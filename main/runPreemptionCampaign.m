function [summary, raw] = runPreemptionCampaign(opts)
% BLE Mesh Performance Simulation - Scan Interval Campaign
%
% This function evaluates the three relaying strategies described in:
% Belli et al., "Relaying Mechanisms in BLE Mesh Networks: A Method for
% Improving Latency and Reliability," IEEE Internet of Things Journal,
% 2025. DOI: 10.1109/JIOT.2025.3550831
%
% Every simulation parameter is exposed as a name-value argument.
% Calling the function with no arguments reproduces the reference protocol
% of "Experiment D": 20 relay nodes in a 5x4 grid with 8 m spacing, two
% source-destination pairs at the edges, a 9 m coverage range, 400 messages
% per source at 1 packet/s, two network transmissions, TTL 127, a Scan
% Interval sweep from 10 to 200 ms in 10 ms steps, and 12 repetitions of
% each configuration.
%
% For each relay strategy and Scan Interval value, the function runs a set
% of independent replications on a local worker pool, computes PDR and
% end-to-end latency with their 95% confidence intervals, and plots the
% results against the Scan Interval.
%
% Requires ConfigurableGAPBearer.m and CustomMeshNode.m on the path.
%
% Note: This script has only been verified to work with MATLAB R2025b.
%
% --- CAMPAIGN ------------------------------------------------------------
%   Strategies              Relaying strategies to evaluate: 0/1/2
%   ScanIntervals           Scan Interval values to sweep, in seconds
%   Seeds                   One independent replication per seed
%   RandomStream            Generator used by rng inside each worker
%   UseParallel             Run the replications on a local pool
%   NumWorkers              Pool size; 0 uses the profile default
%   PlotTopology            Draw the network map. The topology is fixed for
%                           the whole campaign, so it is drawn once, before
%                           the sweep starts
%   Plot / ShowCI           Draw the paper-style figure, with 95% error bars
%   PlotTitle               Custom figure title ("" keeps the default)
%   PlotFromOrigin          Anchor every curve at (0 ms, 0), as in the
%                           reference figures
%   SaveResults             Checkpoint to disk after every configuration
%   ResultFile              Destination .mat file
%   Verbose                 Print the campaign header and progress lines
%
% --- TRAFFIC -------------------------------------------------------------
%   PacketsPerSource        Application messages per source, per replication
%   PacketRate              Cycles per second, per source. With the default
%                           BurstSize = 1 this is the message rate; with
%                           BurstSize > 1 it is the burst rate
%   PacketSize              Application payload size, in bytes
%   BurstSize               Messages emitted back-to-back in each cycle
%                           (1 = one message per cycle, the default). Must
%                           divide PacketsPerSource exactly
%   TrafficOnTime           On period of the generator, in seconds. The data
%                           rate is derived so that exactly BurstSize packets
%                           of PacketSize bytes are emitted per cycle
%   DrainTime               Tail of the run with no new messages, in seconds
%                           (0 = half a packet period). It lets the last
%                           message complete its multi-hop path instead of
%                           being counted as transmitted but never received
%   SimTime                 Explicit run length in seconds; 0 derives it from
%                           PacketsPerSource, PacketRate and DrainTime
%
% --- MESH PROFILE --------------------------------------------------------
%   NetworkTransmissions    Transmissions of a network PDU originated by the
%                           node: 1 = single transmission, no replica
%   NetworkTransmitInterval Seconds between those transmissions
%   RelayEnabled            Enable the Relay feature on the grid nodes
%   RelayRetransmissions    Transmissions of a relayed PDU (1 = no repeat)
%   RelayRetransmitInterval Seconds between those transmissions
%   TTL                     Time-To-Live of the network PDUs
%
% --- RADIO AND LINK LAYER ------------------------------------------------
%   AdvertisingInterval     Advertising interval, in seconds
%   RandomAdvertising       Randomise the advertising channel rotation and
%                           the T_ChPDU gaps
%   FixedChannelOrder       Keep the standard 37-38-39 rotation while still
%                           randomising T_ChPDU. Defaults to true because the
%                           reference work combines random T_ChPDU with the
%                           standard scanning order, a pairing the native
%                           RandomAdvertising flag cannot express on its own.
%                           Set it to false to let the Link Layer reshuffle
%                           the rotation at every advertising event, which
%                           makes Stateless Preemption resume on an arbitrary
%                           channel
%   AdvMinGap / AdvMaxGap   T_ChPDU bounds, in milliseconds
%   ReceiverRange           Coverage range, in meters
%   TransmitterPower        Transmit power, in dBm
%
% --- TOPOLOGY ------------------------------------------------------------
%   GridRows / GridCols     Relay grid shape
%   NodesDistance           Grid spacing, in meters
%   SourcePositions         N-by-2 source coordinates
%   DestPositions           N-by-2 destination coordinates, paired by row
%                           with SourcePositions
%
% --- LOGGING -------------------------------------------------------------
%   EnablePreemptionLog     Print Suspended/Resumed events of every node.
%                           Costly, and interleaved across workers: use it
%                           with UseParallel = false
%   EnableAdvEventLog       Print the T_ChPDU gaps of every advertising
%                           event. Same caveat as EnablePreemptionLog
%
% --- OUTPUT --------------------------------------------------------------
%   summary  Struct with the aggregated table, the paired comparison
%            table, the figure handles and the configuration
%   raw      Struct array with one entry per replication, for further
%            inspection
%
% --- EXAMPLES ------------------------------------------------------------
%   % Reference protocol
%   [s, raw] = runPreemptionCampaign();
%
%   % Reduced campaign
%   [s, raw] = runPreemptionCampaign( ...
%       ScanIntervals = [10 20 40 60 100 150 200]*1e-3, ...
%       PacketsPerSource = 100, Seeds = 1:8, NumWorkers = 8, ...
%       NetworkTransmissions = 1, ...
%       ResultFile = "campaign_reduced_single_tx.mat");
%
%   % Four source-destination pairs
%   [s, raw] = runPreemptionCampaign( ...
%       ScanIntervals = [10 20 40 60 100 150 200]*1e-3, ...
%       PacketsPerSource = 50, Seeds = 1:8, NumWorkers = 8, ...
%       ResultFile = "campaign_reduced_4pairs.mat", ...
%       SourcePositions = [0 20; 32  4; 20 24; 12  0], ...
%       DestPositions   = [0  4; 32 20; 20  0; 12 24]);
%
%   % Same campaign with the rotation reshuffled at every advertising event
%   [s, raw] = runPreemptionCampaign( ...
%       ScanIntervals = [10 20 40 60 100 150 200]*1e-3, ...
%       FixedChannelOrder = false, PacketsPerSource = 50, ...
%       Seeds = 1:8, NumWorkers = 8, ...
%       ResultFile = "campaign_reduced_4pairs_random.mat", ...
%       SourcePositions = [0 20; 32  4; 20 24; 12  0], ...
%       DestPositions   = [0  4; 32 20; 20  0; 12 24]);

