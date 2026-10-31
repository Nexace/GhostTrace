# ADR 0007: System monitor, alerts and the battery, network and disk investigators (Phase 6)

Date: 2026-10-29. Status: accepted. Spec: `docs/superpowers/specs/2026-10-28-system-monitor-design.md`.

## Context

Phases 3 and 4 recorded memory and CPU of the user's own processes. They could not answer "what drained my battery", "what used the network", "what filled the disk" or "why was the CPU busy". Phase 6 adds system-wide CPU, GPU, network, disk and battery readings, alerts, a live System pane, and three investigators. The user's constraint is minimal CPU and memory: the recorder stays near 5 MB and near zero CPU, and the idle menu bar app does not grow.

## Decisions

### System reader and stored activity
- One `SystemReader` reads CPU ticks, GPU utilization, network and disk byte counters, battery and free space. A metric the Mac does not give is stored as absent and shown as "Not available" with the capability row's reason; it is never filled with zero.
- **Network sums only `en*` interfaces** (physical Ethernet and Wi-Fi). `utun` and `ipsec` carry the same traffic as `en0` again, and `awdl`, `llw` and `utun` come and go. Cost: traffic on other interfaces (a USB modem not named `en`) is not recorded.
- **Counter resets count as 0 bytes.** `ActivityTracker` keeps state in memory, so within one recorder life a "reset" is almost always an interface or drive disappearing, not a reboot. A reset check adds 0 bytes and no rate, peak or busy edge. Cost: one interval of real traffic is under-counted after a genuine reset.
- Rates are bytes over wall seconds; CPU needs two tick readings, so the first reading has no CPU.
- Per-process `energy` (watts), `diskRead` and `diskWritten` ride on the processes a sample already lists (the keep-set also adds the top 3 by energy and by disk writes). Samples stored before Phase 6 still decode; every new field is optional.

### On-change storing
The check stays at 30 s and the heartbeat at 10 min. A sample is stored when an existing trigger fires or when charge dropped 5 points, CPU or GPU crossed 80% in either direction, network or disk crossed 10 MB/s in either direction, the power source changed, or free space dropped 1 GiB (counted since the last stored sample). Known limit: no hysteresis at 80%, so a load hovering at 80% can store a sample at every check. Decide in the final review.

### Live IPC
`Request.Method.live` is read-only and returns the current reading without touching the store. It backs the System pane. It is **not** an MCP tool: a live poll is for a person looking at a screen. While the switch is off the recorder refuses `live` (it never reads IOKit then).

### Alerts and their windows
Four rules, evaluated by the pure `AlertMonitor` on every check and never while paused: `battery_drain` (projected time to empty under 2 h over 10 min on battery; ends on plug-in or over 3 h), `disk_full` (free space under 10 GB or 5%; ends over 15 GB and 7.5%), `memory_critical` (critical pressure; ends after 5 min non-critical) and `sustained_load` (CPU or GPU at or above 80% on every check for 5 min while idle 5 min or more; ends after 2 checks under 60%). One hour cooldown per rule.
- Each start and end is an `alert` event citing the sample that caused it, so it shows in the Timeline, `events --kind alert` and MCP. **Banners are shown only for starts**: an "is over" banner per incident is noise. Cost: the user is not told by banner when an incident ends.
- Windows need at least 2 readings spanning the window, not the spec's 3 checks, because at a 600 s interval only 2 readings can span 10 min. Cost: a noisier 2-point battery projection at long intervals.
- Recent readings are kept in memory, capped at `max(24, 600/interval + 3)`: 21 readings are not enough, because the 30 s timer has leeway and 21 can span 597 s. Cost: at short intervals up to 123 small structs in the saved state.
- Alert state is saved only on a start or end, not on every check, as the spec says recent checks are not stored; a recorder restart restarts the windows. Saving every check would write SQLite every 30 s.
- `sustained_load` requires the same load (CPU or GPU) high on every check: the stricter reading.
- Names come from the last stored sample, the same sample the alert cites as evidence. A process that started since the sample before it is averaged over its own life (its whole life lies inside the sample's span), so a load that just started is listed with its real share; before the final-review fix it had no figure and older processes were named instead. The message says "among your processes" (only this user's are readable), gives each name its figure, and collapses same-named processes (`yes ×3 297%`). Where no process is measurable it says "none measurable". "While you were away" is said only when idle time was read; without it the rule drops the idle condition.
- `disk_full` takes its names from the latest stored sample (up to 10 min), not "the largest writers over the last day" as the spec says, and leaves them out of the message. Recorded as a deviation; revisit in Phase 7.

