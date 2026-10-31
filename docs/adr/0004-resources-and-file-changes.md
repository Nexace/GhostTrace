# ADR 0004: Resource sampling and file changes (Phase 3)

Date: 2026-10-27. Status: accepted.

## Resource sampling

**Checked (on this Mac, macOS 27.0.1, M-series, 16 GB).**
- `proc_listallpids` returned 787 processes. `proc_pid_rusage(RUSAGE_INFO_V4)` and `proc_pidinfo(PROC_PIDTBSDINFO)` worked for the 563 owned by this user and failed for all 223 others (root and other system users), without privileges. `proc_pidpath` worked for nearly all.
- `ri_phys_footprint` matches Activity Monitor's "Memory". CPU times are in mach units (timebase 125/3 here), so they are converted.
- `host_statistics64(HOST_VM_INFO64)`, `hw.memsize`, `vm.swapusage` and `kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical) all work unprivileged.
- One pass over every process takes about 7 ms.

**Decision.**
- `ResourceSampler` takes one sample every 30 s by default (`ghosttrace config --sample-interval`, 5 s to 10 min, stored in `recorder_state`). Each sample is one `resource_sample` event with quality `sampled`. The sample is stored as JSON under `payload["sample"]`, with `memory_used` and `pressure` beside it for listings. This keeps `Event.payload` a string map and needs no schema change.
- A sample keeps the 10 largest processes by memory, the 5 busiest by CPU (at least 1%), and any process that grew by 256 MB or more since the previous sample. The sampler keeps the previous footprint and CPU time of *every* readable process in memory, so `footprintChange` and `cpu` are true per-process deltas even for a process that wasn't in the previous sample's list.
- Process identity is pid plus start time (`pbi_start_tvsec`), because pids are reused.
- Only the executable's file name is stored, not its path. Paths of app helpers made a sample 3.7 KB; without them it is 2.3 KB.

**Profiled targets** (release build, this Mac, 30 s interval, 5 minutes):
- under 1% of one core: measured 0.34%;
- under 50 MB resident: measured 15–20 MB;
- about 7 MB/day of database growth from samples: measured 2.3 KB a sample, which is 6.6 MB/day.

Thinning old samples is the next lever if storage matters.
- CPU % is CPU time over uptime (`CLOCK_UPTIME_RAW`), so time asleep doesn't dilute it.
- "Memory used" is app memory (internal minus purgeable) plus wired plus compressor pages, as Activity Monitor counts it.
- Processes that can't be read are counted (`unreadable`) and reported as a limit. GhostTrace doesn't ask for privileges to read them.

**Chart data.** `ResourceAnalyzer.summarize` (IPC `resources`, up to 7 days) buckets samples into at most 500 points with average and peak memory, worst pressure and peak swap. Empty buckets are left out, so a stretch with no samples isn't drawn as data.

**Gap detection.** Two samples more than 2.5 intervals apart (using the longer of the two intervals, so changing the interval isn't a gap) mark a sampling gap. Gaps are reported as limits and listed with times. Rises across a gap are never treated as spikes.

## Memory-spike investigations

A spike is a run of consecutive samples (no gap between them) where at least one of these happens between neighbours:
- memory pressure rises;
- memory in use rises by at least 10% of RAM (and at least 1 GB);
- one process grows by at least 1 GB. A process started since the previous sample counts its whole footprint as growth.

| Finding | Confidence |
|---|---|
| Memory in use went from A to B; pressure went from X to Y | `observed` (macOS's measurements, cited by the two samples) |
| Process P grew by N, or started and reached N (at least 100 MB, top 5) | `observed` |
| P accounts for most of the rise (≥ 50% of it) | `likely`: GhostTrace's comparison. macOS doesn't attribute shared, cached or compressed memory to processes |
| No sampled process accounts for most of it | `unknown` |
| An app launched during the rise but didn't grow enough to be listed | `correlated` |

Processes that started after the rise are never considered. Recorder gaps during a spike are limits; power-log holes and dropped file changes are not, since they don't affect samples. Up to 48 hours per investigation, 20 spikes.

**Checked live.** A 2 GB Python allocation was sampled 5 s apart. The system's "used" rose only 0.8 GB, because macOS compressed other memory. The investigator reported Python as observed, starting during the rise and reaching 2.0 GB, and as the `likely` cause.

## File changes (FSEvents)

**Checked (on this Mac).** A stream with `kFSEventStreamCreateFlagFileEvents` on a temporary folder reported:
- **Paths are resolved.** `/var/folders/...` came back as `/private/var/folders/...`, so watched and queried paths are canonicalised with `realpath` (a missing item goes through its nearest existing parent). Foundation's `resolvingSymlinksInPath` strips `/private` and is not used.
- **Flags accumulate.** A plain append reported `created,modified,inode,xattr`. The `created` flag stays set on later changes to the same file.
- **Atomic writes** appear as a temporary `a.txt.sb-…` file plus `a.txt` records in the same delivery.
- **Renames** arrive as two records with consecutive event ids, the old path first.
- **A watched folder being deleted** produced `RootChanged` (with `WatchRoot`).
- No record carries a process or a timestamp.

**Decision.**
- `FileWatcher` runs one FSEvents stream on its own queue with 1 s latency, over the user's watched paths. Watched paths are stored in `recorder_state` with the time each was added, and changed with `ghosttrace watch add|remove` (IPC `watch_add`/`watch_remove`).
- Limits on watching:
  - At most 32 paths.
  - `/` is refused.
  - A path inside another watched one stays listed, keeping its own start time, but only the outer path goes to FSEvents.
- Each record becomes a `file_change` event:
  - subject `path`, `privacyClass` sensitive;
  - payload `changes` (flag names), `item` (file, folder or symlink) and `fsevent_id`;
  - `occurredAt` is delivery time, and the provenance says so.
- Changes under GhostTrace's own data folder are dropped, so the database can't feed itself.
- **Bounded.**
  - More than 200 records a second are dropped, and the drop is stored as an `event_gap` with reason `watch_dropped` and the count.
  - FSEvents' own `MustScanSubDirs`, `UserDropped` and `KernelDropped` flags also become `watch_dropped` gaps, from the last delivery to now.
- **No writer, ever.** FSEvents can't say who wrote a file. Every change gets an `unknown` finding: "Which process made this change is unknown." Apps launched up to 2 minutes before are `correlated` only. Naming a writer would need Endpoint Security, which stays out of scope (ADR 0001).
- **The file-change investigator** (`investigate_file_change`, up to 30 days):
  - It matches the path itself and anything under it.
  - Records for one path within 0.5 s are one change. They come in one delivery, as with atomic saves.
  - Renames are paired by consecutive ids (`likely`).
  - It reports as limits:
    - a path that isn't watched;
    - a watch that started inside the window;
    - recorder gaps and dropped changes.
- Historical FSEvents replay (`sinceWhen`) isn't used. Its records have no times, so changes made while the recorder was stopped stay unrecorded. That is reported through the recorder gaps.

**Unverified.** Delivery for TCC-protected folders (Desktop, Documents, Downloads) when the recorder lacks access to them. Nothing was written to those folders to test it.

## Other gaps closed

- **Power-log holes.** If the oldest power-log line in an import is newer than the previous import, the lines in between rolled off unread. GhostTrace records that span as an `event_gap` with reason `power_log_hole` (Phase 2 open item).

## Export

`ghosttrace export` pages through `events` (no new IPC method) and writes one JSON document: `apiVersion`, window, `redacted` and the events. By default `Event.redacted()` replaces two kinds of path with `redacted-` plus 12 hex characters of their SHA-256, so equal paths still match:
- sensitive events' subject paths;
- any `payload["path"]`.

`--include-sensitive` keeps them. `--output` creates the file with mode 0600 and refuses to overwrite.

## IPC

All additions are optional fields or new methods, so `IPC.apiVersion` stays 1:
- methods `resources`, `investigate_memory`, `investigate_file_change`, `watch_add`, `watch_remove`, `configure`;
- request fields `path`, `top`, `points`, `sampleInterval`;
- response fields `resources`, `memoryInvestigation`, `fileChangeInvestigation`;
- status fields `sampleInterval` and `watchedPaths`, optional so a Phase 2 recorder's status still decodes.

## Overhead pass (user targets: CPU near zero, recorder under 5 MB)

Measured with `footprint` (Activity Monitor's "Memory") and `ps` CPU time, release build, on this Mac.

**Storing samples only on change.**
- Memory is still checked every 30 s. A sample is stored only when one of these changed since the last stored sample:
  - memory in use, by 1 GB or more;
  - one process's footprint, by 512 MB or more (a new process counts from zero);
  - the pressure level.
- A sample is also stored at least every 10 minutes (`heartbeat`, stored in the sample).
- `footprintChange` and `cpu` are measured against the last *stored* sample, so growth across unstored checks isn't lost. CPU is the average since then.
- Gap detection allows the heartbeat plus 1.5 checks. Older samples have no heartbeat and keep the 2.5-check rule.
- On 2.8 hours of real samples this kept 42 of 337 rows (about 360 a day instead of 2,880).
- Each sample lists the top 6 processes by memory and the top 3 by CPU (was 10 and 5), plus any that changed by 512 MB or more.
- The thresholds were first 512 MB and 256 MB. In a 10-minute run, browser tabs and video decoding (Brave helpers, `VTDecoderXPCService`) swinging 270–670 MB stored 7 samples. Spikes start at 1 GB, so the finer steps bought nothing. The thresholds live in `ResourceSample` (`storeOnSystemChange`, `storeOnProcessChange`), shared by the sampler and the investigation wording.

**CPU.**
- A check calls `proc_pid_rusage` once per process. The identity key is pid plus `ri_proc_start_abstime`. `proc_pidinfo` and `proc_pidpath` run only for the processes listed, and only when a sample is stored. Before, it was three calls per process on every check.
- The ingestor no longer flushes on a 1 s timer. `Ingestor(whenBuffered:)` asks for a flush when the first event of a batch arrives, so an idle recorder doesn't wake up.
- The power log is imported daily (wall-clock timer) and at startup, not hourly. Investigations still import first.
  - `pmset`'s ~5 MB output is read in 64 KB chunks, and only the kept lines are kept.
  - Lines from before the previous import (less one hour) are skipped before any event is built.
- Timers have leeway, so macOS can batch the wake-ups.

**Memory.**
- Wake investigations fetch only `diagnostic`, `wake` and `app_launch` events (plus gaps), not memory samples.
- SQLite's page cache is capped at 512 KB (default 2 MB).
- After each IPC request (2 s later) and each power-log import, `malloc_zone_pressure_relief` hands free pages back.
- **The decisive change.** The LaunchAgent sets `MallocSpaceEfficient=1`. With live heap data of only 0.76 MB, the default allocator kept freed pages: the recorder measured 15 MB settled and 20–22 MB after 48-hour investigations. With the setting it measured 4.1–4.2 MB in both cases, side by side on copies of the same database.

**Menu bar app.**
- A bare process measured 2.2 MB, and 11.5 MB with an `NSStatusItem` (NSApplication plus the WindowServer connection). The menu bar part therefore can't get under 5 MB.
- The app now runs as two instances of one bundle:
  - The menu bar instance is plain AppKit (`@main` without a SwiftUI `App`) and never builds SwiftUI views.
  - "Open GhostTrace" starts a `--window` instance (`NSWorkspace.OpenConfiguration.createsNewApplicationInstance`). It has a Dock icon and the Edit menu, and it quits when its window closes.
- Before, one instance measured 28 MB after its window was closed, because SwiftUI's memory stays.
- `LSEnvironment` in `App/Info.plist` sets `MallocSpaceEfficient=1` for the app too. The menu bar instance measured 8.6–8.8 MB with it and 12–17 MB without.

**Ad-hoc signing and launchd.**
- `SMAppService` registration records the recorder's code requirement. For an ad-hoc signature, that is its hash, which changes with every build, so launchd refused the rebuilt binary (`last exit reason = OS_REASON_CODESIGNING`).
- When the bundled recorder's modification time differs from the one recorded at registration, the menu bar instance unregisters and registers it again at launch.
- A Developer ID signature would make this unnecessary.

**Results** (10 minutes idle, after startup, nothing attached to the processes):
- Recorder: 0.15 s CPU (0.025% of one core), 4.6 MB.
- Menu bar instance: 0.01 s CPU, 10 MB.
- Sample rows: 1.46 KB (was 2.3 KB). That is at least 144 a day from the heartbeat, about 0.2 MB a day on a quiet Mac.

A CPU burn first measured in the menu bar instance (about 12% of a core) came from accessibility tools attached to that process. They made it re-set the cursor on every mouse move. A fresh instance used 0.01 s in 2.5 minutes.
