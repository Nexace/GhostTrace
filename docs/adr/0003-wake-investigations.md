# ADR 0003: Wake investigations (Phase 2)

Date: 2026-10-27. Status: accepted.

## Evidence source: `pmset -g log`

**Checked (on this Mac, macOS 27.0.1).** `/usr/bin/pmset -g log` runs without privileges. It holds about 7 days of log (first line 2026-10-20, 36,670 lines) and takes about 3.2 s, nearly all of it inside pmset. Its wake lines name a reason:
- `Wake from Deep Idle [CDNVA] : due to … RTP.keyboard/UserActivity …`
- `DarkWake from Deep Idle [CDNPB] : due to … rtc/Maintenance …`

At each sleep it also lists pending wake requests: `[process=dasd request=SleepService deltaSecs=942 wakeAt=… info="…"]`. The format is not documented, so the parser follows the lines as seen here.

**Decision.**
- Import only these entry types:
  - `Sleep`, `Wake` and `DarkWake` lines (including `DarkWake to FullWake`).
  - Each item of a `Wake Requests` line, as its own event.
- Each becomes a `diagnostic` event with quality `imported`, source `power-log/pmset -g log`, and the line (or request item) as `provenance`. Nothing else from the log is stored.
- The event id is the first 16 bytes of the SHA-256 of the line, so re-importing stores nothing new. `bootSessionID` and `monotonicNanos` are left empty, because recording-time values would be wrong for an old line.
- Line times carry their own UTC offset. A request's due time comes from `deltaSecs`, because `wakeAt` is printed without a zone.
- When the import runs:
  - Daily and at startup (hourly until ADR 0004's overhead pass), so wake reasons outlive pmset's week and stay for the 30-day retention.
  - Before every investigation.
  - Never while paused: pausing stops all recording.
- pmset runs in a detached task, so other requests aren't held up. The CLI uses a 30 s client timeout for investigations.
- Coverage is tracked in `recorder_state`:
  - `power_log_since`: the earliest first line seen.
  - `power_log_through`: the last successful read.
- The status capability `power-log` is `observed` after a successful read. After a failed read it is `unverified` (ADR 0001, rule 7).

**Side effect.** `retainedSince` (the oldest stored event) can now be earlier than the recorder's first run, because imported lines are older.

## Confidence taxonomy

Every finding has one label and cites event ids:

| Label | Meaning | Example |
|---|---|---|
| `observed` | macOS recorded it directly | powerd's line "due to rtc/Maintenance"; the NSWorkspace wake notification |
| `likely` | GhostTrace's interpretation of cited evidence | "the lid was opened" read from `lid`; a request due within 5 s of a timer wake |
| `correlated` | close in time only, not evidence of cause | an app that launched within 2 min after the wake |
| `unknown` | the recorded evidence can't answer it | no power log for this time; a timer wake with no request due then |

- Reason-code readings are `likely`, never `observed`, because Apple does not document the codes. The table is in `InvestigationKit` (`WakeInvestigator.codes`).
- A timer wake (`rtc/…`) is matched to requests logged at the previous sleep that were due within ±5 s. Matching uses the time, not the request type: at 17:11:27 the reason was `rtc/Maintenance`, but the request due then was `powerd CSPNEvaluation`. When several requests match, all are listed, as alternatives. The `*` that pmset puts before one request is kept as `marked`, but not used. On this Mac it marked the earliest request, not always the one that fired.
- Post-wake app launches are only ever `correlated`. Findings are ordered observed, likely, unknown, correlated.

## Matching and bounds

- An NSWorkspace wake notification pairs with the nearest power-log wake from 2 s before to 10 s after it. Measured live: 0.55 s after the line's whole-second time. Time offsets are worded to the second, because log lines have no fractions.
- Window: at most 48 h. Events are read from 24 h before the window (for wake requests) to 2 min after it. The recorder refuses, rather than truncating, if that span holds more than 100,000 events.
- Limits are reported per wake and per investigation:
  - Recorder gaps around the wake (citing the gap event).
  - Wakes from before GhostTrace first ran.
  - Power-log coverage, or a failed read.
  - A full wake without a notification while the recorder was running.

## Not verified

- Whether macOS posts `NSWorkspaceDidWakeNotification` for dark wakes. No dark wake has happened while the recorder was running. The investigator says so ("may not post one") and does not treat the absence as evidence.
- Lid-close sleep. Other macOS versions or Intel Macs, whose reason codes differ (`EC.LidOpen` and similar). Those codes would show as "can't interpret" (`unknown`).
