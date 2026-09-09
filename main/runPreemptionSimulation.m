function [results, nodes] = runPreemptionSimulation(opts)
% BLE Mesh Performance Simulation - Single Run
%
% This function runs one replication of the setup described in:
% Belli et al., "Relaying Mechanisms in BLE Mesh Networks: A Method for
% Improving Latency and Reliability," IEEE Internet of Things Journal,
% 2025. DOI: 10.1109/JIOT.2025.3550831
%
% Every simulation parameter is exposed as a name-value argument.
% Calling the function with no arguments reproduces the reference protocol
% of "Experiment D": 20 relay nodes in a 5x4 grid with 8 m spacing, two
% source-destination pairs at the edges, a 9 m coverage range, 400 messages
% per source at 1 packet/s, two network transmissions, TTL 127, a 10 ms
% Scan Interval and Stateful Preemption.
%
% Requires ConfigurableGAPBearer.m and CustomMeshNode.m on the path.
%
% Note: This script has only been verified to work with MATLAB R2025b.
%
% --- RUN -----------------------------------------------------------------
%   RelayStrategy           0 = Without, 1 = Stateless, 2 = Stateful
%   ScanInterval            T_si, in seconds
%   Seed                    Seed of the random generator
%   RandomStream            Generator used by rng
%   PlotTopology            Draw the network map
%   PlotResults             Draw the PDR/latency figure of the run, in the
%                           layout of the reference figures
%   Verbose                 Print the header, progress and results
%
% --- TRAFFIC -------------------------------------------------------------
%   PacketsPerSource        Application messages per source
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
%   EnablePreemptionLog     Print Suspended/Resumed events of every node
%   EnableAdvEventLog       Print the T_ChPDU gaps of every advertising event
%
% --- OUTPUT --------------------------------------------------------------
%   results  Struct with PDR, Latency, Tx, Rx, their per-pair breakdown,
%            the node IDs, the elapsed wall-clock time and the configuration
%   nodes    The array of CustomMeshNode objects, for further inspection
%
% --- EXAMPLES ------------------------------------------------------------
%   % Reference protocol
%   results = runPreemptionSimulation();
%
%   % Reduced run
%   results = runPreemptionSimulation( ...
%       RelayStrategy = 2, ScanInterval = 100e-3, ...
%       PacketsPerSource = 100, ...
%       NetworkTransmissions = 1);
%
%   % Reduced run with logs, to verify the mechanism
%   results = runPreemptionSimulation( ...
%       RelayStrategy = 2, ScanInterval = 100e-3, PacketsPerSource = 5, ...
%       EnablePreemptionLog = true, EnableAdvEventLog = true);
%
%   % Four source-destination pairs
%   results = runPreemptionSimulation( ...
%       RelayStrategy = 2, ScanInterval = 100e-3, ...
%       PacketsPerSource = 50, ...
%       SourcePositions = [0 20; 32  4; 20 24; 12  0], ...
%       DestPositions   = [0  4; 32 20; 20  0; 12 24]);
%
%   % Same run with the rotation reshuffled at every advertising event
%   results = runPreemptionSimulation( ...
%       RelayStrategy = 2, ScanInterval = 100e-3, ...
%       FixedChannelOrder = false, PacketsPerSource = 50, ...
%       SourcePositions = [0 20; 32  4; 20 24; 12  0], ...
%       DestPositions   = [0  4; 32 20; 20  0; 12 24]);

arguments
    % --- RUN -------------------------------------------------------------
    opts.RelayStrategy           (1,1) double  {mustBeMember(opts.RelayStrategy, [0 1 2])} = 2
    opts.ScanInterval            (1,1) double  {mustBePositive} = 10e-3
    opts.Seed                    (1,1) double  = 1
    opts.RandomStream            (1,1) string  = "twister"
    opts.PlotTopology            (1,1) logical = true
    opts.PlotResults             (1,1) logical = true
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

t0 = tic;
strategyNames = ["Without Preemption", "Stateless Preemption", "Stateful Preemption"];

%% 1. CROSS-PARAMETER VALIDATION AND DERIVED QUANTITIES
nPairs = size(opts.SourcePositions, 1);

if size(opts.DestPositions, 1) ~= nPairs
    error('runPreemptionSimulation:PairMismatch', ...
        'SourcePositions and DestPositions must have the same number of rows (%d vs %d).', ...
        nPairs, size(opts.DestPositions, 1));
end

if opts.AdvMinGap >= opts.AdvMaxGap
    error('runPreemptionSimulation:AdvGaps', ...
        'AdvMinGap (%g ms) must be smaller than AdvMaxGap (%g ms).', ...
        opts.AdvMinGap, opts.AdvMaxGap);
end

