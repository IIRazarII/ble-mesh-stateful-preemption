classdef CustomMeshNode < bluetoothLENode
% This class inherits from the standard MATLAB bluetoothLENode, 
% overriding the internal Link Layer (pLinkLayer) with a custom 
% ConfigurableGAPBearer to support Stateful Preemption and 
% dynamic T_ChPDU intervals.
%
% Supported Name-Value pairs:
%   RelayStrategy     - 0 (Without), 1 (Stateless), 2 (Stateful). Default: 0
%   RandomAdvMinGap   - Minimum gap for T_ChPDU in ms. Default: 1
%   RandomAdvMaxGap   - Maximum gap for T_ChPDU in ms. Default: 10
%   FixedChannelOrder - Keep the 37-38-39 rotation while still randomising
%                       T_ChPDU. Default: false
%
% Note: This script has only been verified to work with MATLAB R2025b.

    properties
        RelayStrategy (1,1) double {mustBeMember(RelayStrategy, [0, 1, 2])} = 0
        RandomAdvMinGap (1,1) double {mustBeNonnegative} = 1
        RandomAdvMaxGap (1,1) double {mustBeNonnegative} = 10
        EnablePreemptionLog (1,1) logical = false
        EnableAdvEventLog   (1,1) logical = false
        FixedChannelOrder   (1,1) logical = false
    end

    methods
        function obj = CustomMeshNode(varargin)
            % Call the superclass constructor
            obj@bluetoothLENode(varargin{:});
            
            % Override the internal Link Layer for each instantiated node
            for i = 1:numel(obj)
                currentNode = obj(i);
                
                % Sync the native hidden property with the selected strategy
                currentNode.PreemptiveScanning = (currentNode.RelayStrategy > 0);
                
                % Apply the custom bearer only for relevant GAP/Mesh roles
                if any(strcmp(currentNode.Role, ["broadcaster-observer", "broadcaster", "observer"]))
                    
                    % Link the bearer to the node's event triggers
                    objWeakRef = matlab.lang.WeakReference(currentNode);
                    notificationFcn = @(eventName, eventData) objWeakRef.Handle.triggerEvent(eventName, eventData);
                    
                    % Instantiate the custom GAP bearer with the node's parameters
                    customBearer = ConfigurableGAPBearer(notificationFcn, ...
                        'Role', currentNode.Role, ...
                        'RelayStrategy', currentNode.RelayStrategy, ...
                        'RandomAdvMinGap', currentNode.RandomAdvMinGap, ...
                        'RandomAdvMaxGap', currentNode.RandomAdvMaxGap, ...
                        'EnablePreemptionLog', currentNode.EnablePreemptionLog, ...
                        'EnableAdvEventLog', currentNode.EnableAdvEventLog, ...
                        'FixedChannelOrder', currentNode.FixedChannelOrder);
                    
                    % Overwrite the protected property of the superclass
                    currentNode.pLinkLayer = customBearer;
                end
            end
        end
    end
end