arguments
    % --- CAMPAIGN --------------------------------------------------------
    opts.Strategies              (1,:) double  {mustBeMember(opts.Strategies, [0 1 2])} = [0 1 2]
    opts.ScanIntervals           (1,:) double  {mustBePositive} = (10:10:200)*1e-3
    opts.Seeds                   (1,:) double  = 1:12
    opts.RandomStream            (1,1) string  = "twister"
    opts.UseParallel             (1,1) logical = true
    opts.NumWorkers              (1,1) double  {mustBeNonnegative} = 12
    opts.PlotTopology            (1,1) logical = true
    opts.Plot                    (1,1) logical = true
    opts.ShowCI                  (1,1) logical = true
    opts.PlotTitle               (1,1) string  = ""
    opts.PlotFromOrigin          (1,1) logical = true
    opts.SaveResults             (1,1) logical = true
    opts.ResultFile              (1,1) string  = "preemption_campaign.mat"
    opts.Verbose                 (1,1) logical = true

    % --- TRAFFIC ---------------------------------------------------------
    opts.PacketsPerSource        (1,1) double  {mustBePositive} = 400
    opts.PacketRate              (1,1) double  {mustBePositive} = 1
    opts.PacketSize              (1,1) double  {mustBePositive} = 15
    opts.BurstSize               (1,1) double  {mustBeInteger, mustBePositive} = 1
    opts.TrafficOnTime           (1,1) double  {mustBePositive} = 1e-3
    opts.DrainTime               (1,1) double  {mustBeNonnegative} = 0
    opts.SimTime                 (1,1) double  {mustBeNonnegative} = 0

    % --- MESH PROFILE ----------------------------------------------------
    opts.NetworkTransmissions    (1,1) double  {mustBePositive} = 2
    opts.NetworkTransmitInterval (1,1) double  {mustBePositive} = 30e-3
    opts.RelayEnabled            (1,1) logical = true
    opts.RelayRetransmissions    (1,1) double  {mustBePositive} = 1
    opts.RelayRetransmitInterval (1,1) double  {mustBePositive} = 10e-3
    opts.TTL                     (1,1) double  {mustBePositive} = 127

    % --- RADIO AND LINK LAYER --------------------------------------------
    opts.AdvertisingInterval     (1,1) double  {mustBePositive} = 20e-3
    opts.RandomAdvertising       (1,1) logical = true
    opts.FixedChannelOrder       (1,1) logical = true
    opts.AdvMinGap               (1,1) double  {mustBePositive} = 1
    opts.AdvMaxGap               (1,1) double  {mustBePositive} = 10
    opts.ReceiverRange           (1,1) double  {mustBePositive} = 9
    opts.TransmitterPower        (1,1) double  = 20

    % --- TOPOLOGY --------------------------------------------------------
    opts.GridRows                (1,1) double  {mustBeInteger, mustBePositive} = 4
    opts.GridCols                (1,1) double  {mustBeInteger, mustBePositive} = 5
    opts.NodesDistance           (1,1) double  {mustBePositive} = 8
    opts.SourcePositions         (:,2) double  = [0 20; 32 4]
    opts.DestPositions           (:,2) double  = [0 4; 32 20]

    % --- LOGGING ---------------------------------------------------------
    opts.EnablePreemptionLog     (1,1) logical = false
    opts.EnableAdvEventLog       (1,1) logical = false
end

%% 1. CROSS-PARAMETER VALIDATION AND DERIVED QUANTITIES
if size(opts.SourcePositions, 1) ~= size(opts.DestPositions, 1)
    error('runPreemptionCampaign:PairMismatch', ...
        'SourcePositions and DestPositions must have the same number of rows (%d vs %d).', ...
        size(opts.SourcePositions, 1), size(opts.DestPositions, 1));
end

if opts.AdvMinGap >= opts.AdvMaxGap
    error('runPreemptionCampaign:AdvGaps', ...
        'AdvMinGap (%g ms) must be smaller than AdvMaxGap (%g ms).', ...
        opts.AdvMinGap, opts.AdvMaxGap);