### `nettop` gating
`nettop` runs only on a network busy edge, as a `diagnostic` event (`source: nettop`), off the writer queue, with output read while it runs (a full pipe would otherwise stall it until the 15 s kill) and SIGKILL after a short grace. The 300 s limit applies to "started" snapshots only; an "ended" snapshot always follows a started one, since otherwise spikes under 5 min never get a start and end pair and the network investigator can never name a process. Cost: up to 2 runs per 5 min. Idle cost is unchanged by design. `nettop` truncates names to 15 characters.

### The three investigators
`investigate battery|network|disk` (CLI and MCP) follow the wake investigator: each finding has a confidence and cites event ids, and what could not be seen is a limit.
- **Battery.** Sessions on battery split at plug-ins, sleeps, naps and unexplained gaps. A drain rate is stated only across measured samples; process energy is reported as a share of what was measured, rounded down ("at least N%"), or "couldn't be measured". Dark wakes are `correlated` only.
- **Network.** Spikes over 10 MB/s, or over 100 MB between two samples. A process is named `likely` only with a started and an ended `nettop` snapshot, a top growth over 50% of `nettop`'s growth (strict), and at least 10% of the interface bytes. Otherwise `unknown`.
- **Disk.** Free-space drops of 1 GiB or more, or bursts at 10 MB/s or more. **A burst whose bytes are mostly reads is not a write burst** and is dropped with one limit counting them; the live 24 h run showed 15 mostly-unknown incidents. Cost: a read storm is not explained by `investigate disk`. A writer is `likely` only above 50% of the system's writes (share capped at 100%, never `likely` at 0 written). Watched-folder changes in the incident are `correlated`, naming the folder only.
- `investigate battery` and `network` import the power log first, as `investigate wake` does, so a call can take 1 to 3 s and write power-log events.
- Confidence rules: `observed` is a macOS counter or reading; `likely` needs measured evidence over a stated threshold; `correlated` is only closeness in time; `unknown` is said where the evidence cannot answer. GhostTrace only sees its user's processes, APFS snapshots and purgeable space are invisible, and no investigator claims a cause it cannot cite.

### The System pane budget work
The first build cost the recorder 1.1% of a core while the pane was open and the window 145 MB. Fixed before review: `SystemReader.read()` 4.80 ms to 0.52 ms (free-space "important usage" cached for 60 s or a 256 MB move at that time, now 600 s: see "Perf fix after the 30-min soak"; `statfs` kept fresh), the window 145 MB to 53 MB (sparklines drawn as `Shape`, Charts only in the History section), and polling paused while the window is hidden, minimised, or the screen is asleep. Window memory is not a recorder cost, and the window quits when closed.

### Perf fix after the 30-min soak
The soak missed the CPU line (0.059%). Two causes: the free+purgeable ("important usage") lookup, about 16 ms cold, ran on every other check, and `if_indextoname` ran a routing sysctl per interface. The lookup now refreshes every 600 s (a 256 MB `statfs` move still refreshes at once) and interface names are read in place from the `sockaddr_dl`. Per check 13.5 to 7.0 ms; recorded fields are the same.

### The on/off switch: "Record System Activity"
Menu bar item, `ghosttrace config --system on|off` and a toggle in the System pane. Off stops only the system monitor (system fields, per-process energy and disk, alerts, `nettop`, `live`); memory, launches and file changes keep recording. The off span is stored as an `event_gap` with the new reason `system_monitor_off`, written when it is turned back on (as pause does), and every investigator turns it into an explicit limit, not into "quiet". Cost: an old client cannot decode the new gap reason; the app, recorder and CLI ship together. Switching stores a sample so readings are never joined across the off span. Rates after turning on span no off time, so the first sample after has no CPU, network or disk bytes, rates or energy (bytes are "not measured", never 0).

