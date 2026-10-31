# System monitor — design (Phase 6)

Date: 2026-10-28. Status: approved in conversation; awaiting review of this written spec.

## Goal

Record system-wide CPU, GPU, memory, network, disk and battery activity, so GhostTrace can explain past incidents: what drained the battery, what used the network, what filled or wrote to the disk, and why the CPU or GPU stayed busy. Add a live view while the window is open, plus four alerts. Keep the recorder at about 5 MB and near-zero CPU.

**Agreed scope.** History for investigations, a live view in the window, and alerts. Out of scope: live readouts in the menu bar, user-set thresholds, quiet hours, and alerts that leave the Mac.

## Feasibility (probed on this Mac, macOS 26, Apple Silicon, no admin rights)

| Metric | API | Cost | Caveat |
|---|---|---|---|
| CPU, system | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` ticks | 44 µs | — |
| Network, system | `sysctl NET_RT_IFLIST2` (`if_msghdr2`, 64-bit bytes) | 0.3 ms | `getifaddrs` `if_data` is 32-bit and wraps at 4 GiB, so it isn't used |
| Network, per process | `/usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out` | 5 s wall, about 0 CPU, 4 MB | Covers only processes with recent connections; what the counts include is undocumented |
| Disk | IOKit `IOBlockStorageDriver` "Statistics" (bytes and ops read and written); `volumeAvailableCapacityForImportantUsage` | 0.5 ms | No SMART or health data |
| GPU | IOKit `IOAccelerator` "PerformanceStatistics": "Device Utilization %", "In use system memory" | 0.15 ms | Undocumented keys; no per-process figure |
| Battery | `IOPSCopyPowerSourcesInfo` (state, charge, time to empty); `AppleSmartBattery` Amperage × Voltage → watts | small | Absent on desktops |
| Per process | `proc_pid_rusage(RUSAGE_INFO_V6)`: `ri_energy_nj`, `ri_diskio_bytesread`/`written` | already called | Own processes only (EPERM otherwise) |
| User idle | IOKit `IOHIDSystem` "HIDIdleTime" | — | **Not probed yet**: probe at the start of step 3 |

## 1. Data model and collection

All system reads go behind an injectable probe of closures (the `SystemProbe` pattern), so tests never touch IOKit.

`ResourceSample` gets new optional fields, so older rows still decode and a metric that can't be read is left out:
- `cpuBusy`, `cpuPeak`: average busy fraction since the last stored sample, and the highest single check.
- `gpuUtilization`, `gpuPeak`, `gpuMemoryInUse`.
- `networkIn`, `networkOut`: bytes since the last stored sample, summed over interfaces except `lo0`. Plus `networkPeakRate`: the fastest check, in bytes/s.
- `diskRead`, `diskWritten`, `diskPeakRate`, `freeSpace` (startup volume).
- `onBattery`, `charge` (%), `watts`, `minutesToEmpty`. All absent without a battery.

`ProcessSample` gains `energy` (average watts since the last stored sample), `diskRead` and `diskWritten`, for the processes a sample already lists.

Counters are cumulative, so a delta is current − previous. A current value below the previous one means a reset (a reboot, or an interface coming back): the delta restarts from the current value, and the sample notes the reset.

**Store triggers.** The check stays at 30 s and the heartbeat at 10 min. A sample is stored when an existing trigger fires (memory ±1 GB, a process ±512 MB, a pressure change) or any of these:
- the power source changed;
- the charge dropped 5 points since the last stored sample;
- CPU or GPU crossed 80% in either direction;
- network or disk crossed 10 MB/s in either direction;
- free space dropped 1 GB.

**Capability rows:**
- GPU utilization: unverified (undocumented keys).
- Battery: observed or missing.
- Per-process network: on demand only (§4).
- Per-process GPU: missing.
- SSD health: missing.
- User idle: observed or missing.

## 2. Live view

- **`Request.Method.live`.** Read-only (`isReadOnly`). It returns `LiveMetrics`: a timestamp; the cumulative CPU ticks (busy, total), network bytes (in, out) and disk bytes (read, written); and the current GPU %, memory used, memory pressure, free space and battery. Nothing is stored. Rates are worked out by the client from two answers, so the recorder keeps no state for each client.
- **App, new "System" pane.** It has six tiles: CPU, GPU, Memory, Network, Disk and Battery. Each shows the current value and a 5-minute sparkline kept in memory. It polls `live` every 2 s, only while the pane is visible, and stops when you switch panes, close the window or the Mac sleeps. A tile whose metric is unavailable shows the capability row's reason. Below the tiles: a 1 h, 24 h or 7 d history from `resources`, and an "Explain this range" button for battery, network and disk. Built with the existing Figma-based components. The Memory pane is unchanged.
- **`ResourceSummary`.** Its downsampled series gains CPU, GPU, network rate, disk rate, charge and free space. MCP `get_resource_usage` returns these automatically.
- **CLI.** `ghosttrace system [--last D | --from T [--to T]] [--json]` prints the history summary. `live` isn't exposed to the CLI or MCP.
- **On/off switch** (added 2026-10-28 at the user's request). "Record System Activity", on by default, persisted by the recorder.
  - **When off, these stop:** CPU, GPU, network, disk and battery readings; per-process energy and disk I/O; alerts; `nettop` snapshots; and the System pane's polling.
  - **These keep recording:** memory samples (Phase 4), wakes, launches and file changes.
  - **The off span is recorded as a gap**, so investigators report it as missing data, never as "nothing happened".
  - **Where it is:** a menu bar checkmark next to "Show Alerts", `ghosttrace config --system on|off`, and a switch at the top of the System pane. MCP can't change it (it's a write).

## 3. Alerts

**Rules.** The recorder evaluates them on every check, never while paused.

| Rule | Starts when | Ends when | Names |
|---|---|---|---|
| `battery_drain` | On battery, and the drop over the last 10 min (at least 3 checks) projects empty in under 2 h | Plugged in, or projection over 3 h | Top 3 energy users among your processes; the rest is "not measurable" |
| `disk_full` | Free space under 10 GB or under 5% | Over 15 GB and over 7.5% | Free space; the largest writers over the last day |
| `memory_critical` | Pressure is critical | Below critical for 5 min | Largest processes by memory |
| `sustained_load` | CPU or GPU ≥ 80% on every check for 5 min, while you've been idle ≥ 5 min | Under 60% for 2 checks | Top CPU users; for GPU, "which process is unknown" |

- **Once per incident:** each rule has a started/ended state, plus a 1-hour cooldown after it ends.
- **Recent checks** for the 10-minute and 5-minute windows are kept in memory: the last 20 checks, a few KB. They are not stored, so a recorder restart starts the windows again.
- **Without the idle reading:** `sustained_load` drops the idle condition, and the capability row says so.

**Delivery:**
- **Stored:** each start and end is a new `EventKind.alert` event, with its payload: the rule, the state, the values, and the ids of the samples it was based on.
- **Notified:** after storing, the recorder calls `notify_post("com.amoghkhairate.GhostTrace.alert")`. The menu bar app listens with `notify_register_dispatch`, fetches recent alert events over IPC, and posts a `UNUserNotification`. Clicking it opens the window on that alert.
- **A new event kind:** the decoder rejects unknown kinds, so older clients can't read `alert` events. The app, CLI and recorder ship together, so they always match; the release zip and the reinstall keep them in step.
- **Menu toggle:** "Show Alerts", on by default. Notification permission is requested when Show Alerts is turned on, and at the first alert if still undetermined (changed 2026-10-30 at the user's request).
- **If the menu bar app isn't running,** the alert is still stored and visible in the Timeline, Overview, `events --kind alert` and MCP.

## 4. Investigators

All three are pure `InvestigationKit` types. Each takes events plus coverage and returns findings labelled observed / likely / correlated / unknown, with evidence ids and limits. Windows are up to 48 h. They're exposed as:
- the CLI: `ghosttrace investigate battery|network|disk`;
- IPC methods: `investigate_battery`, `investigate_network`, `investigate_disk`;
- read-only MCP tools of the same names;
- the app's "Explain this range" button.

**Battery:**
- **Sessions:** spans on battery, with start and end charge, %/h and average watts (observed).
- **Asleep:** drain between sleep and wake is reported separately (observed). Its cause is unknown, with dark wakes from the wake investigator cited as correlated.
- **Top energy users** among your processes, with shares (observed).
- **Coverage:** measured process energy ÷ battery energy ("your processes account for 38%").
- **Likely cause:** a process is the likely cause only when it alone accounts for more than 50% of battery energy; otherwise the main cause is unknown.
- Apps launched during a session are correlated only.

**Network:**
- **Spikes:** spans over 10 MB/s, or more than 100 MB between two samples (observed: bytes in and out, duration).
- **Snapshots:** the recorder runs `nettop` when traffic crosses 10 MB/s upward and again when it drops back (at most once every 5 min, off the writer queue). Each run is stored as a `diagnostic` event (`source: nettop`).
- **Attribution:** the process with the largest growth between the two snapshots is likely. With no snapshots, the process is unknown.
- Spikes during dark wakes are correlated with the wake.
- **Limits:** `nettop` coverage and undocumented counts.

**Disk:**
- **Free-space drops:** 1 GB or more between samples (observed).
- **Write bursts:** over 10 MB/s (observed).
- **Top writers** among your processes, with shares (observed). A process is likely only when it accounts for more than 50% of system writes.
- **Coverage:** your writes ÷ system writes.
- **Where the space went:** file changes in watched folders during a drop are correlated; anything else is unknown.
- **Limits:** APFS snapshots, purgeable space and cache eviction change free space without writes. A drop with few bytes written is reported as such.

## 5. Testing, budget, delivery

- **Unit tests:**
  - counter deltas and resets;
  - each store trigger;
  - decoding samples stored before Phase 6;
  - the alert state machine (start, end, the easier end condition, cooldown, paused);
  - each investigator on synthetic data with misleading cases (a launch during a drain with no energy, a spike without snapshots, a drop without writes);
  - `live` and the new MCP tools being read-only.
- **Live checks:**
  - a real unplug session;
  - 6 min of `yes > /dev/null` on all cores while idle (the `sustained_load` alert);
  - a 2 GB scratch file written and deleted;
  - a large download, only after asking the user.
  - Disk-full and critical memory pressure are unit-tested only, never caused live.
- **Budget:**
  - Measured with `footprint` and `ps -o time`, with no accessibility tools attached, over 30 min after a reinstall.
  - The recorder stays about 5 MB and near-zero CPU, and the idle menu bar app doesn't grow.
  - The recorder's cost while the System pane polls is reported separately.
- **Delivery order.** Each step builds, passes tests and is checked live before the next:
  1. Sampler fields, triggers and capability rows.
  2. `live` and the System pane.
  3. Alerts.
  4. The battery, network and disk investigators with their CLI and MCP tools.
- **Records:** ADR 0007 records the decisions, and the plan's progress log gets the Phase 6 handoff.