end

% The generator emits BurstSize messages per On-Off cycle, so PacketRate is
% the rate of the cycles: with the default BurstSize = 1 it is the message
% rate, and with BurstSize > 1 it is the burst rate.
period = 1 / opts.PacketRate;

if mod(opts.PacketsPerSource, opts.BurstSize) ~= 0
    error('runPreemptionCampaign:BurstSize', ...
        'PacketsPerSource (%g) must be an integer multiple of BurstSize (%d).', ...
        opts.PacketsPerSource, opts.BurstSize);
end

nBursts = opts.PacketsPerSource / opts.BurstSize;

if opts.TrafficOnTime >= period
    error('runPreemptionCampaign:OnTime', ...
        'TrafficOnTime (%g s) must be shorter than the cycle period (%g s).', ...
        opts.TrafficOnTime, period);
end

% The data rate is chosen so that the On period carries exactly BurstSize
% packets of PacketSize bytes: the generator spaces them by the time needed
% to transmit one packet, so BurstSize of them fill TrafficOnTime exactly.
% DataRate is expressed in kb/s by networkTrafficOnOff.
dataRate = (opts.BurstSize * opts.PacketSize * 8) / (opts.TrafficOnTime * 1000);

% The traffic generator fires at t = 0, T, 2T, ... so a run of length L
% emits floor(L/T) + 1 messages per source. Reserving a drain window at the
% end caps the count at exactly PacketsPerSource and, at the same time,
% leaves room for the last message to complete its multi-hop path: without
% it that message would be counted as transmitted but never as received,
% depressing the PDR by 1/PacketsPerSource.
drainTime = opts.DrainTime;
if drainTime == 0
    drainTime = period / 2;  % Reference behaviour: half a packet period
end

if drainTime > period
    error('runPreemptionCampaign:DrainTime', ...
        'DrainTime (%g s) cannot exceed the cycle period (%g s), or the last burst is never generated.', ...
        drainTime, period);
end

if opts.SimTime > 0
    simTime = opts.SimTime;  % Explicit override: the message count follows
else
    simTime = nBursts * period - drainTime;
end

if simTime <= opts.TrafficOnTime
    error('runPreemptionCampaign:SimTimeTooShort', ...
        'The run (%g s) is not longer than the burst itself (%g s): raise SimTime or lower TrafficOnTime.', ...
        simTime, opts.TrafficOnTime);
end

% Messages actually generated per source, given the resulting run length. A
% burst that starts before the end of the run is counted in full, since its
% On period is short compared with the cycle.
msgPerSource = (floor(simTime / period) + 1) * opts.BurstSize;

if opts.AdvertisingInterval <= opts.AdvMaxGap * 1e-3
    warning('runPreemptionCampaign:AdvGapTooLarge', ...
        'AdvMaxGap (%g ms) does not fit inside AdvertisingInterval (%g ms): T_ChPDU values will be clipped.', ...
        opts.AdvMaxGap, opts.AdvertisingInterval * 1000);
end

% Rotation actually in use, reported in the header
if opts.RandomAdvertising && ~opts.FixedChannelOrder
    channelOrder = "randomised";
else
    channelOrder = "fixed 37-38-39";
end

strategyNames = ["Without Preemption", "Stateless Preemption", "Stateful Preemption"];
nSeeds  = numel(opts.Seeds);
nPairs  = size(opts.SourcePositions, 1);
nConfig = numel(opts.Strategies) * numel(opts.ScanIntervals);

% Everything a single replication needs is packed into one struct: parfor
% broadcasts it as a whole, whereas individual fields of a captured struct
% (opts.Foo) would not be accepted inside the loop body.
cfg = struct( ...
    'PacketSize',              opts.PacketSize, ...
    'DataRate',                dataRate, ...
    'OnTime',                  opts.TrafficOnTime, ...
    'OffTime',                 period - opts.TrafficOnTime, ...
    'SimTime',                 simTime, ...
    'NetworkTransmissions',    opts.NetworkTransmissions, ...
    'NetworkTransmitInterval', opts.NetworkTransmitInterval, ...
    'RelayEnabled',            opts.RelayEnabled, ...
    'RelayRetransmissions',    opts.RelayRetransmissions, ...
    'RelayRetransmitInterval', opts.RelayRetransmitInterval, ...
    'TTL',                     opts.TTL, ...
    'AdvertisingInterval',     opts.AdvertisingInterval, ...
    'RandomAdvertising',       opts.RandomAdvertising, ...
    'FixedChannelOrder',       opts.FixedChannelOrder, ...
    'AdvMinGap',               opts.AdvMinGap, ...
    'AdvMaxGap',               opts.AdvMaxGap, ...
    'ReceiverRange',           opts.ReceiverRange, ...
    'TransmitterPower',        opts.TransmitterPower, ...
    'GridRows',                opts.GridRows, ...
    'GridCols',                opts.GridCols, ...
    'NodesDistance',           opts.NodesDistance, ...
    'SourcePositions',         opts.SourcePositions, ...
    'DestPositions',           opts.DestPositions, ...
    'RandomStream',            opts.RandomStream, ...
    'EnablePreemptionLog',     opts.EnablePreemptionLog, ...
    'EnableAdvEventLog',       opts.EnableAdvEventLog);

