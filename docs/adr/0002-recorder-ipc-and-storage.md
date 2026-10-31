# ADR 0002: Recorder IPC and storage (Phase 1)

Date: 2026-10-27. Status: accepted.

## IPC: Unix-domain socket now, XPC deferred

**Checked (SDK headers, macOS 27.0 SDK).** `NSXPCListener initWithMachServiceName:` is documented as "a listener for a named Mach service advertised in a `launchd.plist`" (Foundation `NSXPCConnection.h`). `xpc/connection.h` and `xpc/session.h` say the same for the C APIs. An anonymous listener can't be found by an independent terminal process without a broker. So a standalone `ghosttrace` process can reach a named XPC service only after a LaunchAgent plist or `SMAppService` registration. That is Phase 4's launch-at-login work and leaves persistent configuration on the Mac. Code-signing peer requirements (`xpc/peer_requirement.h`) also need a real signing identity, and this machine has none (ADR 0001).

**Decision.** Use the fallback the plan allows: a Unix-domain socket at `~/Library/Application Support/GhostTrace/recorder.sock`.
- The directory is forced to 0700, the socket to 0600, and the agent runs with `umask 077`.
- The server answers only peers whose `getpeereid` uid equals its own; others get `permission_denied`. The client checks the server's uid the same way.
- One JSON request line, one JSON response line, one connection per request. 5 s socket timeouts, 8 MiB message limit, `SO_NOSIGPIPE`.
- Every message carries `apiVersion` (currently 1). A mismatch is rejected with `unsupported_version` before the handler runs.
- No network port is bound.

**Limits (stated, not solved).** Any process running as the same user can query the recorder. That is the same reach it already has to the database file. Without a signing identity, nothing distinguishes the real CLI from another same-user process. Revisit XPC with peer code-signing requirements in Phase 4, once a signing identity and a LaunchAgent exist.

## Storage

- SDK `SQLite3` through a ~200-line internal wrapper (`Sources/EventStore/EventStore.swift`). Still no dependency.
- One connection guarded by a lock. The recorder is the only writer; the CLI and app never open the file. Uses WAL and `synchronous=NORMAL`.
- Schema: `events(seq AUTOINCREMENT, id UNIQUE, occurred_at ms, ended_at ms, kind, bundle_id, json)` plus `recorder_state(key, value)`. The full event is stored as `GhostTraceJSON`; indexed columns exist only for querying.
- Migrations are append-only SQL strings keyed by `PRAGMA user_version`. A database newer than the build is refused and left untouched.
- Duplicates: `INSERT OR IGNORE` on the event id, so a retried batch can't double-store.
- Order is `occurred_at`, then `seq`. Pagination uses the opaque cursor `"<occurred_at ms>.<seq>"`.
- Recovery: if `PRAGMA quick_check` fails, or the file isn't a database, the file and its WAL/SHM are renamed to `events.sqlite.corrupt-<unix time>` (never deleted). A fresh database is created and a `storage_recovered` marker is recorded.
- Retention: an hourly purge of events older than 30 days, then of the oldest rows beyond 1,000,000.

## Coverage and gaps

- `event_gap` (an interval with `endedAt`, quality `inferred`) is recorded in these cases:
  - Downtime between runs: `recorder_stopped` after a clean stop, or `recorder_interrupted` from the last heartbeat (every 60 s until ADR 0004's overhead pass, now every 5 min).
  - User pause.
  - Ingestion-queue overflow, with `dropped_count`.
- Startup gaps carry `boot_changed`: `true`, `false` or `unknown`, from `kern.bootsessionuuid`.
- Listings always include gap events that overlap the window, whatever kind filter is applied.

## Timestamps

- UTC milliseconds everywhere, serialized as `2026-10-26T21:30:00.123Z`.
- CLI inputs must carry an explicit zone. Nothing is inferred from the local zone.
- `monotonicNanos` is `CLOCK_MONOTONIC_RAW`, which counts through sleep, taken at recording time. It is comparable only within one boot session, so ordering never uses it.
