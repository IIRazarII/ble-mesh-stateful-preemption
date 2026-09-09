classdef ConfigurableGAPBearer < ble.internal.linkLayerGAPBearer
% This class implements the relaying mechanisms (including Stateful Preemption) described in:
% Belli et al., "Relaying Mechanisms in BLE Mesh Networks: A Method for Improving Latency and Reliability,"
% IEEE Internet of Things Journal, 2025. DOI: 10.1109/JIOT.2025.3550831
%
% It ensures that the scanning process resumes from the interrupted channel
% and completes the remaining scan interval duration. Additionally, it allows 
% dynamic configuration of the T_ChPDU parameter (the random delay between 
% consecutive advertising PDUs) if needed.
%
% RelayStrategy values:
% 0 = Without Preemption (Default BLE Mesh behavior)
% 1 = Stateless Preemption (Aborts scan, resets timer on resume)
% 2 = Stateful Preemption (Saves channel/timer, resumes where interrupted)
%
% Note: This script has only been verified to work with MATLAB R2025b.

    properties
        % Definition of the public property to select the relay strategy.
        % Accepts only values 0, 1, or 2. Default value: 0 (Without Preemption).
        RelayStrategy (1,1) double {mustBeMember(RelayStrategy, [0, 1, 2])} = 0
        
        % Minimum gap for random advertising in milliseconds. Default: 1 ms.
        RandomAdvMinGap (1,1) double {mustBeNonnegative} = 1
        
        % Maximum gap for random advertising in milliseconds. Default: 10 ms.
        RandomAdvMaxGap (1,1) double {mustBeNonnegative} = 10
        
        % Toggle for Stateful Preemption logs (Saved/Restored channels and timers)
        EnablePreemptionLog (1,1) logical = false
        
        % Toggle for Advertising Event logs (T_ChPDU gaps and timing)
        EnableAdvEventLog (1,1) logical = false
        
        % Keep the standard 37-38-39 channel rotation while still drawing
        % T_ChPDU at random. Has no effect when RandomAdvertising is false,
        % since the base class already uses that rotation. Default: false.
        FixedChannelOrder (1,1) logical = false
    end

    properties (Access = protected)
        TRSI = 0                % Remaining Scan Interval time in microseconds
        SavedChannelIndex = -1  % Index of the channel where scanning was interrupted
        SavedChannelCounter = 1 % Index of the channel selection counter
        SavedChannelList = []   % Snapshot of the advertising channel rotation
                                % (pAdvertisingChannelList) at the moment of the
                                % interruption. Needed because, when
                                % RandomAdvertising is enabled, the base class
                                % re-shuffles the channel list at every ADV
                                % event: restoring the counter alone would make
                                % it index a different (re-shuffled) list,
                                % breaking the original scan rotation described
                                % in Fig. 5 of the paper.
    end

    methods
        % Constructor
        function obj = ConfigurableGAPBearer(notificationFcn, varargin)
            % Call the superclass constructor
            obj@ble.internal.linkLayerGAPBearer(notificationFcn, varargin{:});
            
            % Set the native PreemptiveScanning variable based on the chosen strategy
            % (Evaluated only once during node initialization)
            obj.PreemptiveScanning = (obj.RelayStrategy > 0);
            
            % Pin the channel rotation to the standard 37-38-39 sequence.
            % The base class picks a row of pRandomAdvertisingChannelList at
            % every advertising event (and once more in init), so collapsing
            % all six permutations onto the same row makes that draw a no-op
            % while leaving getRandomAdvertisingInstances untouched. This must
            % run after the superclass constructor, which is what assigns the
            % name-value pairs and therefore FixedChannelOrder itself.
            if obj.FixedChannelOrder
                obj.pRandomAdvertisingChannelList = repmat([37 38 39], 6, 1);
                obj.pAdvertisingChannelList = [37; 38; 39];
            end
        end
    end

    methods (Access = protected)
        
        % OVERRIDE SCANNING: Save state before interrupting for Advertising.
        function scanning(obj, elapsedTime, rxLLPacket)
            % Apply the saving logic ONLY for Stateful Preemption (2)
            if obj.RelayStrategy == 2
                % If scanning is interrupted by an incoming packet in the queue
                if (obj.PreemptiveScanning && ~isEmpty(obj.pQueue)) && (obj.LastRunTime < obj.pNextEventTime)
                    % Calculate and store the remaining time
                    obj.TRSI = obj.pNextEventTime - obj.LastRunTime;
                    
                    % Store the current advertising channel to resume later
                    obj.SavedChannelIndex = obj.pChannelIndex;
                    
                    % Store the channel selection counter
                    obj.SavedChannelCounter = obj.pChannelSelectionCounter;
                    
                    % Store the current channel rotation list. The upcoming ADV
                    % event may re-shuffle pAdvertisingChannelList (when
                    % RandomAdvertising is enabled), so the full list must be
                    % restored together with the counter to preserve the
                    % original scanning sequence across the interruption.
                    obj.SavedChannelList = obj.pAdvertisingChannelList;
                    
                    % Log for the stored state
                    if obj.EnablePreemptionLog
                        fprintf('[Preemption] %.2f ms | Suspended | TRSI: %.2f ms | Channel Index: %d | Rotation: [%s]\n', ...
                            obj.LastRunTime/1000, obj.TRSI/1000, obj.SavedChannelIndex, ...
                            strjoin(string(obj.SavedChannelList(:).'), ' '));
                    end
                end
            end
            
            % Execute the standard scanning logic
            scanning@ble.internal.linkLayerGAPBearer(obj, elapsedTime, rxLLPacket);
        end

        % OVERRIDE SWITCHTOSCANNING: Restore the interrupted state.
        function switchToScanning(obj)
            % Execute the standard setup (resets timer, advances channel, and
            % possibly uses a re-shuffled channel list)
            switchToScanning@ble.internal.linkLayerGAPBearer(obj);
            
            % Apply the restoration ONLY for Stateful Preemption (2)
            if obj.RelayStrategy == 2 && obj.TRSI > 0
                % Revert to the channel rotation that was active when scanning
                % was interrupted, so that the subsequent Scan Windows follow
                % the original channel sequence (e.g., resume on 38, then 39)
                if ~isempty(obj.SavedChannelList)
                    obj.pAdvertisingChannelList = obj.SavedChannelList;
                end
                
                % Revert to the channel where scanning was interrupted
                obj.pChannelIndex = obj.SavedChannelIndex;
                
                % Restore the channel selection counter to not skip channels in rotation
                obj.pChannelSelectionCounter = obj.SavedChannelCounter;
                
                % Assign the remaining time to the next scanning event
                obj.pNextEventTime = obj.LastRunTime + obj.TRSI;
                
                % Update the PHY receiver request with the restored channel
                obj.RxRequest.ChannelIndex = obj.pChannelIndex;

                % Synchronize the simulator's event invocation timer with the internal timer
                if ~obj.pSignalAtPHY
                    obj.pNextInvokeTime = obj.pNextEventTime;
                end
                
                % Log for the restored state
                if obj.EnablePreemptionLog
                    fprintf('[Preemption] %.2f ms |  Resumed  | Active Scan Time: %.2f ms | Channel Index: %d | Rotation: [%s]\n', ...
                        obj.LastRunTime/1000, (obj.pNextEventTime - obj.LastRunTime)/1000, obj.pChannelIndex, ...
                        strjoin(string(obj.pAdvertisingChannelList(:).'), ' '));
                end
                
                % Reset state memory for the next full Scan Interval cycle
                obj.TRSI = 0;
                obj.SavedChannelList = [];
            end
        end

        % OVERRIDE GETRANDOMADVERTISINGINSTANCES: Allow configuration of random advertising gaps.
        function advInstances = getRandomAdvertisingInstances(obj)
            advInstances = zeros(1,3);
            
            % Fetch user-defined properties
            minGapMs = obj.RandomAdvMinGap;
            maxGapMs = obj.RandomAdvMaxGap;
            
            % Default to [1, 10] ms if values are invalid
            if isempty(minGapMs) || isempty(maxGapMs) || minGapMs <= 0 || minGapMs >= maxGapMs
                warning('ConfigurableGAPBearer:InvalidAdvGaps', ...
                    'Invalid RandomAdvMinGap/RandomAdvMaxGap values (%g, %g). Falling back to [1, 10] ms.', ...
                    minGapMs, maxGapMs);
                minGapMs = 1;
                maxGapMs = 10;
            end
            
            % Convert directly into microsecond boundaries
            minUs = minGapMs * 1000; 
            maxUs = maxGapMs * 1000; 
            
            % First advertising instance
            advInstances(1) = randi([minUs, maxUs]);
            
            % Second advertising instance
            minSecond = advInstances(1) + minUs;
            % Cap the second instance so it always leaves at least 'minUs'
            % space before the 20ms boundary for the third packet
            maxSecond = min(advInstances(1) + maxUs, round(obj.AdvertisingInterval*1e6,3) - minUs);
            
            if maxSecond < minSecond
                maxSecond = minSecond;
            end
            advInstances(2) = randi([minSecond, maxSecond]);
            
            % Third advertising instance
            minThird = advInstances(2) + minUs;
            maxThird = min(advInstances(2) + maxUs, round(obj.AdvertisingInterval*1e6,3));
            
            % Ensure IMAX is not less than IMIN
            if maxThird < minThird
                maxThird = minThird;
            end
            
            advInstances(3) = randi([minThird, maxThird]);
            
            % Log for the advertising event timings
            if obj.EnableAdvEventLog
                fprintf('[AdvEvent]   Start: %.2f ms | T_ChPDU1: %.2f ms | T_ChPDU2: %.2f ms | End: %.2f ms\n', ...
                    advInstances(1)/1000, ...
                    (advInstances(2) - advInstances(1))/1000, ...
                    (advInstances(3) - advInstances(2))/1000, ...
                    advInstances(3)/1000);
            end
        end
    end
end