%% 2. PARALLEL POOL SETUP
% Replications are independent, so each one can run on its own worker.
% Workers are separate processes: the wirelessNetworkSimulator singleton
% therefore does not conflict across concurrent simulations.
%
% Replications of a configuration run concurrently, one per worker. When the
% number of seeds is not a multiple of the pool size, the last wave is
% partial and the configuration takes longer than the workers in use would
% suggest: NumWorkers is best kept equal to the seed count.
if opts.UseParallel
    if opts.EnablePreemptionLog || opts.EnableAdvEventLog
        warning('runPreemptionCampaign:LogsInParallel', ...
            'Node logs are enabled on a parallel pool: the output of the workers will be interleaved and hard to read.');
    end

    pool = gcp('nocreate');

    % An existing pool of the wrong size is discarded, since its size cannot
    % be changed once created.
    if opts.NumWorkers > 0 && ~isempty(pool) && pool.NumWorkers ~= opts.NumWorkers
        delete(pool);
        pool = [];
    end

    if isempty(pool)
        if opts.NumWorkers > 0
            % The local profile may cap the worker count below the requested
            % value, in which case the profile default is used instead.
            try
                pool = parpool('Processes', opts.NumWorkers);
            catch poolErr
                warning('runPreemptionCampaign:PoolSize', ...
                    'Could not start %d workers (%s). Falling back to the profile default.', ...
                    opts.NumWorkers, poolErr.message);
                pool = parpool('Processes');
            end
        else
            pool = parpool('Processes');
        end
    end

    % The custom classes must be visible to the workers. An alternative
    % is pctRunOnAll addpath('/path/to/folder').
    addAttachedFiles(pool, {'ConfigurableGAPBearer.m', 'CustomMeshNode.m'});
    nWorkers = pool.NumWorkers;
else
    nWorkers = 0;  % With 0 workers parfor degenerates into a serial for
end

if opts.Verbose
    fprintf('\n======================================================\n');
    fprintf('   BLE Mesh Campaign Initialized\n');
    fprintf('======================================================\n');
    fprintf(' Strategies     : %d\n', numel(opts.Strategies));
    fprintf(' Scan Intervals : %s ms\n', strjoin(string(opts.ScanIntervals*1000), ' '));
    fprintf(' Configurations : %d\n', nConfig);
    fprintf(' Replications   : %d per configuration\n', nSeeds);
    fprintf(' Topology       : %dx%d grid, %g m spacing, %d pairs, %g m range\n', ...
        opts.GridRows, opts.GridCols, opts.NodesDistance, nPairs, opts.ReceiverRange);
    if opts.BurstSize > 1
        fprintf(' Traffic        : %d-packet bursts @ %g Hz, %g B, %d messages/source\n', ...
            opts.BurstSize, opts.PacketRate, opts.PacketSize, msgPerSource);
    else
        fprintf(' Traffic        : %g pkt/s, %g B, %d messages/source\n', ...
            opts.PacketRate, opts.PacketSize, msgPerSource);
    end
    fprintf(' Mesh           : NetTx %d @ %g ms, RelayTx %d @ %g ms, TTL %d\n', ...
        opts.NetworkTransmissions, opts.NetworkTransmitInterval*1000, ...
        opts.RelayRetransmissions, opts.RelayRetransmitInterval*1000, opts.TTL);
    fprintf(' Link Layer     : ADV %g ms, T_ChPDU [%g, %g] ms, Random %d\n', ...
        opts.AdvertisingInterval*1000, opts.AdvMinGap, opts.AdvMaxGap, opts.RandomAdvertising);
    fprintf(' Channel Order  : %s\n', channelOrder);
    fprintf(' Duration       : %.2f s each (%.2f s drain window)\n', ...
        simTime, simTime - (floor(simTime/period)*period + opts.TrafficOnTime));
    fprintf(' Workers        : %d\n', max(nWorkers, 1));
    fprintf('======================================================\n\n');
end

%% 3. NETWORK TOPOLOGY MAP
% The topology does not change across strategies, Scan Intervals or seeds,
% so the map is drawn once here rather than inside runSingle: that function
% executes on the workers, where a figure would be created in an invisible
% process and lost. Drawing it before the sweep also lets the layout be
% checked while the campaign is still running.
topologyFigure = gobjects(0);

if opts.PlotTopology
    if opts.Verbose
        fprintf('Drawing the network topology map...\n');
    end

    % Same lattice as the one built by runSingle, kept in step with it
    [Xtopo, Ytopo] = meshgrid( ...
        0:opts.NodesDistance:(opts.GridCols-1)*opts.NodesDistance, ...
        0:opts.NodesDistance:(opts.GridRows-1)*opts.NodesDistance);

    topologyFigure = plotTopology([Xtopo(:), Ytopo(:)], opts.SourcePositions, ...
        opts.DestPositions, opts.NodesDistance, opts.ReceiverRange);
end

raw = struct('Strategy', {}, 'ScanInterval', {}, 'Seed', {}, ...
             'PDR', {}, 'Latency', {}, 'Tx', {}, 'Rx', {}, ...
             'TxPair', {}, 'RxPair', {}, 'LatPair', {}, ...
             'SrcIDs', {}, 'DstIDs', {}, 'Elapsed', {});

%% 4. RUN THE CAMPAIGN
% The loops over strategy and Scan Interval are kept serial so that partial
% results can be checkpointed to disk: an interrupted sweep is not lost.
tCampaign = tic;
iConfig = 0;

