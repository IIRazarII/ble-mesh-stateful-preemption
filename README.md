# BLE Mesh Relay Mechanisms — Stateful Preemption

MATLAB implementation of the three relaying mechanisms described in:
> A. Belli, M. Esposito, S. Raggiunto, L. Palma, P. Pierleoni,
> "Relaying Mechanisms in BLE Mesh Networks: A Method for Improving Latency and Reliability," *IEEE Internet of Things Journal*, vol. 12, no. 12, pp. 22282–22297, June 2025.
> DOI: [10.1109/JIOT.2025.3550831](https://doi.org/10.1109/JIOT.2025.3550831)

As of the R2025b release, the MATLAB Bluetooth Toolbox natively supports only
two of the three mechanisms: relaying without preemption, and stateless
preemption through the `PreemptiveScanning` property. Stateful
preemption is not available. This repository adds it by subclassing the toolbox
link layer, together with a configurable `T_ChPDU` range so that the advertising
inter-PDU separation can be set to the 1–10 ms interval used in the paper
instead of the toolbox default. It also splits apart the two behaviours that
the toolbox controls through a single `RandomAdvertising` flag, namely the
randomisation of `T_ChPDU` and the reshuffling of the advertising channel
rotation, because the paper randomises the first while keeping the standard
37-38-39 order for the second.

R2025b is also the only release the code has been verified against. The
subclasses rely on undocumented toolbox internals, so both the gap being filled
and the way it is filled may no longer hold on other releases.

## Requirements

- MATLAB R2025b
- Bluetooth Toolbox
- Communications Toolbox
- Parallel Computing Toolbox (for `runPreemptionCampaign`; set `UseParallel = false` to run serially)

All `.m` files must sit in the same folder (or on the MATLAB path).

## Files

| File | Purpose |
| --- | --- |
| `ConfigurableGAPBearer.m` | Link layer bearer. Subclasses `ble.internal.linkLayerGAPBearer` and implements the save/restore logic for stateful preemption, plus the configurable `T_ChPDU` gaps and the option to pin the channel rotation. |
| `CustomMeshNode.m` | Node wrapper. Subclasses `bluetoothLENode` and swaps its internal `pLinkLayer` for a `ConfigurableGAPBearer`, exposing the new options as name-value pairs. |
| `runPreemptionSimulation.m` | Single simulation on the Experiment D topology (grid, 20 relays, 2 source/destination pairs). Plots the network layout and prints per-pair and aggregate PDR and end-to-end latency. Useful for inspecting one configuration, with the tracing options switched on. |
| `runPreemptionCampaign.m` | Measurement campaign over the same topology. Sweeps the Scan Interval across the three strategies, replicates each configuration over several seeds, and reports PDR and latency with 95% confidence intervals. |

## Running a single simulation

Every parameter is a name-value argument, so there is nothing to edit in the
file. Calling the function with no arguments reproduces the Experiment D
protocol with stateful preemption and a 10 ms Scan Interval.

```matlab
% Reference protocol
results = runPreemptionSimulation();

% Four source-destination pairs instead of two
results = runPreemptionSimulation( ...
    RelayStrategy = 2, ScanInterval = 100e-3, ...
    PacketsPerSource = 50, ...
    SourcePositions = [0 20; 32  4; 20 24; 12  0], ...
    DestPositions   = [0  4; 32 20; 20  0; 12 24]);

% Reduced run with tracing switched on, to inspect the mechanism
results = runPreemptionSimulation( ...
    RelayStrategy = 2, ScanInterval = 100e-3, PacketsPerSource = 5, ...
    EnablePreemptionLog = true, EnableAdvEventLog = true);
```

It returns a `results` struct with PDR, latency, the per-pair breakdown and
the configuration used, together with the array of `CustomMeshNode` objects
for further inspection.

| Argument | Meaning |
| --- | --- |
| `RelayStrategy` | `0` without preemption, `1` stateless, `2` stateful |
| `ScanInterval` | T_SI in seconds. The paper sweeps 10–200 ms in 10 ms steps |
| `PacketsPerSource` | Application messages per source |
| `PacketRate` | Cycles per second, per source. With the default `BurstSize = 1` this is the message rate |
| `BurstSize` | Messages emitted back-to-back in each cycle. Must divide `PacketsPerSource` exactly |
| `TrafficOnTime` | On period of the generator, in seconds |
| `DrainTime` | Tail of the run with no new messages (`0` = half a packet period), so the last message is not counted as transmitted without a chance to arrive |
| `SimTime` | Explicit run length in seconds; `0` derives it from `PacketsPerSource`, `PacketRate` and `DrainTime` |
| `ReceiverRange` | Coverage range in metres (9 or 16 in the paper) |
| `AdvMinGap` | Lower T_ChPDU bound in ms (1 in the paper) |
| `AdvMaxGap` | Upper T_ChPDU bound in ms (10 in the paper) |
| `RandomAdvertising` | Toolbox flag: randomises the T_ChPDU gaps *and* reshuffles the channel rotation |
| `FixedChannelOrder` | Keep the 37-38-39 rotation while still randomising T_ChPDU. `true` by default, as in the paper |
| `SourcePositions` / `DestPositions` | One row per source-destination pair, in metres. Paired row by row |
| `Seed` | Seed of the random generator |
| `RandomStream` | Generator used by `rng` |
| `PlotTopology` | Draw the network map |
| `PlotResults` | Draw the PDR and latency figure of the run |
| `Verbose` | Print the header, progress and results |
| `EnablePreemptionLog` | Print every scan suspension and resumption, with remaining T_RSI and channel |
| `EnableAdvEventLog` | Print the T_ChPDU gaps drawn for each ADV event |

The generator is seeded with `rng(1, "twister")` by default, so a given
configuration is reproducible. A single run leaves a few percentage points of
spread in PDR, which is why comparing strategies is better done through the
campaign.

## Running a campaign

```matlab
% Reference protocol: 10–200 ms in 10 ms steps, 400 messages per source,
% 12 replications per configuration. 720 simulations — expect days.
[summary, raw] = runPreemptionCampaign();

% Reduced campaign: ~6 hours on an 8-core consumer CPU
[summary, raw] = runPreemptionCampaign( ...
    ScanIntervals = [10 20 40 60 100 150 200]*1e-3, ...
    PacketsPerSource = 100, Seeds = 1:8, NumWorkers = 8);

% Same campaign with the rotation reshuffled at every advertising event,
% as a control against the fixed-rotation result
[summary, raw] = runPreemptionCampaign( ...
    ScanIntervals = [10 20 40 60 100 150 200]*1e-3, ...
    FixedChannelOrder = false, ...
    PacketsPerSource = 100, Seeds = 1:8, NumWorkers = 8, ...
    ResultFile = "campaign_reduced_random.mat");
```

The defaults reproduce the measurement protocol of the paper, so calling the
function with no arguments is the faithful but expensive option. Reducing the
sweep, the messages per source and the number of replications leaves the
topology, radio parameters and offered load untouched; each replication is a
shorter observation of the same network, and the aggregate message count is
recovered across replications.

The function returns a summary table and the raw per-replication data, plots
PDR and latency against the Scan Interval, and writes a checkpoint after every
configuration so an interrupted campaign is not lost. Note that it does not
resume from that file on restart.

| Argument | Meaning |
| --- | --- |
| `Strategies` | Any of `0` without preemption, `1` stateless, `2` stateful |
| `ScanIntervals` | Vector of T_SI values in seconds |
| `Seeds` | One independent replication per seed |
| `PacketsPerSource` | Application messages per source, per replication |
| `AdvMinGap` / `AdvMaxGap` | T_ChPDU bounds in ms |
| `FixedChannelOrder` | Keep the 37-38-39 rotation while still randomising T_ChPDU. `true` by default, as in the paper |
| `SourcePositions` / `DestPositions` | One row per source-destination pair, in metres. Paired row by row |
| `NumWorkers` | Pool size; keep it equal to the seed count to avoid a partial wave |
| `Plot` / `ShowCI` | Draw the figure, with or without error bars |
| `ResultFile` | Checkpoint path |

Each replication seeds its own generator, so a campaign is reproducible: the
same seeds and configuration return the same numbers. Confidence intervals come
from the spread across replications, using the independent-replications method.
Tracing is left off here, as output from concurrent workers interleaves.

## Relay strategies

All three share the same node configuration and differ only in how the
transition from scanning to advertising is handled at the relay:

- **0 — Without preemption.** The relay finishes the current Scan Interval
before forwarding. This is the plain toolbox behaviour. Best PDR, but latency
grows with the Scan Interval.
- **1 — Stateless preemption.** Scanning is aborted as soon as a packet is
queued for relaying; afterwards a *new* scanning event starts, from the first
channel of the rotation and with a full Scan Interval. Under the default fixed
rotation that first channel is always 37, so 38 and 39 are starved whenever
relaying is frequent. This is what `PreemptiveScanning = true` already does in
the toolbox. Low latency, degraded PDR.
- **2 — Stateful preemption.** Scanning is still preempted, but the channel,
the position in the channel rotation and the remaining Scan Interval
(`T_RSI`) are saved beforehand and restored afterwards, so that each channel
is listened to for the full nominal Scan Interval even when split across
several scanning events (Fig. 5 of the paper). Low latency with PDR close to
the no-preemption case.

Only strategy 2 required new code; strategies 0 and 1 are selected by
configuring the base class.

The gap between 1 and 2 only exists while the rotation is fixed. With
`FixedChannelOrder = false` the base class reshuffles it at every advertising
event, so stateless preemption resumes on an arbitrary channel instead of
restarting from 37 — which is precisely the failure the stateful mechanism
corrects — and the two strategies converge to within the confidence intervals.
That configuration is worth running as a control, but it is not the one the
paper describes.

## Notes on the setup

The toolbox exposes a single `RandomAdvertising` flag that governs both the
`T_ChPDU` randomisation and the reshuffling of the channel rotation, so the
combination the paper uses — random `T_ChPDU`, standard scanning order, with
random channel selection listed as future work — is not reachable through that
flag alone. `FixedChannelOrder` supplies it and defaults to `true` in both
runners, so their shipped defaults match the reference measurement protocol.
The `ConfigurableGAPBearer` and `CustomMeshNode` classes keep it at `false`
instead, so that instantiating them directly still reproduces plain toolbox
behaviour, in the same way that `RelayStrategy` defaults to `0` there.

The paper does not state the relay retransmission count, which the Mesh
specification keeps separate from the network transmission count. It is left at
the toolbox default of a single transmission here.

Scan Interval values below 10 ms fall outside the range examined in the paper.
With `T_ChPDU` up to 10 ms an advertising event can span several such
intervals, so the residual scan time restored by the stateful mechanism becomes
a small fraction of a window and the comparison loses its meaning.