### `status()` caching
The window polls `status()` every 2 s. Code-signing, entitlement and FDA checks cannot change while a recorder runs, so they are computed once per process. Measured by socket benchmark (Task 12): 0.48 to 0.15 ms CPU per call (wall time on the socket benchmark: 1.00 to 0.16 ms); live over XPC 1.0 to 0.45 ms per call (the rest is XPC session set-up).

### Final-review fixes
- **Alert names (C1).** See "Alerts and their windows": new processes get their lifetime average for CPU, energy and disk bytes; names and evidence come from one stored sample.
- **Blocked banners (I1).** When macOS refuses notifications, asking or posting fails, or the alert style is None, the menu shows "Banners Are Off: Open Notification Settings…" under Show Alerts (only while Show Alerts is on). It is refreshed after each delivery and when the menu opens, never on a timer. "Not determined" counts as blocked only after asking failed. Alert style None also counts as blocked. Notification permission is requested when the user turns Show Alerts on (changed 2026-10-30 at the user's request; off the main thread, then the menu state is refreshed), and still at the first alert if undetermined. Alerts that arrive while banners are blocked are not shown later; they are in the Timeline.
- **Banner click and window races (I2).** The window's model is built with `pane = .timeline` before it is installed (the earlier change in `init` was lost, so a click opened Overview). A launch by a banner click skips the plain launch-time window. One in-flight flag joins a reopen and a banner click in either order: a selection that arrives during a launch is applied when the launch finishes. Restarting the window on an event is tried once, then the old window is brought forward.
- **Pause carry-over (I3).** A pause resets the activity tracker as well as the baseline, so the first sample after resume holds no bytes from the paused span (the privacy promise) and no fake network spike.
- **Unmeasured bytes (I4).** Bytes and peaks are nil when no check-to-check span was measured, and kept when the last reading failed. The first sample after a recorder start, a turn-on or a resume no longer stores 0 B, so history averages don't dip after a restart.
- **Zero battery power (I5).** The battery investigator no longer divides by 0 W (a trap that could stop the recorder).
- **Failed free-space lookup (M1).** A failed "important usage" lookup is cached as no purgeable space, so it isn't repeated every check.

## Consequences
- The recorder gains a system reader, an alert monitor and `nettop` runs, all on the existing 30 s check. Idle cost is a single reading per check.
- Three new MCP tools (`investigate_battery`, `investigate_network`, `investigate_disk`). The MCP set is now ten read-only tools: the seven in ADR 0006 plus these. `live` is not exposed.
- `EventKind.alert`, `GapReason.system_monitor_off` and `Key.alertState` / `Key.systemMonitor` are new stored values.

## Known limits / follow-ups
- Free space lag: purgeable-only changes (for example Optimize Storage) can lag up to 10 min in `freeSpace`; real writes still refresh at a 256 MB move, so the 1 GiB drop trigger and the disk-full alert stay timely.
Deferred from reviews, none blocking:
- Not tried in the app: the Explain button. Pane polling pausing when hidden or asleep was not tested with a real sleep.
- User-visible: rates under 512 B/s show "0 KB/s"; a window peak can include a first sample with no span; interfaces other than `en*` (for example pdp_ip) are not recorded.
- No 80% hysteresis on the CPU/GPU store trigger (above). Charge does not re-anchor while charging.
- Counter-reset under-count; `en*`-only network; 32-bit per-core tick wrap reads as a reset.
- A real banner click (warm and cold launch) has not been re-tested since the final-review fix; that is part of Phase 7's final debug. Whether macOS sets `launchUserNotificationUserInfoKey` on a cold launch from a banner is unverified (the in-flight flag covers both cases). No `willPresent` delegate. `alert_state` decode failures are silent. An alert older than 24 h shows "No Selection" in the Timeline.
- Alert windows restart after a recorder restart. A load-end check uses the last two readings without a gap test.
- Battery watts are instantaneous while the process figure is an average (the basis says approximate). Short naps count in energy. Per-process identity is by name, so helpers split.
- Network: `nettop` names are cut to 15 characters; a process absent from the start snapshot is treated as growing from 0.
- Disk: `incident()` runs for every run (cost grows on 48 h windows); a 100k-event cap can refuse disk on a very busy watched folder. Per-incident cap and gap cases are untested.
- Switch: an in-flight check can store one reading just inside the gap; a poll racing the toggle can flash "Recorder not responding" for one interval; two fast menu toggles can lose one click; `Recorder` wiring (executable target) has no tests; the pane's toggle and menu checkmark were not looked at on screen.
- The System pane screenshot (`docs/screenshots/system-pane.png`) is dark mode only. Light mode is unchecked.
- Not claimed: which process caused GPU load, battery or disk activity beyond what the investigators cite.

## Gate

| Gate item | Result | Evidence |
|---|---|---|
| Each metric recorded or labelled unavailable | Pass (unit tests, live) | CPU, GPU, memory, network, disk, battery and free space are stored, or shown "Not available" with the capability row's reason. Live GPU, battery and free-space values checked in the System pane and `ghosttrace system`. Suite: 199 tests. |
| Alerts once per incident | Pass (banner click re-test in Phase 7) | Live (Task 6): `sustained_load` start and end once each, a recorder restart added no duplicate, and the app fetched the alert. Banner: none showed while macOS notifications were off for GhostTrace; after the user allowed them, a banner appeared on a re-sent alert; clicking it opened Overview, not the Timeline. Fixed in the final fix wave. Verified on screen 2026-10-30: the user opened the window with `--select-event` for the 22:39 alert and it opened on Timeline with the alert selected. The real banner click is still a Phase 7 re-test. |
| Investigators cite evidence | Pass (tests, live 24 h runs) | Every finding cites event ids; labels follow the rules above. Live: `investigate disk` named dd for a 2.0 GB write at 69% (likely); battery and network ran over 24 h in 2 s each. Battery with a real unplug (2026-10-29, 23:57): `investigate battery --last 2h` gave two stretches split at the reinstall's recorder_stopped gap; the 22:53-23:57 stretch went 85 to 80% at 4.7%/h and 4.5 W average, main cause unknown, launches correlated only, measured processes "at least 2%" of battery power. Agent via MCP (2026-10-30): after `ghosttrace mcp allow`, a `claude -p` run with only `investigate_battery` allowed answered with the drain (85 to 79%, 4.8%/h, cause unknown, labels kept) and cited event ids including the recorder_stopped gap; then `mcp deny`, status back to "not allowed" |
| Budget, switch on | Pass (after the perf fix) | Phase 4 baseline 0.025% of one core. 30-min soak before the perf fix (22:54-23:24, on battery, no accessibility tools): recorder 0.059% of a core (missed the 0.05% line), 5.3 to 5.0 MB; menu bar 0.008%, 11 MB. After the perf fix (free+purgeable lookup refreshed every 600 s instead of 60 s; interface names read in place), per check 13.5 to 7.0 ms; final 10-min live measurement after reinstall: recorder 0.028% (pass line 0.05%; Phase 4 0.025%), 5.0 to 5.2 MB; menu bar 0.003%, 11 MB; energy impact 0.0 for both. The menu bar's 11 MB is above Phase 5's 9-10 MB likely because the UNUserNotificationCenter delegate is set at launch (macOS requires it for banner clicks); this was not A/B measured. One reading of 19 MB came after about 80 minutes of use, with the menu opened and alerts delivered (heap left after activity). After the final fix wave (reinstall, 2-min settle, window closed, no accessibility tools on the recorder, on battery, 23:18-23:23): recorder 0.08 s per 300 s = 0.027% of a core, footprint 5.3 MB (5,329 to 5,265 KB). |
| Budget, switch off | Pass | On a throwaway recorder at 30 s, 0.13 s (off) vs 0.27 s (on) per 600 s before the perf fix and 0.11 s vs 0.14 s after it; Task 12's 120 s test: off 0.11 s vs on 0.20 s. The live switch-off cost was not measured separately. |
| On/off switch | Pass (CLI and IPC) | Off: no system, energy or disk fields; `system` says not recorded; a `system_monitor_off` gap and investigator limit appear on turning on; `live` refused while off. Menu checkmark and pane toggle: not looked at on screen. |
| Whole suite | Pass | `swift test`: 199 tests, 0 failures (193 after the perf fix; 192 at Task 12, fix round 1); Release `xcodebuild`: BUILD SUCCEEDED. Final run for 0.6.0: `swift test` green; `dist/GhostTrace-0.6.0.zip` 4,795,242 bytes. |