for s = 1:numel(opts.Strategies)
    for c = 1:numel(opts.ScanIntervals)
        % Local copies: parfor requires sliced or broadcast variables, not
        % fields of a struct captured from the enclosing scope.
        strat = opts.Strategies(s);
        scanI = opts.ScanIntervals(c);
        seeds = opts.Seeds;
        runCfg = cfg;

        block(1:nSeeds) = struct('PDR', NaN, 'Latency', NaN, 'Tx', 0, 'Rx', 0, ...
                                 'TxPair', [], 'RxPair', [], 'LatPair', [], ...
                                 'SrcIDs', [], 'DstIDs', [], 'Elapsed', NaN);
        tConfig = tic;

        parfor (k = 1:nSeeds, nWorkers)
            block(k) = runSingle(runCfg, strat, seeds(k), scanI);
        end

        for k = 1:nSeeds
            raw(end+1) = struct('Strategy', strat, 'ScanInterval', scanI, ...
                'Seed', seeds(k), 'PDR', block(k).PDR, ...
                'Latency', block(k).Latency, ...
                'Tx', block(k).Tx, 'Rx', block(k).Rx, ...
                'TxPair', block(k).TxPair, 'RxPair', block(k).RxPair, ...
                'LatPair', block(k).LatPair, ...
                'SrcIDs', block(k).SrcIDs, 'DstIDs', block(k).DstIDs, ...
                'Elapsed', block(k).Elapsed); %#ok<AGROW>
        end

        iConfig = iConfig + 1;
        if opts.Verbose
            fprintf('[%s] (%d/%d) %-20s T_SI=%3.0f ms | %.1f min | PDR %.2f%% | Lat %.1f ms\n', ...
                string(datetime('now', 'Format', 'HH:mm:ss')), iConfig, nConfig, ...
                strategyNames(strat+1), scanI*1000, toc(tConfig)/60, ...
                mean([block.PDR]), 1000*mean([block.Latency]));
        end

        % Checkpoint after each configuration
        if opts.SaveResults
            save(opts.ResultFile, 'raw', 'opts');
        end
    end
end

if opts.Verbose
    fprintf('\nCampaign completed in %.1f min.\n', toc(tCampaign)/60);
end

%% 5. POST-CAMPAIGN ANALYSIS (PDR AND LATENCY)
summary = summarize(raw, opts.Strategies, opts.ScanIntervals, strategyNames);
summary.config = opts;

% The handle is kept separate from summary.figure, which holds the PDR and
% latency plot produced at the end of this function.
if ~isempty(topologyFigure)
    summary.topologyFigure = topologyFigure;
end

if opts.SaveResults
    save(opts.ResultFile, 'raw', 'summary', 'opts');
end

% The per-pair breakdown is only printed for single-point campaigns: over a
% full sweep it would produce one block per configuration and bury the trend.
if opts.Verbose && isscalar(opts.ScanIntervals)
    printPairBreakdown(raw, opts.Strategies, strategyNames);
end

if opts.Verbose
    fprintf('\n--- Summary Across Replications ---\n');
    disp(summary.table);

    if ~isempty(summary.pairedTable)
        fprintf('Paired differences against "Without Preemption":\n');
        disp(summary.pairedTable);
    end
end

if opts.Plot
    summary.figure = plotCampaign(summary, opts.Strategies, ...
        opts.ScanIntervals, strategyNames, opts.ShowCI, opts.ReceiverRange, ...
        opts.PlotTitle, opts.PlotFromOrigin);
end
end

%% ========================================================================
function fig = plotCampaign(summary, strategies, scanIntervals, names, showCI, receiverRange, customTitle, fromOrigin)
% Draws PDR and end-to-end latency against the Scan Interval, following the
% layout of Figs. 11 and 17 of the reference paper: PDR in blue on the left
% axis, latency in red on the right axis, and one line style per relaying
% strategy (solid = without, dashed = stateless, dotted = stateful).
%
% Unlike the original figures, error bars report the 95% confidence
% interval over the replications.

fig = figure('Name', 'BLE Mesh: PDR and Latency vs Scan Interval', ...
             'Color', 'w', 'Position', [200, 200, 650, 450]);

% Line styles and widths of the reference figures, indexed by strategy
styles  = {'-', '--', ':'};
widths  = [1.5, 1.2, 1.5];
legendNames = ["Without Preemption", "With Stateless Preemption", ...
               "With Stateful Preemption"];

T      = summary.table;
tsiMs  = scanIntervals * 1000;
xMax   = max(tsiMs);
latMax = 0;
hLeg   = gobjects(1, numel(strategies));

hold on;

% --- LEFT AXIS: PDR ------------------------------------------------------
yyaxis left
for s = 1:numel(strategies)
    m = T.Strategy == names(strategies(s)+1);
    [x, ord] = sort(T.ScanInterval_ms(m));
    y  = T.MeanPDR(m);   y  = y(ord);
    ci = T.PDR_CI95(m);  ci = ci(ord);

    % The reference curves start at the origin, where no packet is delivered
    if fromOrigin
        x = [0; x]; y = [0; y]; ci = [0; ci];
    end

    k = mod(strategies(s), numel(styles)) + 1;
    if showCI
        plotSeries(x, y, ci, 'b', styles{k}, widths(k));
    else
        plotSeries(x, y, [], 'b', styles{k}, widths(k));
    end
end
ylabel('PDR (%)', 'Interpreter', 'none');
ylim([0, 100]);
yticks(0:10:100);

