# ADR 0005: Reliable background operation (Phase 4)

Date: 2026-10-28. Status: accepted.

## IPC: XPC with a same-team requirement under launchd, the socket for terminal recorders

This replaces the first Phase 4 decision, which kept the socket because no signing identity existed.

**Checked.**
- After signing in to Xcode with a free Personal Team (5PCPH987YL), `xcodebuild -allowProvisioningUpdates … build` created an Apple Development certificate from the command line (valid until 2027-10-27). The app has no entitlements, so no provisioning profile is involved.
- Throwaway launchd probe (scratch, removed afterwards): a team-signed client gets its reply from a team-signed server. An ad-hoc client against a team-signed server, and a team-signed client against an ad-hoc server, both end in "Underlying connection interrupted". A name nobody holds fails at lookup ("No such process").
- launchd sets `XPC_SERVICE_NAME` to the job label (`launchctl print` shows it in the job's environment).

**Decision.**
- The agent plist advertises the Mach service `com.amoghkhairate.GhostTrace.recorder` (`MachServices`; the name is `IPC.machServiceName`). The recorder listens with `XPCPeerRequirement.isFromSameTeam()`. Clients open an `XPCSession` with the same requirement, so a fake recorder can't answer either.
- A message is `Envelope { json: Data }`: the socket's JSON, produced by `GhostTraceJSON`, so dates and `apiVersion` behave identically. Both transports run the same `decodeRequest` (8 MiB limit, readable JSON, `unsupported_version`) before the same handler. XPC replies come from a task, after the async handler.
- **No fallback under launchd.** `IPC.Transport.recorder` picks XPC when `XPC_SERVICE_NAME` equals the label, and that recorder creates no socket. Anything else (a shell, `swift test`, `GHOSTTRACE_HOME`) is a terminal recorder and keeps ADR 0002's socket, unchanged. Clients use the socket only when `GHOSTTRACE_HOME` is set (or a socket path is passed), otherwise XPC. Both choices are pure functions of the environment, with unit tests. The Mach service itself can't be tested under `swift test`.
- The deployment target is now macOS 26 (Package.swift tools 6.2, the Xcode project), because the peer-requirement API starts there. GhostTrace is a personal tool for this Mac, so there is no `#available` fallback.
- Signing: Xcode signs the app and `RecorderAgent` (automatic, team 5PCPH987YL). The CLI is signed by `scripts/sign-cli.sh`, which builds release `ghosttrace` and signs it with the Apple Development identity of that team. An unsigned CLI gets `permission_denied` (exit 4) naming that script.

**Limits (stated, not solved).**
- "Same team" admits every program signed with this Personal Team certificate, not only GhostTrace's three.
- `XPCRichError` exposes only text, and a rejected peer and a recorder dying mid-request both read "interrupted". The client's message says both. Matching the word is a stated shortcut in the code.
- A terminal recorder on the default home is unreachable by clients that use XPC. Set the same `GHOSTTRACE_HOME` for it and the CLI.
- The certificate expires on 2027-10-27; signed builds need a renewed one after that.

## Pause stops collection

A pause used to drop events while every collector kept running, so sampling still cost CPU. Now pause stops every collector and resume starts them again. A paused recorder only answers IPC. A recorder that starts paused (pause is persisted) starts no collectors. The sampler forgets its baseline when stopped, so the first sample after a resume doesn't average CPU over the paused time.

## Restart recovery: FSEvents history

FSEvents event ids persist across restarts and reboots, and a stream created with `sinceWhen` replays the history after that id, then sends `HistoryDone`.
- The file watcher's **checkpoint** is the system's latest id when its stream started, or the highest id delivered since, whichever is later. The recorder saves it with its time (`fsevents_checkpoint`) at every 5-minute heartbeat and at a clean stop.
- At the next start (not paused), the watcher replays from the checkpoint. Each changed item becomes one `file_change` event with `replayed=true`, quality `inferred`, and an interval from the checkpoint time minus 5 s (FSEvents' delivery delay) to the stream start. The history keeps which items changed, not when or how often, so investigations show the interval and pair no renames or app launches with it.
- After a crash, changes recorded live after the last heartbeat aren't replayed again: the start moves the replay point past the highest `fsevent_id` already stored since the checkpoint.
- Pausing clears the checkpoint, so changes made while paused are never replayed.
- If the history reports drops, or its ids were reset, the stopped span becomes a `watch_dropped` gap. A replay lists at most 1,000 items, and the rest are counted in a gap.
- Checked live with a throwaway recorder: a clean stop, a `kill -9` and a pause each behaved as above.

## Migration safety

- Before an upgrade (existing schema older than the build), the database is copied with `VACUUM INTO` to `events.sqlite.pre-v<N>-<unix time>` (mode 0600, never deleted automatically). The recorder records a `storage_migrated` marker naming it.
- A migration that fails is rolled back explicitly (`sqlite3_exec` stops at the failing statement and leaves the transaction open), so the file stays at the old version with its data. The recorder then fails to start and says why in the unified log.
- The database, WAL and SHM are set to 0600 at every open. This fixes files created before the recorder set `umask 077`.

## Diagnostics

- The recorder logs to the unified log (subsystem `com.amoghkhairate.GhostTrace`, category `recorder`) as well as stderr, because launchd discards a LaunchAgent's stderr. Errors are logged at error level. Lifecycle markers (start, stop, pause, resume, watch changes) are logged at default level, with their details private.
- `ghosttrace logs [--last DURATION]` shows them (`log show` with that predicate).
- `status` adds `databaseBytes` (database plus WAL) and `schemaVersion`. Both are optional, so the API version stays 1.

## Storage growth

The sampler now stores a sample only on a change, and at least every 10 minutes (ADR 0004's overhead pass). That makes thinning old samples unnecessary for now. Measured on the live database (5.3 h of data, mostly development use), a sample row is about 2.4 KB and the rate was 33 to 100 rows an hour. That projects to roughly 2 to 6 MB a day, or 60 to 170 MB at 30 days, against the 1,000,000-row cap. The overnight soak (`scripts/soak-report.sh`) is to confirm it.