% The generator emits BurstSize messages per On-Off cycle, so PacketRate is
% the rate of the cycles: with the default BurstSize = 1 it is the message
% rate, and with BurstSize > 1 it is the burst rate.
period = 1 / opts.PacketRate;

if mod(opts.PacketsPerSource, opts.BurstSize) ~= 0
    error('runPreemptionSimulation:BurstSize', ...
        'PacketsPerSource (%g) must be an integer multiple of BurstSize (%d).', ...
        opts.PacketsPerSource, opts.BurstSize);
end

nBursts = opts.PacketsPerSource / opts.BurstSize;

if opts.TrafficOnTime >= period
    error('runPreemptionSimulation:OnTime', ...
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
    error('runPreemptionSimulation:DrainTime', ...
        'DrainTime (%g s) cannot exceed the cycle period (%g s), or the last burst is never generated.', ...
        drainTime, period);
end

if opts.SimTime > 0
    simTime = opts.SimTime;  % Explicit override: the message count follows
else
    simTime = nBursts * period - drainTime;
end

if simTime <= opts.TrafficOnTime
    error('runPreemptionSimulation:SimTimeTooShort', ...
        'The run (%g s) is not longer than the burst itself (%g s): raise SimTime or lower TrafficOnTime.', ...
        simTime, opts.TrafficOnTime);
end

% Messages actually generated per source, given the resulting run length. A
% burst that starts before the end of the run is counted in full, since its
% On period is short compared with the cycle.
msgPerSource = (floor(simTime / period) + 1) * opts.BurstSize;

if opts.AdvertisingInterval <= opts.AdvMaxGap * 1e-3
    warning('runPreemptionSimulation:AdvGapTooLarge', ...
        'AdvMaxGap (%g ms) does not fit inside AdvertisingInterval (%g ms): T_ChPDU values will be clipped.', ...
        opts.AdvMaxGap, opts.AdvertisingInterval * 1000);
end

% Rotation actually in use, reported in the header
if opts.RandomAdvertising && ~opts.FixedChannelOrder
    channelOrder = "randomised";
else
    channelOrder = "fixed 37-38-39";
end

% Set the seed to ensure stable and reproducible results
rng(opts.Seed, char(opts.RandomStream));

if opts.Verbose
    fprintf('\n======================================================\n');
    fprintf('   BLE Mesh Simulation Initialized\n');
    fprintf('======================================================\n');
    fprintf(' Relay Strategy : %s\n', strategyNames(opts.RelayStrategy + 1));
    fprintf(' Scan Interval  : %.2f ms\n', opts.ScanInterval * 1000);
    fprintf(' Topology       : %dx%d grid, %g m spacing, %d pairs, %g m range\n', ...
        opts.GridRows, opts.GridCols, opts.NodesDistance, nPairs, opts.ReceiverRange);
    if opts.BurstSize > 1
        fprintf(' Traffic        : %d-packet bursts @ %g Hz, %g B, %d messages/source\n', ...
            opts.BurstSize, opts.PacketRate, opts.PacketSize, msgPerSource);
    else
        fprintf(' Traffic        : %g pkt/s, %g B, %d messages/source\n', ...
            opts.PacketRate, opts.PacketSize, msgPerSource);
    end
    fprintf(' Mesh           : TTL %d\n', opts.TTL);
    fprintf(' Network Tx     : %d transmission(s) per originated message @ %g ms\n', ...
        opts.NetworkTransmissions, opts.NetworkTransmitInterval*1000);
    if opts.RelayEnabled
        fprintf(' Relay Tx       : %d transmission(s) per relayed message @ %g ms\n', ...
            opts.RelayRetransmissions, opts.RelayRetransmitInterval*1000);
    else
        fprintf(' Relay Tx       : relay feature disabled on the grid nodes\n');
    end
    fprintf(' Link Layer     : ADV %g ms, T_ChPDU [%g, %g] ms, Random %d\n', ...
        opts.AdvertisingInterval*1000, opts.AdvMinGap, opts.AdvMaxGap, opts.RandomAdvertising);
    fprintf(' Channel Order  : %s\n', channelOrder);
    fprintf(' Duration       : %.2f s (%.2f s drain window), seed %d\n', ...
        simTime, simTime - (floor(simTime/period)*period + opts.TrafficOnTime), opts.Seed);
    fprintf('======================================================\n\n');
end

%% 2. CREATE THE GRID TOPOLOGY
% Relays occupy a GridRows-by-GridCols lattice; sources and destinations are
% appended afterwards, so the node IDs are:
%   1 : numRelays                       -> relays
%   numRelays + (1:nPairs)              -> sources
%   numRelays + nPairs + (1:nPairs)     -> destinations
[X, Y] = meshgrid(0:opts.NodesDistance:(opts.GridCols-1)*opts.NodesDistance, ...
                  0:opts.NodesDistance:(opts.GridRows-1)*opts.NodesDistance);
relayPositions = [X(:), Y(:)];
numRelays = size(relayPositions, 1);

allPositions = [relayPositions; opts.SourcePositions; opts.DestPositions];
numTotalNodes = size(allPositions, 1);

srcIDs = numRelays + (1:nPairs);
dstIDs = numRelays + nPairs + (1:nPairs);

%% 3. INITIALIZE SIMULATOR
% init also resets the singleton, so consecutive calls of this function do
% not inherit the nodes of one another.
simulator = wirelessNetworkSimulator.init;

%% 4. CREATE AND CONFIGURE NODES
% Use the CustomMeshNode subclass to inject the ConfigurableGAPBearer
nodes = CustomMeshNode.empty(0, numTotalNodes);

for i = 1:numTotalNodes
    % Configure Mesh Profile
    meshCfg = bluetoothMeshProfileConfig( ...
        ElementAddress = dec2hex(i, 4), ...
        NetworkTransmissions = opts.NetworkTransmissions, ...
        NetworkTransmitInterval = opts.NetworkTransmitInterval, ...
        TTL = opts.TTL);

    % Enable Relay for the grid nodes. The retransmission parameters only
    % exist on the object once the Relay feature is turned on.
    if opts.RelayEnabled && i <= numRelays
        meshCfg.Relay = true;
        meshCfg.RelayRetransmissions = opts.RelayRetransmissions;
        meshCfg.RelayRetransmitInterval = opts.RelayRetransmitInterval;
    end

    % Create Node using the custom subclass
    nodes(i) = CustomMeshNode("broadcaster-observer", ...
        MeshConfig = meshCfg, ...
        Position = [allPositions(i, :) 0], ...
        Name = "Node_" + i, ...
        TransmitterPower = opts.TransmitterPower, ...
        ReceiverRange = opts.ReceiverRange, ...
        AdvertisingInterval = opts.AdvertisingInterval, ...
        ScanInterval = opts.ScanInterval, ...
        RandomAdvertising = opts.RandomAdvertising, ...
        FixedChannelOrder = opts.FixedChannelOrder, ...
        RelayStrategy = opts.RelayStrategy, ...
        RandomAdvMinGap = opts.AdvMinGap, ...
        RandomAdvMaxGap = opts.AdvMaxGap, ...
        EnablePreemptionLog = opts.EnablePreemptionLog, ...
        EnableAdvEventLog = opts.EnableAdvEventLog);
end

%% 5. NETWORK TOPOLOGY MAP
if opts.PlotTopology
    if opts.Verbose
        fprintf('Drawing the network topology map...\n');
    end
    results.figure = plotTopology(relayPositions, opts.SourcePositions, ...
        opts.DestPositions, opts.NodesDistance, opts.ReceiverRange);
end

%% 6. CONFIGURE TRAFFIC
% BurstSize packets per On-Off cycle: the data rate is derived so that
% OnTime carries exactly that many packets, and OffTime completes the cycle.
% With the defaults this is 120 kb/s for 1 ms, i.e. one 15-byte packet, and
% a 0.999 s idle time that closes the 1.0 s cycle.
if opts.Verbose
    if opts.BurstSize > 1
        fprintf('Configuring %d-packet bursts every %g s for %d Source/Destination pairs...\n', ...
            opts.BurstSize, period, nPairs);
    else
        fprintf('Configuring %g packet/sec traffic for %d Source/Destination pairs...\n', ...
            opts.PacketRate, nPairs);
    end
end

for p = 1:nPairs
    traffic = networkTrafficOnOff( ...
        DataRate = dataRate, ...
        PacketSize = opts.PacketSize, ...
        GeneratePacket = true, ...
        OnTime = opts.TrafficOnTime, ...
        OffTime = period - opts.TrafficOnTime);

    addTrafficSource(nodes(srcIDs(p)), traffic, ...
        SourceAddress = nodes(srcIDs(p)).MeshConfig.ElementAddress, ...
        DestinationAddress = nodes(dstIDs(p)).MeshConfig.ElementAddress, ...
        TTL = opts.TTL);
end

%% 7. RUN SIMULATION
if opts.Verbose
    fprintf('[%s] Running simulation for %g seconds...\n', ...
        string(datetime('now', 'Format', 'HH:mm:ss')), simTime);
end

addNodes(simulator, nodes);
run(simulator, simTime);

if opts.Verbose
    fprintf('[%s] Simulation complete.\n', string(datetime('now', 'Format', 'HH:mm:ss')));
end

%% 8. POST-SIMULATION ANALYSIS (PDR AND LATENCY)
% Counters are kept per source-destination pair, not only aggregated, so
% that the breakdown of each pair remains available.
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
results.PDR = 100 * sum(rxPair) / max(sum(txPair), 1);

% The reference work averages the per-pair latency curves arithmetically,
% so the same convention is used here for comparability with its figures.
results.Latency = mean(latPair, 'omitnan');

results.Strategy     = strategyNames(opts.RelayStrategy + 1);
results.ScanInterval = opts.ScanInterval;
results.Seed         = opts.Seed;
results.Tx           = sum(txPair);
results.Rx           = sum(rxPair);
results.TxPair       = txPair;
results.RxPair       = rxPair;
results.LatPair      = latPair;
results.SrcIDs       = srcIDs;
results.DstIDs       = dstIDs;
results.SimTime      = simTime;
results.Elapsed      = toc(t0);
results.Config       = opts;

%% 9. PERFORMANCE FIGURE
% Same layout as the campaign figure, with the single operating point of
% this run marked on both axes.
if opts.PlotResults
    results.performanceFigure = plotPerformance(results, opts);
end

if opts.Verbose
    fprintf('\n--- Performance Results: %s, T_SI = %.0f ms, NetTx %d, RelayTx %d ---\n', ...
        results.Strategy, opts.ScanInterval * 1000, ...
        opts.NetworkTransmissions, opts.RelayRetransmissions);

    for p = 1:nPairs
        fprintf('Pair %d (Node %d -> %d): Tx=%d, Rx=%d, PDR=%.2f%%\n', ...
            p, srcIDs(p), dstIDs(p), txPair(p), rxPair(p), ...
            100 * rxPair(p) / max(txPair(p), 1));
    end

    fprintf('\nOVERALL RESULTS:\n');
    fprintf('Total Transmitted / Received: %d / %d\n', results.Tx, results.Rx);
    fprintf('Aggregate Packet Delivery Ratio (PDR): %.2f %%\n', results.PDR);
    fprintf('Average End-to-End Latency: %.4f seconds\n', results.Latency);
    fprintf('Wall-clock time: %.1f min\n', results.Elapsed / 60);
end
end

%% ========================================================================
function fig = plotPerformance(results, opts)
% Draws the PDR and the end-to-end latency of this run against the Scan
% Interval, with the layout of Figs. 11 and 17 of the reference paper: PDR
% in blue on the left axis, latency in red on the right axis, and one line
% style per relaying strategy (solid = without, dashed = stateless,
% dotted = stateful).
%
% A single run is a single operating point, so it is drawn as a marker; the
% campaign function sweeps the Scan Interval and produces the full curves.

styles = {'-', '--', ':'};
widths = [1.5, 1.2, 1.5];
legendNames = ["Without Preemption", "With Stateless Preemption", ...
               "With Stateful Preemption"];

k     = mod(opts.RelayStrategy, numel(styles)) + 1;
tsiMs = opts.ScanInterval * 1000;

% Axis span of the reference figures, widened if this point falls outside it
xMax = max(200, ceil(tsiMs / 20) * 20);
yTop = max(2, ceil(results.Latency / 0.2) * 0.2);

fig = figure('Name', 'BLE Mesh: PDR and Latency vs Scan Interval', ...
             'Color', 'w', 'Position', [200, 200, 650, 450]);
hold on;

% --- LEFT AXIS: PDR ------------------------------------------------------
yyaxis left
plot(tsiMs, results.PDR, 'Color', 'b', 'LineStyle', styles{k}, ...
    'LineWidth', widths(k), 'Marker', 'o', 'MarkerSize', 6, ...
    'MarkerFaceColor', 'b', 'HandleVisibility', 'off');
ylabel('PDR (%)', 'Interpreter', 'none');
ylim([0, 100]);
yticks(0:10:100);

% --- RIGHT AXIS: LATENCY -------------------------------------------------
yyaxis right
plot(tsiMs, results.Latency, 'Color', 'r', 'LineStyle', styles{k}, ...
    'LineWidth', widths(k), 'Marker', 's', 'MarkerSize', 6, ...
    'MarkerFaceColor', 'r', 'HandleVisibility', 'off');
ylabel('Latency (s)', 'Interpreter', 'none');
ylim([0, yTop]);
yticks(0:0.2:yTop);

hLeg = plot(nan, nan, 'Color', 'k', 'LineStyle', styles{k}, ...
    'LineWidth', widths(k));

% --- COSMETICS -----------------------------------------------------------
ax = gca;
ax.YAxis(1).Color = 'b';
ax.YAxis(2).Color = 'r';
xlabel('ScanInterval (ms)', 'Interpreter', 'none');
xlim([0, xMax]);
xticks(unique(round(linspace(0, xMax, 11), 4)));
grid on;

legend(hLeg, legendNames(opts.RelayStrategy + 1), 'Location', 'southeast', ...
    'FontSize', 8, 'Interpreter', 'none');
title(sprintf('Grid topology (Coverage range: %g m)', opts.ReceiverRange), ...
    'Interpreter', 'none');

hold off;
drawnow;
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