% --- RIGHT AXIS: LATENCY -------------------------------------------------
yyaxis right
for s = 1:numel(strategies)
    m = T.Strategy == names(strategies(s)+1);
    [x, ord] = sort(T.ScanInterval_ms(m));
    y  = T.MeanLatency_ms(m)  / 1000;   y  = y(ord);
    ci = T.Latency_CI95_ms(m) / 1000;   ci = ci(ord);

    if fromOrigin
        x = [0; x]; y = [0; y]; ci = [0; ci];
    end
    latMax = max([latMax; y(:) + max(ci(:), 0)], [], 'omitnan');

    k = mod(strategies(s), numel(styles)) + 1;
    if showCI
        plotSeries(x, y, ci, 'r', styles{k}, widths(k));
    else
        plotSeries(x, y, [], 'r', styles{k}, widths(k));
    end

    hLeg(s) = plot(nan, nan, 'Color', 'k', 'LineStyle', styles{k}, ...
        'LineWidth', widths(k));
end

% The 2 s span of the reference figures is kept unless the data exceed it
yTop = max(2, ceil(latMax / 0.2) * 0.2);
ylabel('Latency (s)', 'Interpreter', 'none');
ylim([0, yTop]);
yticks(0:0.2:yTop);

% --- COSMETICS -----------------------------------------------------------
ax = gca;
ax.YAxis(1).Color = 'b';
ax.YAxis(2).Color = 'r';
xlabel('ScanInterval (ms)', 'Interpreter', 'none');
xlim([0, xMax]);
xticks(unique(round(linspace(0, xMax, 11), 4)));
grid on;

legend(hLeg, legendNames(strategies+1), 'Location', 'southeast', ...
    'FontSize', 8, 'Interpreter', 'none');

if strlength(customTitle) > 0
    title(customTitle, 'Interpreter', 'none');
else
    title(sprintf('Grid topology (Coverage range: %g m)', receiverRange), ...
        'Interpreter', 'none');
end

hold off;
drawnow;
end

%% ========================================================================
function plotSeries(x, y, ci, colour, style, width)
% One curve of the figure: a plain line, or an errorbar without markers when
% the confidence interval is requested, so that the look of the reference
% figures is preserved in both cases.

if isempty(ci) || all(isnan(ci))
    plot(x, y, 'Color', colour, 'LineStyle', style, 'LineWidth', width, ...
        'Marker', 'none', 'HandleVisibility', 'off');
else
    errorbar(x, y, ci, 'Color', colour, 'LineStyle', style, ...
        'LineWidth', width, 'Marker', 'none', 'HandleVisibility', 'off');
end
end

%% ========================================================================
function printPairBreakdown(raw, strategies, names)
% Reports Tx/Rx per source-destination pair, with the counters summed over
% all replications of each strategy.

for s = 1:numel(strategies)
    m = raw([raw.Strategy] == strategies(s));
    if isempty(m)
        continue
    end

    fprintf('\n--- Performance Results: %s (%d replications) ---\n', ...
        names(strategies(s)+1), numel(m));

    srcIDs  = m(1).SrcIDs;
    dstIDs  = m(1).DstIDs;
    txPair  = sum(vertcat(m.TxPair), 1);
    rxPair  = sum(vertcat(m.RxPair), 1);
    latPair = mean(vertcat(m.LatPair), 1, 'omitnan');

    for p = 1:numel(srcIDs)
        fprintf('Pair %d (Node %d -> %d): Tx=%d, Rx=%d, PDR=%.2f%%\n', ...
            p, srcIDs(p), dstIDs(p), txPair(p), rxPair(p), ...
            100 * rxPair(p) / max(txPair(p), 1));
    end

    % Aggregate Results
    fprintf('\nOVERALL RESULTS:\n');
    fprintf('Total Transmitted / Received: %d / %d\n', ...
        sum(txPair), sum(rxPair));
    fprintf('Aggregate Packet Delivery Ratio (PDR): %.2f %%\n', ...
        100 * sum(rxPair) / max(sum(txPair), 1));
    fprintf('Average End-to-End Latency: %.4f seconds\n', mean(latPair, 'omitnan'));
end
end

%% ========================================================================
function out = runSingle(cfg, strategy, seed, scanInterval)
% Executes a single replication and returns its aggregate metrics. Every
% scenario parameter travels inside cfg, so the function holds no constant.

t0 = tic;

% Seed the generator inside the worker
rng(seed, char(cfg.RandomStream));

%% 1. CREATE THE GRID TOPOLOGY
% Relays occupy a GridRows-by-GridCols lattice; sources and destinations are
% appended afterwards, so the node IDs are:
%   1 : numRelays                       -> relays
%   numRelays + (1:nPairs)              -> sources
%   numRelays + nPairs + (1:nPairs)     -> destinations
[X, Y] = meshgrid(0:cfg.NodesDistance:(cfg.GridCols-1)*cfg.NodesDistance, ...
                  0:cfg.NodesDistance:(cfg.GridRows-1)*cfg.NodesDistance);
relayPositions = [X(:), Y(:)];
numRelays = size(relayPositions, 1);

nPairs = size(cfg.SourcePositions, 1);
allPositions = [relayPositions; cfg.SourcePositions; cfg.DestPositions];
numTotalNodes = size(allPositions, 1);

srcIDs = numRelays + (1:nPairs);
dstIDs = numRelays + nPairs + (1:nPairs);

%% 2. INITIALIZE SIMULATOR
% init also resets the singleton, so consecutive replications assigned to
% the same worker do not inherit nodes from one another.
simulator = wirelessNetworkSimulator.init;

%% 3. CREATE AND CONFIGURE NODES
nodes = CustomMeshNode.empty(0, numTotalNodes);

for i = 1:numTotalNodes
    % Configure Mesh Profile
    meshCfg = bluetoothMeshProfileConfig( ...
        ElementAddress = dec2hex(i, 4), ...
        NetworkTransmissions = cfg.NetworkTransmissions, ...
        NetworkTransmitInterval = cfg.NetworkTransmitInterval, ...
        TTL = cfg.TTL);

    % Enable Relay for the grid nodes. The retransmission parameters only
    % exist on the object once the Relay feature is turned on.
    if cfg.RelayEnabled && i <= numRelays
        meshCfg.Relay = true;
        meshCfg.RelayRetransmissions = cfg.RelayRetransmissions;
        meshCfg.RelayRetransmitInterval = cfg.RelayRetransmitInterval;
    end

    % Create Node using the custom subclass
    nodes(i) = CustomMeshNode("broadcaster-observer", ...
        MeshConfig = meshCfg, ...
        Position = [allPositions(i, :) 0], ...
        Name = "Node_" + i, ...
        TransmitterPower = cfg.TransmitterPower, ...
        ReceiverRange = cfg.ReceiverRange, ...
        AdvertisingInterval = cfg.AdvertisingInterval, ...
        ScanInterval = scanInterval, ...
        RandomAdvertising = cfg.RandomAdvertising, ...
        FixedChannelOrder = cfg.FixedChannelOrder, ...
        RelayStrategy = strategy, ...
        RandomAdvMinGap = cfg.AdvMinGap, ...
        RandomAdvMaxGap = cfg.AdvMaxGap, ...
        EnablePreemptionLog = cfg.EnablePreemptionLog, ...
        EnableAdvEventLog = cfg.EnableAdvEventLog);
end

%% 4. CONFIGURE TRAFFIC
% BurstSize packets per On-Off cycle: the data rate was derived by the
% caller so that OnTime carries exactly that many packets, and OffTime
% completes the cycle. Raising the rate raises the offered load, which is
% itself a variable of the experiment and not merely a way to shorten the run.
for p = 1:nPairs
    traffic = networkTrafficOnOff( ...
        DataRate = cfg.DataRate, ...
        PacketSize = cfg.PacketSize, ...
        GeneratePacket = true, ...
        OnTime = cfg.OnTime, ...
        OffTime = cfg.OffTime);

    addTrafficSource(nodes(srcIDs(p)), traffic, ...
        SourceAddress = nodes(srcIDs(p)).MeshConfig.ElementAddress, ...
        DestinationAddress = nodes(dstIDs(p)).MeshConfig.ElementAddress, ...
        TTL = cfg.TTL);
end

%% 5. RUN SIMULATION
addNodes(simulator, nodes);
run(simulator, cfg.SimTime);

%% 6. COLLECT METRICS
% Counters are kept per source-destination pair, not only aggregated, so
% that the campaign can report the Tx/Rx breakdown of each pair.
txPair  = zeros(1, nPairs);
rxPair  = zeros(1, nPairs);
latPair = NaN(1, nPairs);

for p = 1:nPairs
    sStats = statistics(nodes(srcIDs(p)));
    dStats = statistics(nodes(dstIDs(p)));

    txPair(p) = sum([sStats.App.TransmittedPackets]);
    rxPair(p) = sum([dStats.App.ReceivedPackets]);

    if rxPair(p) > 0
        latPair(p) = mean([dStats.App.AveragePacketLatency]);
    end
end

% PDR = (Total Received / Total Transmitted) * 100
out.PDR = 100 * sum(rxPair) / max(sum(txPair), 1);

% The reference work averages the per-pair latency curves arithmetically,
% so the same convention is used here for comparability with its figures.
out.Latency = mean(latPair, 'omitnan');

out.Tx      = sum(txPair);
out.Rx      = sum(rxPair);
out.TxPair  = txPair;
out.RxPair  = rxPair;
out.LatPair = latPair;
out.SrcIDs  = srcIDs;
out.DstIDs  = dstIDs;
out.Elapsed = toc(t0);
end

%% ========================================================================
function summary = summarize(raw, strategies, scanIntervals, names)
% Aggregates the replications into means, 95% confidence intervals and
% paired differences between strategies, for each Scan Interval.

rows = struct('Strategy', {}, 'ScanInterval_ms', {}, 'MeanPDR', {}, ...
              'PDR_CI95', {}, 'MeanLatency_ms', {}, 'Latency_CI95_ms', {}, ...
              'Replications', {}, 'Packets', {});

for s = 1:numel(strategies)
    for c = 1:numel(scanIntervals)
        m = [raw.Strategy] == strategies(s) & ...
            [raw.ScanInterval] == scanIntervals(c);
        if ~any(m)
            continue
        end

        pdr = [raw(m).PDR];
        lat = [raw(m).Latency] * 1000;

        rows(end+1) = struct( ...
            'Strategy',        names(strategies(s)+1), ...
            'ScanInterval_ms', scanIntervals(c) * 1000, ...
            'MeanPDR',         mean(pdr), ...
            'PDR_CI95',        ci95(pdr), ...
            'MeanLatency_ms',  mean(lat, 'omitnan'), ...
            'Latency_CI95_ms', ci95(lat), ...
            'Replications',    numel(pdr), ...
            'Packets',         sum([raw(m).Tx])); %#ok<AGROW>
    end
end
summary.table = struct2table(rows);

% Paired comparison against the baseline, computed separately at each Scan
% Interval. Note that sharing a seed does not synchronise two strategies:
% they consume the random stream in different orders, so this pairing
% removes no variance in practice and the interval is essentially that of
% two independent samples.
summary.pairedTable = [];

if ismember(0, strategies)
    prows = struct('Comparison', {}, 'ScanInterval_ms', {}, ...
                   'DeltaPDR', {}, 'DeltaPDR_CI95', {}, ...
                   'DeltaLatency_ms', {}, 'DeltaLatency_CI95_ms', {});

    for c = 1:numel(scanIntervals)
        base = raw([raw.Strategy] == 0 & [raw.ScanInterval] == scanIntervals(c));
        if isempty(base)
            continue
        end

        for s = strategies(strategies ~= 0)
            cur = raw([raw.Strategy] == s & [raw.ScanInterval] == scanIntervals(c));
            if isempty(cur)
                continue
            end

            % Match the replications by seed, in case a configuration has
            % fewer runs than another.
            [~, ia, ib] = intersect([base.Seed], [cur.Seed]);
            dP = [cur(ib).PDR] - [base(ia).PDR];
            dL = ([cur(ib).Latency] - [base(ia).Latency]) * 1000;

            prows(end+1) = struct( ...
                'Comparison',           names(s+1) + " vs base", ...
                'ScanInterval_ms',      scanIntervals(c) * 1000, ...
                'DeltaPDR',             mean(dP), ...
                'DeltaPDR_CI95',        ci95(dP), ...
                'DeltaLatency_ms',      mean(dL, 'omitnan'), ...
                'DeltaLatency_CI95_ms', ci95(dL)); %#ok<AGROW>
        end
    end
    summary.pairedTable = struct2table(prows);
end
end

%% ========================================================================
function h = ci95(x)
% Half-width of the 95% confidence interval of the mean (Student's t).

x = x(~isnan(x));
n = numel(x);

% A single replication carries no information about the variance
if n < 2
    h = NaN;
    return
end

h = tcrit95(n-1) * std(x) / sqrt(n);
end

%% ========================================================================
function t = tcrit95(df)
% 0.975 quantile of Student's t distribution, tabulated for 1 to 30 degrees
% of freedom. Avoids a dependency on the Statistics and Machine Learning
% Toolbox, which tinv would otherwise require.

tbl = [12.706 4.303 3.182 2.776 2.571 2.447 2.365 2.306 2.262 2.228 ...
        2.201 2.179 2.160 2.145 2.131 2.120 2.110 2.101 2.093 2.086 ...
        2.080 2.074 2.069 2.064 2.060 2.056 2.052 2.048 2.045 2.042];

if df <= numel(tbl)
    t = tbl(df);
else
    t = 1.96;  % Normal approximation, adequate beyond 30 replications
end
end

%% ========================================================================
function fig = plotTopology(relayPositions, sourcePos, destPos, spacing, range)
% Draws the node map: relays as blue dots, sources as green squares and
% destinations as red triangles, with the source-destination pairs labelled
% following the node numbering (S1..Sn, then D(n+1)..D(2n)).

nPairs = size(sourcePos, 1);
allPos = [relayPositions; sourcePos; destPos];

fig = figure('Name', 'BLE Mesh Network Topology', 'Position', [100, 100, 700, 500]);
hold on; grid on;

scatter(relayPositions(:,1), relayPositions(:,2), 50, 'b', 'filled', ...
    'DisplayName', 'Relay Nodes');
scatter(sourcePos(:,1), sourcePos(:,2), 120, 'g', 's', 'filled', ...
    'DisplayName', 'Source Nodes');
scatter(destPos(:,1), destPos(:,2), 120, 'r', '^', 'filled', ...
    'DisplayName', 'Destination Nodes');

% Every string is drawn with Interpreter = 'none': the default 'tex'
% interpreter needs the TeX font set, which is not always available (the
% figure then warns "Could not load TeX fonts" and falls back anyway). None
% of these labels uses TeX markup, so nothing is lost by skipping it.
title(sprintf('Grid Topology: %d relays, %d pairs, %g m range', ...
    size(relayPositions, 1), nPairs, range), 'Interpreter', 'none');
xlabel('Distance X (m)', 'Interpreter', 'none');
ylabel('Distance Y (m)', 'Interpreter', 'none');
legend('Location', 'northeastoutside', 'Interpreter', 'none');

% Axes limits follow the node coordinates instead of being hard-coded, so
% that a different grid or different source positions still fit in view.
margin = max(spacing, 1);
axis equal;
xlim([min(allPos(:,1)) - margin, max(allPos(:,1)) + margin]);
ylim([min(allPos(:,2)) - margin, max(allPos(:,2)) + margin]);

% Labels are pushed away from the centre of the map, so that they do not
% overlap the grid when a source sits on the left or on the right edge.
centreX = mean(allPos(:,1));
offset  = 0.35 * margin;

for p = 1:nPairs
    placeLabel(sourcePos(p,:), "S" + p, centreX, offset);
    placeLabel(destPos(p,:), "D" + (nPairs + p), centreX, offset);
end

hold off;
drawnow;
end

%% ========================================================================
function placeLabel(pos, label, centreX, offset)
% Places a text label to the left or to the right of a node, depending on
% which side of the map the node lies.

if pos(1) <= centreX
    text(pos(1) - offset, pos(2), label, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'right', 'Interpreter', 'none');
else
    text(pos(1) + offset, pos(2), label, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'left', 'Interpreter', 'none');
end
end
