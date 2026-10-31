# GhostTrace — Implementation Plan for Claude Code

> **Mission:** Build a local-first macOS flight recorder that captures relevant system events over time and helps explain *why* an application launched, a file changed, a process used excessive resources, or a Mac woke from sleep.

## Instructions for Claude Code

You are the lead engineer implementing GhostTrace. Work incrementally. Inspect the repository and toolchain first. Produce a runnable app at each milestone, implement tests, and update this plan with actual progress. Prefer functioning, verified code over mock implementations. Do not invent macOS API capabilities or claim causal certainty without evidence. Where Apple entitlements or approvals are unavailable, implement a clearly labeled reduced-capability mode rather than bypassing system protections.

**Primary language:** Swift. **UI:** SwiftUI. **Storage:** SQLite (through a maintained Swift integration, selected and justified after checking the environment). **Platform:** Apple Silicon macOS, with deployment target selected after inspecting the available Xcode SDK. **Architecture:** persistent native recorder/agent + SQLite event store + investigation engine + local XPC communication boundary + first-class `ghosttrace` CLI + SwiftUI desktop client + optional read-only MCP adapter. Rust is NOT part of v0.1; introduce it only if profiling demonstrates a tangible need or cross-platform support becomes a requirement.

## Product promise and limits

GhostTrace answers questions such as:

- Why did my Mac wake at 3 AM?
- What launched this application?
- What changed this file, if it was in a monitored path?
- Why was an application consuming so much memory?
- What processes were active around a battery-drain incident?

An answer should cite timestamped evidence, sources, and uncertainty. **Temporal proximity is not proof of causation.** Distinguish *observed*, *correlated*, *likely*, and *unknown*. Event records can support explanations only for information collected or retained; do not claim retroactive visibility into previously unrecorded activity.

## Architecture — CLI-first, API-backed, SwiftUI-capable

```text
macOS events / supported Apple APIs / diagnostic snapshots
                            |
                    Recorder collectors
                            |
                Normalize + privacy filters
                            |
                Bounded event ingestion
                            |
              SQLite + InvestigationKit
                            |
           RecorderAgent service boundary
                            |
         Local XPC service / typed IPC contract
                   /         |          \
          ghosttrace CLI   SwiftUI GUI   MCP adapter (later)
              |                             |
          humans / scripts             AI coding agents
```

**Design rules:** One long-running recorder owns the write path. CLI, GUI and MCP are **clients**, never separate collectors or direct concurrent database writers. Implement an explicit typed interface for status, filtered listing, event detail and investigations. Prefer Apple's native XPC mechanism for an authorized, local macOS app/agent pairing; verify service types, connection lifecycle, packaging and signing constraints against the installed SDK before choosing `NSXPCConnection`, XPC C APIs, or another supported solution. XPC is local IPC, **not** automatically a general HTTP API. Do not bind a network port by default. Check caller identity/authorization and protect sensitive event data; file permissions alone are not a complete access model. For CLI packaging/distribution, test how an independent terminal process can actually connect to the chosen XPC service. If this proves impractical for the target packaging, document and test a narrowly scoped local Unix-domain-socket fallback, with peer authentication and strict filesystem permissions. Never silently broaden access.

Suggested modules:

- `RecorderCore`: event contracts, normalization, asynchronous queue, lifecycle.
- `Collectors`: workspace/application lifecycle, sleep/wake, resource sampling, selected file paths, diagnostic snapshots.
- `EventStore`: migrations, indexed queries, retention, export, concurrency-safe writes.
- `InvestigationKit`: temporal windows, event ranking, correlation, evidence provenance, confidence taxonomy.
- `RecorderAgent`: separately managed persistent background execution where supported and authorized; primary storage owner.
- `GhostTraceIPC`: shared typed request/response contracts, versioning, error codes, authorized local IPC client/server.
- `GhostTraceCLI`: `ghosttrace` executable using the shared client, supporting `--json` for machine-readable output and clear exit codes.
- `GhostTraceApp`: SwiftUI onboarding, permissions/status, investigations, timeline, all through the shared service interface.
- `MCPBridge` (later): local read-only adapter using the shared client; no separate database access.

Prefer explicit protocols for collectors, persistence, clocks, investigators and service interfaces to enable deterministic tests. Organize the CLI and recorder so core operations are testable even before a complete GUI exists.

### CLI contract (implement early)

```bash
ghosttrace status
ghosttrace events --last 24h --json
ghosttrace events --from '2026-10-27T02:00:00+05:30' --to '2026-10-27T04:00:00+05:30'
ghosttrace investigate wake --at '2026-10-27T03:00:00+05:30'
ghosttrace investigate app-launch --name 'Safari' --last 24h
ghosttrace investigate file-change --path ~/Documents/example.txt --last 24h
ghosttrace memory --top 10 --last 1h
```

- Require explicit time zones or documented local-time parsing, preserve UTC timestamps in JSON, and report coverage gaps.
- Default output is concise and readable; `--json` is stable, versioned, bounded and suitable for agent automation. Support pagination, meaningful exit status and actionable permission errors.
- `ghosttrace explain "Why did my Mac wake up last night?"` is **future optional** AI-assisted functionality; do not imply that v0.1 supports arbitrary natural language, and do not fabricate interpretations without underlying evidence.
- The CLI must **not** spawn a second recorder for ordinary queries. `status` must distinguish running, paused, permission-limited and stopped states.

## macOS capability matrix (validate against the installed SDK)

| Capability | Initial approach | Limits / caveats |
|---|---|---|
| App launch/quit | NSWorkspace and running app observation | Basic workspace notifications omit some background/agent apps; do not claim all process executions |
| Sleep/wake | NSWorkspace notifications and power-management interfaces; optionally `pmset -g log` diagnostic interpretation | Wake reason is not always conclusively exposed; records collected after waking are not proof of the cause |
| CPU/memory | Periodic sampling via supported process and system interfaces | Samples are snapshots, not continuous measurements; memory pressure is distinct from resident memory |
| Selected file changes | FSEvents for watched trees; file-specific monitoring if appropriate | FSEvents does not reliably identify the actor that wrote a file; do not label a writer without separate evidence |
| Historical system diagnostics | Carefully scoped, read-only OS diagnostic log/command extraction | Log privacy, retention, access and OS version vary; failed lookups must be visible |
| Exact process/file event attribution | Endpoint Security only after approved entitlement, suitable signing, and explicitly consented deployment | Future advanced mode, **not** a v0.1 dependency; do not disable SIP or otherwise weaken machine security |

Apple references for investigation: https://developer.apple.com/documentation/endpointsecurity ; https://developer.apple.com/documentation/appkit/nsworkspace ; https://developer.apple.com/system-extensions/

## Event data model

Normalize each observation into an event with fields:

```text
id: UUID
occurred_at: UTC wall-clock timestamp
recorded_at: UTC wall-clock timestamp
monotonic_time: optional monotonic clock value
boot_session_id: identifier where determinable
kind: enum (app_launch, app_exit, sleep, wake, resource_sample,
            file_change, diagnostic, collector_status, event_gap)
source: collector and API identifier
subject: pid + executable identity / bundle ID / path as relevant
related_subjects: optional structured references
payload: typed, versioned metadata
privacy_class: normal | sensitive
quality: directly_observed | sampled | inferred | imported
provenance: source specifics / reference to original excerpt when retained
```

Store event schema version. Do not assume PID is globally unique; correlate with process start/boot identity wherever available. Add an `event_gap` marker after missed collection windows, agent failures, queue overflow, or sleep interruptions. Use bounded batching and SQLite WAL, a single serialized writer, indexes by time/kind/subject, and explicit migrations.

## Collection rules and safety

1. Default to minimal, relevant metadata: avoid file contents, keystrokes, screenshots, browser history, clipboard and message contents.
2. No stealth collection, no persistence disguised as another service, no outbound telemetry by default.
3. Show recording status, monitored paths, permissions, retention settings, and a prominent Pause/Resume control.
4. Keep captured logs and paths local; redact or exclude secrets from diagnostic command output before persisting.
5. Bound CPU overhead, memory use, queue depth, sampling frequency and database size. Emit loss/gap counters.
6. Make collector failures explicit; a collector missing a required permission must not silently report success.
7. Offer data deletion and export of selected investigation evidence with sensitive fields reviewed/redacted.
8. Do not request Full Disk Access or privileged entitlements until a concrete feature needs them.

## Investigation engine

Inputs: question / event type / subject / time window. The engine:

1. Resolves query intent (wake, app launch, file edit, memory spike).
2. Finds primary events and derives a bounded investigation window.
3. Retrieves related events by boot session, process identity, path, time and source.
4. Constructs a ranked **candidate explanation list** with explicit relationships and supporting event IDs.
5. Produces a plain-language explanation with confidence rationale, contradictory evidence, observability limits and missing sources.
6. Links each factual claim to event IDs in the UI; never allow optional AI summarization to introduce uncited events.

For `Why did my Mac wake at 3 AM?`, first establish whether a wake transition occurred near 03:00 local time and translate timezone correctly. Check power-management diagnostic evidence, wake-related events, maintenance/network patterns and collector gaps. A diagnostic wake-reason code may support an explanation; a process that started *after* waking is only a correlate unless additional evidence establishes it triggered the wake.

For memory spikes, use a sampled time series, rate of change, top contributors, memory pressure and process lifetimes where observable. Avoid claiming a sampled process *caused* all pressure without stronger data.

## User experience

Main views:

1. **Today:** recorder status, captured events, last sleep/wake, resource trends, and health warnings.
2. **Timeline:** filter by time, source, event kind, application/process and path; click to inspect raw evidence.
3. **Investigate:** natural-language-like canned questions first; typed query with deterministic intent parsing before LLM integration.
4. **Evidence:** ordered chronology, evidence IDs, source labels, confidence, alternative explanations and missing data.
5. **Settings:** monitored paths, sampling, retention, storage usage, pause, delete/export and launch-at-login.

Use native SwiftUI design, fast scrolling on large timelines, accessible labels, consistent local-time formatting, and an explicit distinction between recording and interpreting data.

## Optional AI / MCP integration (not needed for MVP)

Start with deterministic findings. Later expose a **local-only, read-only MCP server** with tightly scoped tools such as `get_recording_status`, `list_events`, `get_event`, `get_resource_samples`, `investigate_wake`, `investigate_app_launch`, and `investigate_file_change`. Parameterize time bounds and cap result size. Never expose unrestricted SQL, shell access, arbitrary file reading, or destructive commands. Require an explicit user action/approval to let agents connect, with permission to revoke. Mark AI-generated interpretations as interpretations and require event citations. Design transport/auth for local threat model and verify the current MCP specification before implementation.

## Delivery roadmap

### Phase 0 — Repo and feasibility
- Inspect Xcode, macOS SDK, Swift toolchain, signing configuration and permission constraints.
- Generate a buildable Xcode project, module boundaries, README, architecture decision record and test harness.
- Implement a capability/permission status screen and mock collector for automated tests.
- Verify a signed local debug build opens on the test Mac.

**Done when:** launchable app, passing smoke tests, honest capability matrix.

### Phase 1 — Real recorder + first CLI (v0.1)
- Implement app lifecycle and sleep/wake collectors using supported APIs.
- SQLite database schema/migrations, bounded ingestion, event gap reporting and retention.
- Establish and test the typed service contract and local IPC connection, using the documented XPC/packaging decision.
- Ship `ghosttrace status`, `ghosttrace events --last 24h`, `ghosttrace events --json`, and event detail queries, backed by the recorder rather than a separate database writer.
- Basic user-visible recording state/permissions onboarding (minimal GUI is sufficient).
- Test event ordering, timezone shifts, boot boundaries, duplicate events, interruptions, IPC failures and storage recovery.

**Done when:** CLI retrieves genuine persistent events after recorder restart, with accurate provenance and no unsupported visibility claims.

### Phase 2 — Evidence-based investigations (v0.2)
- Wake incident queries, selected OS diagnostic snapshots, deterministic event correlation, surfaced via `ghosttrace investigate wake`.
- Explanations with exact evidence links, uncertainty, missing coverage, and alternative hypotheses.
- Unit tests from synthetic wake scenarios, including deliberately misleading post-wake activity.

**Done when:** an investigator can distinguish an observed cause indicator from mere correlation.

### Phase 3 — Resource & file analysis (v0.3)
- Process resource sampling and configurable overhead; data downsampling for charts.
- User-selected FSEvents path watching with clear limits on writer attribution.
- Memory-spike and file-change investigators, robust gap detection, export, and matching CLI commands.

**Done when:** investigations remain interpretable and resource consumption stays within profiled targets.

### Phase 4 — Reliable background operation (v0.4)
- Implement authorized launch-at-login/background agent as appropriate to current macOS ServiceManagement APIs.
- Harden XPC agent/CLI/SwiftUI communication, deliver polished SwiftUI timeline and inspector, restart recovery, migration safety, structured diagnostics.
- Sleep/wake and overnight soak testing; benchmark overhead and DB growth.

**Done when:** collector persists as designed across app-window closure and can be fully paused/uninstalled cleanly.

### Phase 5 — AI/MCP and advanced monitoring (v0.5–v1.0)
- Read-only local MCP adapter over the **same local service contract** (do not create a second event store), permission controls and source-grounded summaries.
- Optional advanced Endpoint Security collector only if Apple approves the entitlement and signing/deployment requirements are satisfied.
- Packaging, signing/notarization where applicable, documented privacy model, performance tests, onboarding and troubleshooting.

**Done when:** feature claims are aligned with granted privileges, automated tests pass, and user can understand what is and isn't monitored.

### Phase 6 — System monitor (v0.6)
- Extend the resource sampler with system-wide CPU, GPU, network, disk and free space, battery, and per-process energy and disk I/O (your own processes), stored on change within the recorder's budget.
- A live view in the window (an unstored `live` IPC read, only while the window is open), alerts (fast battery drain, disk nearly full, critical memory pressure, sustained high CPU or GPU) shown by the menu bar app, and battery, network and disk investigators in the CLI, the app and MCP.
- Design: `docs/superpowers/specs/2026-10-28-system-monitor-design.md` (approach A: extend the existing sampler).

**Done when:** each new metric is either recorded or labelled unavailable with the reason, the alerts fire once per incident, the investigators cite evidence, and the recorder stays within its measured CPU and memory budget.

### Phase 7 — Final debug, graph, cleanup and public release (after Phase 6)
Re-ordered by the user on 2026-10-29. The steps run in this order.

1. **Final debug of the whole app.**
   - Exercise every feature end to end on this Mac:
     - the recorder under launchd;
     - every CLI command;
     - every MCP tool, through a real Claude agent run;
     - every app pane;
     - the menu bar items;
     - the alerts and their banners;
     - the investigators on live data;
     - pause and resume, the on/off switch, and a reinstall.
   - Fix every bug found, with a test for each.
   - Re-measure the budget: recorder `footprint` and CPU, and the idle menu bar app.
   - Done when the full suite is green, the Release build has no warnings, and the bug list in the progress log is closed or explicitly deferred with the user's agreement.
2. **Map the project with graphify.** Run a full `/graphify` pass over the finished code, not just `--update`, so the graph and `GRAPH_REPORT.md` describe the final app.
3. **Final cleanup.**
   - List every file and folder created during the work that the shipped product does not need:
     - scratch and proof-of-concept files;
     - build output outside `.gitignore`;
     - superseded or duplicate docs;
     - empty stub modules;
     - temporary helper scripts;
     - the `.superpowers/sdd/` workspaces;
     - leftover test homes such as `/tmp/gtp*`.
   - Remove the XPC proof-of-concept launchd job if it still exists: confirm `com.ghosttrace.poc` is unloaded (`launchctl print gui/$(id -u)/com.ghosttrace.poc` fails) and delete its plist from ~/Library/LaunchAgents.
   - Keep: source, tests, README, `.gitignore`, `.graphifyignore`, this plan and its progress log, the `docs/` decision records and screenshots, and `graphify-out/`.
   - Present the candidate list with full paths and wait for the user's approval before deleting anything. Never delete source, tests, user files or anything outside the project folder.
   - After the approved deletions, rebuild, rerun the suite, and run `/graphify --update`.
4. **Publish the final version to GitHub.**
   - Turn the project folder into a git repository with a `.gitignore` that excludes build output (`.build`, DerivedData, xcuserdata, `dist/`).
   - Push to `Nexace/GhostTrace`.
   - Rewrite the README for a public reader. It covers:
     - what GhostTrace records and why;
     - screenshots of every pane, the menu and the alerts (in `docs/screenshots/`), each with a short caption;
     - install and build steps;
     - the CLI and MCP commands;
     - the privacy model;
     - known limits.
   - Set the repo description, topics and homepage.
   - Make the repo public. Pushing and changing visibility are outward-facing, so confirm both with the user at that moment, even though this plan names them.

**Done when:**
- the final debug is closed;
- the graph is rebuilt;
- the approved cleanup is complete and the build and tests still pass;
- no proof-of-concept launchd job remains;
- the final version is pushed, with an illustrated README;
- the repo is public, after the user's go-ahead;
- the final file tree is recorded in the progress log.

## Test strategy

- Unit: normalization, identity, time conversion, ordering, causality labels, data retention, migrations.
- Integration: actual workspace app launches; file rename/write in explicitly monitored test directory; timed resource-load fixture; sleep/wake manual test matrix.
- Reliability: agent crashes, disk-full, DB corruption, restart, clock corrections, boot changes, duplicate ingestion, dropped event reporting.
- Security/privacy: verify no event content leaves device by default; exports respect redaction settings; stop/uninstall halts recording.
- Performance: define measurable steady-state CPU, RAM, event latency, battery and DB-growth budgets after first profiling pass; optimize against empirical baselines rather than made-up targets.

## First tasks to execute now

1. Audit environment and choose deployment target / SQLite library.
2. Create the Swift project/package structure including recorder, IPC contracts, CLI target and a minimal SwiftUI host for consent/status.
3. Implement `Event`, `EventSource`, `EventStore` interfaces and SQLite persistence tests.
4. Implement the app-launch and sleep/wake collectors with correct availability caveats.
5. Implement and exercise a local XPC service/client proof of concept, confirming a standalone terminal CLI can connect under real signing/launch conditions; document a fallback only if needed.
6. Build working `ghosttrace status` and `ghosttrace events --last 24h --json` commands.
7. Run on a physical Mac and demonstrate capturing a reproducible app-launch test, then retrieving it through the CLI.
8. Add SwiftUI timeline/inspector after the recorder and CLI vertical slice works.
9. Summarize implemented features, exact build/test commands, outstanding permissions and next milestone.

**Operating rule:** Start coding Phase 0 and Phase 1 now. Do not attempt the entire v1.0 in a single untested change. When an API is uncertain, inspect SDK headers/documentation and run a minimal proof of concept. Do not fabricate verification outcomes.

## Progress log

### 2026-10-27 — Phase 0 handoff

**Phase 0 status: complete with one recorded unmet criterion (signed build).** Project: `/Users/amogh_khairate/projects/Ghost Trace` (not a git repo).

#### Gate results
| Gate item | Result | Evidence |
|---|---|---|
| App builds | Pass | `xcodebuild -project App/GhostTrace.xcodeproj -scheme GhostTraceApp -configuration Debug build` → `** BUILD SUCCEEDED **` |
| App launches | Pass | `open GhostTrace.app` → process running (`pgrep`); window screenshot showed the status screen with "Apple code signing: Missing (ad-hoc)" and "Endpoint Security entitlement: Missing"; quit cleanly via `osascript` |
| Smoke tests pass | Pass | `swift test` → Swift Testing runs: 2 tests (RecorderCoreTests), 1 test (EventStoreTests), 5 tests incl. 6 parameterized cases (CollectorsTests), all passed, 0 failures |
| Capability matrix in plan | Pass | Table below |
| Signed local debug build | **Unmet** | `codesign -dv` → `Signature=adhoc`, `TeamIdentifier=not set`; `security find-identity -v -p codesigning` → 0 valid identities |

#### Decisions
- Deployment target **macOS 14.0**: Apple Silicon Sonoma+, Observation and current SwiftUI APIs. Only macOS 27.0.1 has been run.
- SQLite: **SDK `SQLite3` module**, no Swift package (no dependency approval needed). SDK header and runtime `sqlite3_libversion()` both 3.54.0.
- Layout: Swift package (`Package.swift`) for all modules + CLI + agent; thin `App/GhostTrace.xcodeproj` for the SwiftUI app, linking the package's `GhostTraceKit` product. Full rationale: `docs/adr/0001-foundation.md`.
- Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`), bundle ID `com.amoghkhairate.GhostTrace`, app not sandboxed, Swift 6 language mode.

#### Capability matrix (Phase 0)
| Capability | Status | Basis |
|---|---|---|
| Code-signing identity | unavailable | 0 identities installed; app reports ad-hoc as Missing at runtime (SecCodeCopySigningInformation, Security/SecCode.h) |
| Endpoint Security entitlement | unavailable | Not granted; runtime check via SecTaskCopyValueForEntitlement (Security/SecTask.h) reports absent; out of v0.1 scope |
| Full Disk Access | unverified | No public API reports it; not requested |
| App launch/quit (NSWorkspace) | unverified | Collector is Phase 1 |
| Sleep/wake (NSWorkspace) | unverified | Collector is Phase 1 |
| Power diagnostics (`pmset -g log`) | observed | Readable without sudo; output includes `Wake ... due to ...` lines (e.g. `Wake from Deep Idle [CDNVA] : due to smc.sysState.Wake...`) |
| Unified log (`/usr/bin/log show`) | observed | `--predicate 'process == "powerd"'` returned entries without sudo |
| CPU/memory sampling | unverified | Phase 3 |
| Selected file changes (FSEvents) | unverified | Phase 3 |
| SQLite (SDK) | observed | In-memory open/create/insert test passes |

#### Files and modules created
- `Package.swift`; `Sources/{RecorderCore,Collectors,EventStore,InvestigationKit,GhostTraceIPC,RecorderAgent,GhostTraceCLI}`; `Tests/{RecorderCoreTests,CollectorsTests,EventStoreTests}`.
- `RecorderCore`: `CapabilityState`, `CapabilityStatus`, `Collector` protocol, `CollectorError.permissionMissing`.
- `Collectors`: `SystemCapabilities.report(_:)` with injectable `SystemProbe` (live signing + entitlement checks).
- `EventStore`: `SQLiteLibrary.version` only.
- `InvestigationKit`, `GhostTraceIPC`: comment-only placeholders.
- `RecorderAgent`, `GhostTraceCLI` (product `ghosttrace`): print "not implemented yet (Phase 1)" and exit 1.
- `Tests/RecorderCoreTests/MockCollector.swift`: actor mock; refuses to start and reports `missing` without permission.
- `App/GhostTrace.xcodeproj`, `App/GhostTraceApp/{GhostTraceApp,CapabilityStatusView}.swift`.
- `README.md`, `docs/adr/0001-foundation.md`.

#### Working commands (run from the project folder)
- `swift build`
- `swift test`
- `xcodebuild -project App/GhostTrace.xcodeproj -scheme GhostTraceApp -configuration Debug build` (Phase 0 used `-derivedDataPath` in a scratch folder; the default DerivedData also works)
- Schemes listed by `xcodebuild -list`: `GhostTraceApp`, `GhostTraceKit`, `ghosttrace`, `RecorderAgent` (auto-generated; none are shared/committed)

#### Open blockers and unverified items
- Signed build criterion unmet until an Apple Development or Developer ID identity is installed. This will likely matter for the Phase 1 XPC proof of concept (launchd Mach services and code-signing requirements for peer validation); verify against SDK headers before relying on ad-hoc signing there.
- Deployment target 14.0 untested below macOS 27.0.1.
- The app reads capabilities in-process, not through the recorder; Phase 1 must route status through the IPC contract.
- `MockCollector` lives in `RecorderCoreTests` only; move to a shared test-support target when Phase 1 tests need it.
- No `.gitignore`/git repo; `.build/` is created in the project folder by `swift build`.

#### Starting state for Phase 1
Everything above builds and tests green. Phase 1 starts with the `Event` model in `RecorderCore`, the SQLite schema/migrations in `EventStore`, the app-launch and sleep/wake collectors in `Collectors`, and the IPC/packaging decision in `GhostTraceIPC`. No launchd plists, LaunchAgents, entitlements or dependencies have been added.

### 2026-10-27 — Phase 1 handoff

**Phase 1 status: done-when criterion met.** After a recorder restart, the CLI read back a real Calculator launch and quit, with provenance. The SwiftUI window was built and launched but not visually checked (screen access was declined).

#### Gate results
| Gate item | Result | Evidence |
|---|---|---|
| App lifecycle + sleep/wake collectors | Pass | `open -a Calculator` and quit gave `app_launch`/`app_exit` with pid 21699, `com.apple.calculator`, `/System/Applications/Calculator.app`, `occurredAt` from `NSRunningApplication.launchDate`. NSWorkspace notifications arrive in the plain agent process (main run loop). Sleep/wake confirmed on a real `pmset sleepnow` cycle (see below). |
| Schema/migrations, bounded ingestion, gaps, retention | Pass | 11 EventStore tests, 9 RecorderCore tests. Live: `kill -9` then restart recorded a `recorder_interrupted` gap; SIGTERM then restart recorded `recorder_stopped`; pause/resume recorded a `paused` gap. |
| Typed contract + local IPC | Pass, via the Unix-socket fallback | 8 IPC tests over real sockets: round trip, 0600 socket, not-running, garbage reply, closed reply, version mismatch. Live: socket `srw-------`, directory 0700, second agent refused by `flock`, stale socket after a crash reads as `stopped` (exit 3). |
| `status`, `events --last 24h`, `--json`, event detail | Pass | Run live against the agent. JSON is the `apiVersion: 1` envelope with UTC millisecond timestamps. |
| Minimal GUI | Built + launched; not visually verified | `xcodebuild ... build` gave `BUILD SUCCEEDED`; the app ran (pid 22037). The window was not inspected. |
| Ordering, time zones, boot boundaries, duplicates, interruptions, IPC failures, storage recovery | Pass | `swift test`: 37 tests, 4 targets, all green. Includes DST fall-back offsets, cross-boot ordering, idempotent inserts, quick_check recovery that moves the corrupt file aside, newer schema refused without moving the file. |

#### Decisions
- IPC: a Unix-domain socket with `getpeereid` same-uid checks on both ends, not XPC. Named XPC services need a launchd.plist (SDK headers), which is Phase 4. Full rationale and limits: `docs/adr/0002-recorder-ipc-and-storage.md`.
- Events are stored as JSON with indexed columns (`occurred_at`, `ended_at`, `kind`, `bundle_id`). Insert is idempotent on id. Retention is 30 days and 1M rows. JSON keys are camelCase; enum values are snake_case.
- Collector status is `observed` only after a real notification has been delivered; until then it reports `unverified` ("Listening").
- `stopped` is never self-reported: clients map a refused or missing socket to `recorder_not_running` (exit 3).

#### Files and modules
- `RecorderCore`: `Event.swift` (model, `RecorderClock`, `GhostTraceJSON`), `Query.swift`, `Ingestor.swift` (bounded queue, gap factories). `Collector.start(emit:)` now delivers events.
- `Collectors/WorkspaceCollector.swift`. `SystemCapabilities` no longer lists the app-lifecycle and sleep-wake placeholders.
- `EventStore/EventStore.swift`; `GhostTraceIPC/{GhostTraceIPC,UnixSocket}.swift`; `RecorderAgent/{main,Recorder}.swift`; `GhostTraceCLI/main.swift`.
- `App/GhostTraceApp/RecorderStatusView.swift` replaces `CapabilityStatusView.swift`.
- Tests: `RecorderCoreTests/EventTests.swift`, `EventStoreTests/EventStoreTests.swift`, `GhostTraceIPCTests/IPCTests.swift` (new target), `CollectorsTests/WorkspaceCollectorTests.swift`.
- `docs/adr/0002-recorder-ipc-and-storage.md`; README rewritten.

#### Open items for Phase 2+
- GUI not visually verified.
- The agent runs only in the foreground (no LaunchAgent, Phase 4). Database files created before the umask fix are 0644 inside the 0700 directory.
- Unclean-stop gaps can start up to 60 s early (heartbeat interval). `quick_check` runs on every start, which costs O(database size).
- Not built: disk-full handling beyond retry and keep-buffered, `related_subjects`, typed per-kind payloads (string map for now), a snapshot of apps already running at startup, and peer code-signing checks.

#### Real sleep/wake check (2026-10-27, after handoff)
`pmset sleepnow`, then woken by keyboard, with the recorder running (pid 22169):

| | GhostTrace event | Kernel (`kern.sleeptime`/`kern.waketime`), `pmset -g log` | Difference |
|---|---|---|---|
| Sleep | `sleep` 13:43:14.268Z from `NSWorkspaceWillSleepNotification` | 13:43:19.535Z, "Entering Sleep state due to 'Software Sleep'" | Notification arrives 5.3 s **before** the kernel sleeps, as expected for a "will sleep" notice |
| Wake | `wake` 13:44:24.552Z from `NSWorkspaceDidWakeNotification` | 13:44:24.280Z, "Wake from Deep Idle ... due to ... RTP.keyboard/UserActivity" | Notification arrives 0.27 s after the kernel wakes |

- No `event_gap` between the two: the recorder process was suspended during sleep but did not stop.
- The two events' `monotonicNanos` differ by 70.284 s, matching the 70.284 s wall-clock difference. This confirms `CLOCK_MONOTONIC_RAW` keeps counting through sleep (previously this came only from `time.h`).
- The wake reason (`RTP.keyboard/UserActivity`) is in the power log only, not in the NSWorkspace event. Extracting it is Phase 2.
- Still unverified: dark wakes (Power Nap) and lid-close sleep.

### 2026-10-27 — App icon (user-supplied art)

- **Art:** supplied by the user. A translucent cyan-to-violet ghost drifts over a radar/timeline grid, trailing a path of glowing event nodes, inside a glassy dark rounded square. The original is kept at `App/IconSource/ghosttrace-icon.webp` (1254×1254, opaque black background).
- **Processing:** the artwork itself was not changed.
  1. Found the glowing rim by brightness (> 60 against a background of ≤ 15): x 107–1139, y 93–1136. The corner radius fits at 234 px, about 23% (macOS uses about 22.5%).
  2. Cropped to the rim and fitted to Apple's macOS grid: an 824 px body centred in a 1024 canvas. This scales height about 1% more than width, which isn't visible.
  3. Masked outside the rounded rect to transparent, inset 1 px, so the Dock shows no black square.
  4. Added a soft drop shadow and exported the 10 `AppIcon.appiconset` sizes (16–1024 px).
- **Verified:**
  - `BUILD SUCCEEDED`.
  - The compiled `AppIcon.icns` contains the new art (extracted with `iconutil` and viewed).
  - The edges are clean on light and dark backgrounds. A 1 px dark hairline remains on the top rim at 1024 px, invisible at Dock sizes.
  - The app was relaunched; I did not see the Dock myself.
- **Replaced:** the earlier CoreGraphics-drawn icon and its `scripts/render-app-icon.swift`, both removed.

### 2026-10-27 — Phase 2 handoff

**Phase 2 status: done-when criterion met.** `ghosttrace investigate wake` labels every finding `observed`, `likely`, `correlated` or `unknown`, and each finding cites event ids. Synthetic scenarios with misleading post-wake app launches keep those launches `correlated`, ranked below the observed and likely findings. On real data from this Mac, the observed powerd reason and its interpretation are shown separately.

#### Gate results
| Gate item | Result | Evidence |
|---|---|---|
| Wake incident queries via `ghosttrace investigate wake` | Pass | `--at T --within D`, `--last`, `--from/--to`, up to 48 h; `--json` returns the `apiVersion: 1` envelope with `investigation`. A 72 h window is refused (exit 2). An old recorder answers the new method with a decode error (exit 2). |
| Selected OS diagnostic snapshots | Pass | `pmset -g log`: Sleep, Wake, DarkWake and Wake Requests lines become `diagnostic`/`imported` events. Live: 3,685 entries imported; the re-import added "0 new" (ids are hashes of the lines). Imports run hourly and before each investigation, and are skipped while paused (checked live). |
| Deterministic correlation, evidence links, uncertainty, missing coverage, alternatives | Pass | Real 19:14:24 wake: observed powerd reason `RTP.keyboard/UserActivity`, paired with the recorded NSWorkspace wake (<1 s later), then `likely` keyboard input. Real 17:00–17:46 window: 4 dark wakes and 1 full wake. Each timer wake was matched to the request due that second (dasd SleepService, powerd CSPNEvaluation). At 17:29:32 two requests were due, so both are listed as alternatives. The USB-C plug and lid/trackpad readings are `likely`. Limits say GhostTrace wasn't recording then. |
| Synthetic scenarios incl. misleading post-wake activity | Pass | 11 InvestigationKit tests built from real-format pmset lines: a timer wake plus Mail launching 1.5 s later; a keyboard wake plus Calendar; no power log (nothing `likely`); dark → full pairing; a timer with no due request; a wake in a recorder gap; a wake before the first run; an empty window; DST offsets; stable ids. |
| Whole suite | Pass | `swift test`: 49 tests in 5 targets, all green. `xcodebuild ... build`: `BUILD SUCCEEDED`. |

#### Decisions
- The power log is the only wake-reason source. Reason-code readings are `likely`, because Apple doesn't document the codes. Timer wakes are matched to requests due within ±5 s by time, not by type: at 17:11:27, `rtc/Maintenance` matched `powerd CSPNEvaluation`. Details: `docs/adr/0003-wake-investigations.md`.
- NSWorkspace notifications pair with the nearest power-log wake, from 2 s before to 10 s after it. App launches up to 2 min after a wake are `correlated` only (at most 5 listed).
- `InvestigationKit` no longer depends on `EventStore`. `GhostTraceIPC` depends on `InvestigationKit` for the result types. The IPC version stays 1, because the new method is additive.

#### Files and modules
- New: `Sources/Collectors/PowerLog.swift`, `Sources/InvestigationKit/InvestigationKit.swift`, `Tests/InvestigationKitTests/WakeInvestigatorTests.swift`, `docs/adr/0003-wake-investigations.md`.
- Changed:
  - `Request.window` and `Method.investigateWake`; `Response.investigation`; `RecorderClient.investigateWake`.
  - Recorder: power-log import, the `power-log` capability, and the investigate handler.
  - CLI: `investigate wake`, plus the shared `timeWindow`.
  - `CollectorError.commandFailed`. The "Power diagnostics (Phase 2)" placeholder capability is removed.
  - README; its pointer to this plan now uses the plan's new place in the project folder.

- Follow-up (same day): the default text output is now one short answer per wake (`WakeIncident.summary`, e.g. "Likely cause: a timer set by dasd (SleepService)."), followed by the recorder gaps and coverage limits. The full findings view moved to `--detail`. JSON gained `summary`.
- Follow-up (same day): the app has three tabs, Status, Wakes and Timeline, all through `RecorderClient`. Wakes shows each wake's `summary` (newest first), any app launched just afterwards, and the key limits; an Evidence disclosure shows the full findings. Timeline shows up to 5,000 events, newest first, filtered by window and kind, with a detail pane for source, payload, provenance and id. Both are deliberately unstyled; the user will restyle them later. Checked in the running app: Wakes listed 74 wakes for the last 24 h. Timeline was seen loading rows; its detail pane was not clicked, because the window was on a full-screen Space.

#### Open items for Phase 3+
- Still unverified: whether NSWorkspace posts a wake notification for dark wakes (none happened while recording), lid-close sleep, and reason codes on other macOS versions and Intel Macs.
- Imported power-log lines make `retainedSince` older than the recorder's first run. `events` listings now include many `diagnostic` rows (use `--kind`).
- Power-log coverage is tracked only as first/last read. A recorder outage of more than a week leaves a hole that isn't reported.
- No GUI for investigations yet (the Figma design is pending). The recorder was left running on the current build (started with `nohup`, not at login).

### 2026-10-27 — Menu bar icon

- The app shows a ghost icon in the menu bar while it runs: `MenuBarController` in `App/GhostTraceApp/GhostTraceApp.swift`, an `NSStatusItem` with a template image drawn in code. Clicking it brings the window forward, or reopens it if it was closed.
- The app's window is now a single `Window` scene. Closing it no longer quits the app (`applicationShouldTerminateAfterLastWindowClosed` returns false); quit with ⌘Q.
- The icon is an outlined ghost: 1.5 pt stroke, sized against the regular-weight SF Symbols (bolt, sun, Wi-Fi) at menu bar size. It is an 18 pt image in a 28 pt item. That matches the system icons' centre spacing (measured from a 2× screenshot: 76–81 px apart, while a 24 pt square sat at 74 px). A trimmed glyph in a `variableLength` item was tried first and sat even closer.
- Verified with System Events: the status item exists ("Open GhostTrace"). After the window closed, the app kept running with no windows, and clicking the item reopened the window.
- Not done:
  - The icon shows only while the app runs, not the recorder; the recorder has no icon of its own.
  - The icon does not change with the recording state.
  - There is no launch at login (Phase 4).

### 2026-10-27 — Phase 3 handoff

**Phase 3 status: done-when criterion met.** Every memory and file-change finding is labelled and cites event ids. No file-change finding names a writer, and memory investigations name a process only by its own measured growth. In a 5-minute profile of a release recorder at the default 30 s interval, resource use stayed within the targets below (under 1% CPU, under 50 MB RSS, about 7 MB/day of database growth from samples).

#### Gate results
| Gate item | Result | Evidence |
|---|---|---|
| Process resource sampling, configurable overhead | Pass | `ResourceSampler`: one `resource_sample` event per interval (default 30 s; `ghosttrace config --sample-interval`, 5 s to 10 min, persisted). Live: 563 of 787 processes readable (this user's), 7–16 ms per pass. |
| Downsampling for charts | Pass | IPC `resources` → `ResourceAnalyzer.summarize`: at most 500 points (average and peak memory, worst pressure, peak swap); empty buckets are left out. Used by `ghosttrace memory` (one-line chart) and the app's new Memory tab (Swift Charts), checked in the running app on real data. |
| User-selected FSEvents watching, writer limits | Pass | `ghosttrace watch add/remove/list`, persisted with each path's start time. Live: create, append and rename in a watched folder were recorded. The rename was paired from consecutive FSEvents ids, and every change says "Which process made this change is unknown." |
| Memory-spike investigator | Pass | `ghosttrace investigate memory`. Live: a 2 GB Python allocation was found by both the test recorder (5 s) and the real one (30 s): "Likely cause: Python, which grew by 2.0 GB." The system's "used" rose only 0.8 GB because macOS compressed other memory, and the finding says so. |
| File-change investigator | Pass | `ghosttrace investigate file-change --path P`: a path or anything under it, up to 30 days, with limits for unwatched paths, watches started inside the window, recorder gaps and dropped changes. |
| Robust gap detection | Pass | Sampling gaps are found from sample spacing (an interval change doesn't count). FSEvents drops and the 200/s rate limit become `watch_dropped` gaps. Power-log roll-offs between imports become `power_log_hole` gaps, which closes the Phase 2 open item. Each investigator ignores gap types that don't affect it. |
| Export | Pass | `ghosttrace export`: one JSON document. Watched paths are replaced by `redacted-<sha256 prefix>` unless `--include-sensitive` is given. `--output` writes mode 0600 and refuses to overwrite. Checked live. |
| Resource targets | Pass | Release `RecorderAgent`, 5 min at 30 s on this Mac: 1.02 s CPU in 300 s (0.34% of one core, including the startup power-log import), RSS 15–20 MB. A sample row was 3.7 KB with full process paths. Dropping the paths (the name, pid and start time remain) cut it to 2.3 KB: about 6.6 MB/day, or about 200 MB at the 30-day retention, well under the 1,000,000-row cap. |
| Whole suite | Pass | `swift test`: 76 tests in 5 targets, all green (49 before Phase 3). `xcodebuild … build`: `BUILD SUCCEEDED`. |

#### Decisions
Full detail: `docs/adr/0004-resources-and-file-changes.md`.
- **Sample storage.** A sample is stored as JSON in `payload["sample"]`, so there is no schema migration. Each sample keeps:
  - the top 10 processes by memory;
  - the top 5 by CPU;
  - anyone who grew by 256 MB or more.

  The sampler keeps every readable process's previous values, so growth and CPU are true per-process deltas.
- **Spikes.** A spike is any of these between consecutive samples:
  - pressure rising;
  - memory used rising by at least max(1 GB, 10% of RAM);
  - one process growing by 1 GB or more.

  Naming a cause is `likely` only when one process's growth is at least half the rise. Otherwise the cause is `unknown`.
- **FSEvents.**
  - Paths are canonicalised with `realpath`.
  - Records for one path within 0.5 s are one change.
  - Flags are shown as reported, with the caveat that they accumulate.
  - Historical replay (`sinceWhen`) isn't used, because its records carry no times.
- **IPC.** All additions are optional fields or new methods, so the API version stays 1. The new `RecorderStatus` fields are optional, so a Phase 2 status still decodes (tested).

#### Files and modules
- New:
  - `Sources/RecorderCore/Resources.swift`, `Sources/Collectors/ResourceSampler.swift`, `Sources/Collectors/FileWatcher.swift`;
  - `Sources/InvestigationKit/Resources.swift` and `FileChanges.swift`;
  - `App/GhostTraceApp/MemoryView.swift`, `docs/adr/0004-resources-and-file-changes.md`;
  - tests in InvestigationKitTests (`ResourceInvestigationTests`, `FileChangeInvestigatorTests`) and CollectorsTests (`ResourceAndFileCollectorTests`).
- Changed:
  - `Event.redacted()`, and the new `GapReason` cases `watch_dropped` and `power_log_hole`.
  - IPC: the new methods and fields, and the client calls.
  - Recorder: the sampler and watcher, watch and config persistence, the new handlers, and power-log hole detection.
  - CLI: `memory`, `investigate memory`, `investigate file-change`, `watch`, `config` and `export`.
  - The Phase 3 placeholder rows are removed from `SystemCapabilities`.
  - The app: the Memory tab, a shared `EvidenceList`, and new Status intro text.
  - README.

#### Incident during this phase
- While cleaning up a test recorder, `pkill -f debug/RecorderAgent` also stopped the user's own recorder (clean stop at 20:13:34; restarted at 20:13:55, a recorded 21 s `recorder_stopped` gap). It was restarted (by PID) on each later build and now runs the final one (pid 29498), so it samples memory. Test recorders are now stopped by PID only.

#### Open items for Phase 4+
- TCC-protected folders (Desktop, Documents, Downloads) as watch targets are unverified.
- System daemons and other users' processes can't be sampled without privileges, and that is reported.
- Changes made while the recorder is stopped aren't recovered.
- The Memory chart draws lines across stretches without samples; the stretches are listed as limits instead.
- There is no GUI for watches or file-change investigations yet (CLI only; Figma pending).
- Sample rows are about 2.3 KB each, so 30 days at 30 s is about 200 MB. Old samples are not thinned yet (for example, keep 30 s detail for 2 days, then 5 min). This is the main storage cost; a 60 s interval halves it.
- Overhead was profiled for 5 minutes, not overnight. A soak test is Phase 4.

### 2026-10-27 — Menu bar app and background recording (user request, ahead of Phase 4)

Asked for directly: recording shouldn't need the app open, and the app should live in the menu bar with an option to open the window. This covers only Phase 4's first bullet (launch at login). The rest of Phase 4 (XPC hardening, migration safety, soak tests) is not started.
- **Recorder as a LaunchAgent.** A new Xcode tool target `RecorderAgent` compiles `Sources/RecorderAgent` (a synchronised folder) against `GhostTraceKit`.
  - The app embeds it in `Contents/MacOS` and embeds `App/LaunchAgents/com.amoghkhairate.GhostTrace.recorder.plist` in `Contents/Library/LaunchAgents`.
  - The plist sets `BundleProgram`, `RunAtLoad`, `KeepAlive` and `ThrottleInterval 30`.
  - The app registers it with `SMAppService.agent(plistName:)`.
  - The existing single-recorder lock decides who records. A second recorder exits, and launchd retries it every 30 s.
- **Menu bar app.**
  - `LSUIElement`: no Dock icon until the window opens. Then the app turns regular for the Dock, ⌘-Tab and Edit menu, and returns to the menu bar when the window closes.
  - The window is created by `MenuBarController`, not a SwiftUI `Window` scene, so it doesn't open when launched as a login item. That case is detected from the launch Apple event (`keyAELaunchedAsLogInItem`).
  - The menu: recording state (live from `status`), Open GhostTrace (⌘O), Pause/Resume, Record in Background ✓, Open at Login ✓ (`SMAppService.mainApp`), and Quit.
  - If macOS needs approval, the toggle opens Login Items instead.
  - Both login items are registered on first launch only; after that, the user's choices stand.
- **Checked on this Mac** (macOS 27.0.1, ad-hoc signed, app installed to `~/Applications`):
  - launchd ran the bundled recorder (`launchctl print`: running, keepalive, runatload).
  - With the app quit, `ghosttrace status` still showed it recording.
  - After `kill -9`, launchd restarted it about 30 s later (runs = 2), and the outage was stored as a `recorder_interrupted` gap.
  - The menu showed every item, and both toggles were checked.
  - The terminal-started recorder (pid 29498) was stopped by PID first, so the launchd one could take the lock.
- **Unverified:**
  - Behaviour across a real logout or login: the recorder starting at login, and the window staying closed. The login-item Apple event isn't confirmed for `SMAppService.mainApp` launches.
  - Whether a future Developer ID signature changes the approval flow.
- **Logs.** The recorder's stderr isn't captured under launchd. Structured diagnostics are Phase 4.

### 2026-10-27 — Overhead pass: near-zero CPU, recorder under 5 MB (user request)

Asked for: as light as possible, CPU near zero, the recorder under 5 MB (Activity Monitor's "Memory", measured with `footprint`). Full decisions: `docs/adr/0004-resources-and-file-changes.md`, section "Overhead pass".
- **Results** (release build, 10 minutes idle, nothing attached to the processes):
  - Recorder: 0.15 s CPU (0.025% of a core), 4.6 MB footprint.
  - Menu bar instance: 0.01 s CPU, 10 MB.
  - Stored samples: 1.46 KB each (was 2.3 KB, and 3.7 KB at first), stored only on change. That is about 0.2 MB a day when quiet, against 6.6 MB a day before.
- **Recorder memory.**
  - Before: 7.6 MB idle and 33–35 MB after a 48-hour wake investigation (26 MB 20 s later). The live heap was only 0.76 MB; the rest was freed pages the default allocator kept.
  - `MallocSpaceEfficient=1` in the LaunchAgent fixed most of it: 4.1–4.2 MB after the same queries, against 20–22 MB without it, side by side on copies of the database.
  - Also: wake investigations no longer load memory samples, the SQLite cache is capped at 512 KB, `pmset` output is streamed, and free pages are handed back after requests and imports.
- **Recorder CPU.**
  - One `proc_pid_rusage` per process per check (was three calls).
  - Event-driven flushes instead of a 1 s timer.
  - Daily power-log import that parses only new lines (was hourly, all lines).
  - A 5-minute heartbeat (was 60 s), a daily retention purge (was hourly), and timer leeway.
- **Storage.** Samples are stored only on change: 1 GB in use, 512 MB in one process, or pressure, with a 10-minute heartbeat. Each sample lists the top 6 by memory and top 3 by CPU (was 10 and 5).
  - The first thresholds (512 MB and 256 MB) kept 42 of 337 rows on 2.8 hours of real samples. A live run still stored 7 in 10 minutes, because of browser-tab and video-decoder swings, so they were raised.
- **Menu bar.**
  - A status item alone costs about 11.5 MB in any process (measured: a bare process 2.2 MB, with an `NSStatusItem` 11.5 MB), so the menu bar part can't reach 5 MB.
  - The app is now two instances of one bundle: a plain-AppKit menu bar instance, and a `--window` SwiftUI instance that "Open GhostTrace" starts and that quits with its window. Before, one instance stayed at 28 MB after its window closed.
  - `LSEnvironment` sets `MallocSpaceEfficient=1` for the app too.
- **Ad-hoc signing and launchd.** launchd refused each rebuilt recorder (`OS_REASON_CODESIGNING`), because registration pins the ad-hoc signature.
  - When the bundled recorder's modification time changes, the menu bar instance unregisters it and registers it again once the unregister completes.
  - It waits until the old job is gone, because registering while it still existed kept the old signature (intermittently).
  - If the recorder still doesn't answer 45 s later, it retries once.
  - Checked with five reinstalls: from a failed job, and four times from a running one, three of them in a row with the recorder rebuilt each time. Each ended with a fresh launchd job running the new binary.
- **Corrections to earlier notes.**
  - The Phase 3 handoff's "15–20 MB" was RSS, which includes shared framework pages. The footprint was 7.6 MB.
  - The menu bar icon had reverted to the filled ghost: my rewrite of `GhostTraceApp.swift` for the menu bar work started from a copy read before the outline change and overwrote it. The outlined ghost (1.5 pt stroke, 28 pt item) is restored.
  - A CPU burn in one menu bar instance (about 12% of a core) came from my accessibility tools (computer-use, System Events) attached to that process. With every mouse move it re-set the cursor, which this Mac's pointer settings re-render with a blur. A fresh instance used 0.01 s in 2.5 minutes, and a plain status item 0.09 s in 2 minutes.
- **Not verified.**
  - The window instance quitting when its window is closed by a click: the automation tools couldn't reach that instance. It relies on AppKit's standard last-window rule.
  - Behaviour across a real logout or login.

### 2026-10-28 — Phase 4 handoff

**Phase 4 status: done.** Every gate passed on this Mac (overnight soak and logout/login checked 28 Oct). One accepted gap: the Uninstall menu item is built but has not been run, because running it removes the real install; test it on a copy before release.
- **Met:** recording persists with the app window closed and the app quit, and pause now stops all collection.
- **Built, not run:** uninstall exists, but it wasn't run on this Mac because that would remove the user's install.
- **Waiting on time or input:** the overnight soak, a real logout/login, and the polished UI (Figma). XPC is done ("2026-10-28 — XPC hardening" below).

#### Gate results
| Gate item | Result | Evidence |
|---|---|---|
| Launch at login / background agent | Pass | Real logout/login on 28 Oct: the recorder stopped cleanly at 15:39:51 (`recorder_stopped`), launchd started it again by itself at 15:40:04 after login (pid 46487), and the 15 s logged out is one `event_gap`. The menu bar app came back as a login item and the window stayed closed (no `--window` process); the user confirmed the menu showed Recording. |
| Pause | Pass | Pause stops every collector, and resume restarts them. Live: while paused, sampling and FSEvents both said "Not running.", and a file written while paused never appeared. |
| Uninstall | Built, unverified | Menu: Uninstall GhostTrace… (turns both login services off, waits for the recorder to exit, optionally moves the data folder to the Trash, clears the defaults, then shows the app in Finder). Release build succeeded. The flow wasn't run. |
| Restart recovery | Pass | FSEvents history replay from a saved checkpoint (ADR 0005). Live, with a throwaway recorder: a change made after a clean stop came back as one `replayed` change spanning the stop. After `kill -9`, the change recorded live appeared once and the change made after the crash was replayed. New live test: `changesMadeWhileStoppedAreReadBackFromTheCheckpoint`. |
| Migration safety | Pass | `VACUUM INTO` backup before an upgrade, explicit rollback on failure, and 0600 files at every open. Tests cover the upgrade, the failed migration and the file modes. The live database's files are now 0600. |
| Structured diagnostics | Pass | Unified log (subsystem `com.amoghkhairate.GhostTrace`), `ghosttrace logs`, and `databaseBytes`/`schemaVersion` in status (CLI and app). Checked live. |
| XPC hardening | Pass | Done later the same day ("2026-10-28 — XPC hardening" below): the launchd recorder answers XPC only, to programs signed by the same team. Live: the signed CLI works, an unsigned one is refused. ADR 0005. |
| Polished SwiftUI timeline and inspector | Pass | Built from the Figma design ("GhostTrace — macOS UI"): sidebar, Overview, Timeline with inspector, Wakes, coloured icon tiles, Liquid Glass cards, and the menu's status row. Installed and checked on screen in dark mode with live data (`docs/screenshots`). Light mode unchecked; Files and Settings panes not built. |
| Overnight sleep/wake soak | Pass | Night of 27–28 Oct, launchd recorder pid 40636 (started 00:54:23, replaced by a reinstall at 14:42): sleep recorded at 01:31:36, wake at 14:31:18 (13 h asleep), no `event_gap` between 00:54 and the reinstall, 52 samples during maintenance wakes, about 390 power-log wake entries overnight, and no error-level lines in `ghosttrace logs`. Its CPU and memory over the night weren't measured (the process was replaced before the check); the replacement measured 0.7% of one core in its first 3 min (startup import included) and 34.5 MB RSS. |
| Overhead and DB growth | Partial | 17 min of the launchd recorder: 0.17% of one core including queries, about 0.02% idle. Footprint 4.6 MB. RSS 13–17 MB idle, about 31 MB right after paging the whole history. Rows are about 2.4 KB per sample, projected at 2–6 MB a day, so thinning isn't needed yet (ADR 0005). |
| Whole suite | Pass | `swift test`: 85 tests, all green. `xcodebuild … -configuration Release build`: `BUILD SUCCEEDED`. |

#### Files and modules
- **New:** `docs/adr/0005-reliable-background-operation.md`, `scripts/soak-report.sh`.
- **Changed:**
  - `EventStore`: the migration backup, rollback and file modes, plus injectable migrations for tests.
  - `FileWatcher`: `checkpoint`, `replayChanges` and the history replay.
  - `ResourceSampler.stop`: resets the baseline.
  - `Recorder`: pause stops collectors, the checkpoint is saved and replayed, the unified log, and the new status fields.
  - IPC: `logSubsystem`, `databaseBytes` and `schemaVersion`.
  - `FileChangeInvestigator`: replayed changes as intervals, and the restart-gap wording.
  - CLI: `logs`, the database size, and change intervals.
  - The app: the Uninstall menu item and the database size on the Status tab.
  - README.

#### Open items for Phase 5+
- **Overnight soak:** run `scripts/soak-report.sh` after a night with the lid closed. Compare the pid, launchd `runs`, gaps, and sleep/wake counts.
- **Logout/login:** check the recorder starts at login and the window stays closed.
- **Uninstall:** run it once on a test install, ideally a copy of the app in another folder with its own registration.
- **Launch-constraint kills:** `~/Library/Logs/DiagnosticReports` has three `RecorderAgent` reports from 2026-10-27 (23:09, 23:38, 23:52). Each is SIGKILL "Launch Constraint Violation" from launchd during development reinstalls. `reregisterIfRebuilt` recovered each time. A real signing identity would end this.
- **XPC:** done, see "2026-10-28 — XPC hardening".
- **UI:** the Figma-based timeline and inspector, and a GUI for watches and file-change investigations.
- **FSEvents replay limits:**
  - If FSEvents' history was purged, or the volume's ids changed, the replay may be partial. That is recorded as a gap only when FSEvents flags it.
  - TCC-protected watch targets are still unverified.

### 2026-10-28 — XPC hardening

**Status: done.** The launchd recorder answers XPC only, to programs signed by the same team. The decision and its limits are in ADR 0005.

- **Certificate.** After the user signed in to Xcode with a Personal Team (5PCPH987YL), `xcodebuild … -allowProvisioningUpdates build` created `Apple Development: khairate.amogh@gmail.com` from the command line (valid until 2027-10-27). `security find-identity -v -p codesigning` now lists 1 identity. The app and `RecorderAgent` targets use automatic signing with the team, and macOS 26 is the deployment target (Package.swift tools 6.2).
- **Transport rule.** Under launchd (`XPC_SERVICE_NAME` equals the label, checked with `launchctl print`): XPC only, no socket. Terminal and test recorders: the socket, unchanged. Clients: the socket when `GHOSTTRACE_HOME` is set, otherwise XPC.
- **Design.** `Envelope { json: Data }` carries the socket's JSON, and both transports run the same `decodeRequest`. The listener and the session both use `.isFromSameTeam()`. The agent plist has `MachServices`. `scripts/sign-cli.sh` signs the CLI.
- **Live checks** (reinstalled signed app; new recorder pid 40636, `state = running`; no approval prompt was needed):
  - Signed CLI `ghosttrace status` over XPC shows the recorder; `events`, `memory` and `investigate wake` also work. A 30-day `events --json` (112 KB) came back intact.
  - An ad-hoc debug `ghosttrace status` without `GHOSTTRACE_HOME` is refused with `permission_denied` (exit 4) and the message that names `scripts/sign-cli.sh`.
  - The launchd recorder created no `recorder.sock`; the data folder holds only the database files and the lock. (The old socket was removed when the old recorder stopped.)
  - A terminal recorder with `GHOSTTRACE_HOME=/tmp/gtp5` answered both the debug and the signed CLI over the socket, and removed its socket on a clean stop.
  - `codesign -dv`: the app, its `RecorderAgent` and the signed CLI all show `TeamIdentifier=5PCPH987YL`; the debug CLI is ad-hoc.
- **Probe finding.** A rejected peer (either side) and a recorder dying mid-request both surface as "interrupted", so the client's `permission_denied` message names both. A name nobody holds fails at lookup and maps to `recorder_not_running`.
- **Tests:** `swift test`, 88 tests, all green (3 new: the envelope round trip and the shared request checks, and the transport choice). `xcodebuild … -configuration Release build`: `BUILD SUCCEEDED`. The Mach service can't be tested under `swift test`; it was checked live.
- **Files.** New: `Sources/GhostTraceIPC/XPCTransport.swift`, `scripts/sign-cli.sh`. Changed: `UnixSocket.swift` (transport parameter, shared `decodeRequest`), `RecorderAgent/main.swift`, the agent plist, Package.swift, `project.pbxproj`, ADR 0005, README.
- **Not verified.** The menu bar and window tabs over XPC were not looked at on screen. The signed CLI was checked; the menu bar app's own startup check did open a connection to the Mach service (visible in the unified log), but I didn't see its result. The client's timeout path over XPC wasn't exercised against a hung recorder. A real logout/login with the new signature is still untested. `reregisterIfRebuilt` is probably no longer needed, because launchd now pins the team and signing identifier instead of the build's hash, but it was left as is.

### 2026-10-28 — Phase 5 handoff

**Phase 5 status: done, with the parts Apple gates left out.** AI agents can read the recording through a read-only MCP server that is off until the user allows it. Endpoint Security and notarization weren't built, because both need Apple approval or a paid account that this team doesn't have, and nothing claims them.

#### Gate results
| Gate item | Result | Evidence |
|---|---|---|
| Read-only MCP adapter over the same service contract | Pass | `ghosttrace mcp` (`Sources/MCPBridge`): 7 read-only tools, each one IPC `Request` through `RecorderClient`, with no database access. It speaks MCP 2026-07-28 (`server/discover`, `_meta`, -32022) and the older `initialize` handshake. Checked live against the launchd recorder (pid 48571) over XPC with the signed CLI: `server/discover`, `investigate_wake` and `list_events` all answered. |
| Permission controls | Pass | Off by default. `ghosttrace mcp allow` / `deny` and a menu item ("Allow AI Agents to Read (MCP)") set it, and `status` shows it. The recorder refuses `client: mcp` requests while it is off, and refuses MCP writes at any time. Live: refused before allow, answered after, refused again after deny. Each change is a `collector_status` event, and each agent request is a unified-log line (`mcp investigate_wake`, …). Before each call the bridge also checks that the recorder is new enough to enforce the switch. |
| Source-grounded summaries | Pass | Results are the investigation JSON, with findings, confidence labels and evidence ids. The server's `instructions` tell the agent to cite ids, keep the labels and not present correlation as a cause. Event listings redact watched paths, as exports do. |
| Endpoint Security | Not built (gated) | The entitlement needs Apple's approval. The capability row already reports "missing … reduced-capability mode". ADR 0006. |
| Packaging, signing | Pass | `scripts/package.sh` builds the Release app, signs the CLI, checks that all three binaries carry team 5PCPH987YL, and writes `dist/GhostTrace-0.5.0.zip` (4 MB). Version 0.5.0. |
| Notarization | Not applicable | It needs a Developer ID Application certificate (paid program). The steps are in ADR 0006, untried. |
| Privacy model, onboarding, troubleshooting | Pass | `docs/privacy.md` (what is recorded, storage, who can read it, when data leaves the Mac, the agent caveat), `docs/troubleshooting.md`, and README sections "AI agents (MCP)" and "Packaging". |
| Performance tests | Pass | New `aMonthOfEventsStaysFastToQueryAndPurge`: 100k rows, a 24 h page query in 26 ms, the summary in 4 ms, and purging half in 0.19 s (debug build). |
| Whole suite | Pass | `swift test`: 95 tests, all green (6 new MCP tests, 1 performance test). `xcodebuild … -configuration Release build`: `BUILD SUCCEEDED`. The app was reinstalled to `~/Applications`, and launchd shows `state = running`. |

#### Decisions
- The MCP server is hand-written (about 200 lines) instead of using the Swift MCP SDK, so the package still has no dependencies. It lives inside the signed CLI so that it gets XPC access without a second signed binary.
- Results are one JSON text block with no `structuredContent`. A 24 h wake investigation is still about 168 KB (65 maintenance wakes and 135 evidence events), so agents should ask for short windows.
- The access switch records consent; it isn't a security boundary. Same-team signing is the boundary, and `client` is self-declared.
- `TimeArgument.window` is now shared by the CLI and the MCP tools.

#### Files and modules
- **New:** `Sources/MCPBridge/MCPServer.swift`, `Tests/MCPBridgeTests/MCPServerTests.swift`, `docs/adr/0006-mcp-and-release.md`, `docs/privacy.md`, `docs/troubleshooting.md`, `scripts/package.sh`.
- **Changed:**
  - IPC: `Request.client`, `mcpAccess`, `Method.isReadOnly`, `mcpRefusal`, `RecorderStatus.mcpAccess`, `TimeArgument.window`, and `RecorderClient.client` / `configure(mcpAccess:)`.
  - `Recorder`: the gate, the audit log line, the `mcp_access` state, and `configure`.
  - CLI: `mcp` and the status line.
  - The app's menu item.
  - Package.swift, `MARKETING_VERSION` 0.5.0, `.gitignore` (`dist/`), README.

#### Open items
- **Real agent client: done (same day).** Registered with Claude Code 2.1.310 in local scope (`claude mcp add ghosttrace -- "<project>/.build/out/Products/Release/ghosttrace" mcp`), and `claude mcp get` showed "Connected".
  - With access off, a `claude -p` agent got the `permission_denied` text and relayed it without retrying.
  - After `ghosttrace mcp allow`, an agent answered "why did this Mac wake in the last 3 hours" from `get_recording_status` and `investigate_wake`. It cited event ids, kept the observed/likely/unknown labels, and called the post-wake app launches correlated only.
  - Access was left allowed, at the user's request. The registration points at the build folder, so a `swift build -c release` without `scripts/sign-cli.sh` leaves it unsigned and refused.
- **The menu item** builds and reads `mcpAccess`, but nobody has looked at it on screen or clicked it.
- **Carried over:** the uninstall flow is still unrun, light mode and the Files/Settings panes are still unbuilt, and the FSEvents replay limits (ADR 0005) still apply.

### 2026-10-29 — Phase 6 handoff

**Phase 6 status: built, reviewed and fixed after the final review; budget, unplug and MCP checks measured; a real banner click re-test is part of Phase 7's final debug.** GhostTrace records system-wide CPU, GPU, network, disk and battery, raises four alerts, shows a live System pane, and explains battery, network and disk incidents with cited evidence. Everything runs on the existing 30 s check; a "Record System Activity" switch turns the system part off. Decisions and costs: `docs/adr/0007-system-monitor.md`. The task ledger was `.superpowers/sdd/2026-10-28-system-monitor/progress.md`; Phase 7 moved the workspaces out of the repository, to Claude's project folder.

#### Gate results
| Gate item | Result | Evidence |
|---|---|---|
| Each metric recorded or labelled unavailable | Pass | CPU, GPU, memory, network, disk, battery and free space are stored on change, or the tile and `ghosttrace system` say "Not available" with the reason. Network counts `en*` only. |
| Alerts once per incident | Pass (banner click re-test in Phase 7) | Live: `sustained_load` start and end once each, no duplicate after a recorder restart, the app fetched the alert. Banner: none showed while macOS notifications were off for GhostTrace; after the user allowed them, a banner appeared on a re-sent alert; clicking it opened Overview, not the Timeline. Fixed in the final fix wave. Verified on screen 2026-10-30: the user opened the window with `--select-event` for the 22:39 alert and it opened on Timeline with the alert selected. The real banner click is still a Phase 7 re-test. |
| Investigators cite evidence | Pass | `investigate battery\|network\|disk`, CLI and MCP; every finding cites event ids. Live: disk named dd for a 2.0 GB write (likely, 69%); 24 h battery and network runs took 2 s each. Real unplug (2026-10-29, 23:57): `investigate battery --last 2h` gave two stretches split at the reinstall's recorder_stopped gap; 22:53-23:57 went 85 to 80%, 4.7%/h, 4.5 W average, main cause unknown, launches correlated only, measured processes "at least 2%". MCP agent run (2026-10-30): `mcp allow`, a `claude -p` run with only `investigate_battery` answered with the drain (85 to 79%, 4.8%/h, cause unknown, labels kept) and cited event ids including the recorder_stopped gap; then `mcp deny`, status back to "not allowed" |
| Budget, switch on | Pass (after the perf fix) | Phase 4: 0.025% of a core. 30-min soak before the perf fix (22:54-23:24, on battery, no accessibility tools): recorder 0.059% of a core (missed the 0.05% line), 5.3 to 5.0 MB; menu bar 0.008%, 11 MB. After the perf fix (free+purgeable lookup refreshed every 600 s instead of 60 s; interface names read in place), per check 13.5 to 7.0 ms; final 10-min live measurement after reinstall: recorder 0.028% (pass line 0.05%; Phase 4 0.025%), 5.0 to 5.2 MB; menu bar 0.003%, 11 MB; energy impact 0.0 for both. The menu bar's 11 MB is above Phase 5's 9-10 MB likely because the UNUserNotificationCenter delegate is set at launch (macOS requires it for banner clicks); this was not A/B measured. One reading of 19 MB came after about 80 minutes of use, with the menu opened and alerts delivered (heap left after activity). After the final fix wave (reinstall, 2-min settle, window closed, no accessibility tools on the recorder, on battery, 23:18-23:23): recorder 0.08 s per 300 s = 0.027% of a core, footprint 5.3 MB (5,329 to 5,265 KB). |
| Budget, switch off | Pass | On a throwaway recorder at 30 s, 0.13 s (off) vs 0.27 s (on) per 600 s before the perf fix and 0.11 s vs 0.14 s after it; Task 12's 120 s test: off 0.11 s vs on 0.20 s. The live switch-off cost was not measured separately. |
| On/off switch | Pass for CLI and IPC | Off stops system fields, alerts, `nettop` and `live`; the off span is a `system_monitor_off` gap that investigators state. Menu checkmark and pane toggle not looked at on screen. |
| Whole suite | Pass | 199 tests, 0 failures (193 after the perf fix; 192 at Task 12 fix round); Release `xcodebuild` BUILD SUCCEEDED. `swift test` green; `dist/GhostTrace-0.6.0.zip` 4,795,242 bytes |

#### Decisions
- Network sums only `en*` interfaces; a counter reset counts as 0 bytes. Both under-count rather than invent a spike.
- Readings store on change (charge down 5 points, CPU or GPU across 80%, network or disk across 10 MB/s, power source change, free space down 1 GB) plus the 10-min heartbeat.
- Alerts: banners for starts only; state saved on start or end only; windows need 2 readings spanning them, with a readings cap of `max(24, 600/interval + 3)`.
- `nettop` runs only on a network busy edge; an "ended" snapshot always follows a started one.
- Disk bursts that are mostly reads are not write bursts and are left out with a counting limit.
- The system monitor can be switched off; the off span is an `event_gap` with the new reason `system_monitor_off`, and investigators show it as missing data.
- `status()` computes the signing and capability checks once per process (0.48 → 0.15 ms CPU per call on a socket benchmark; 1.0 → 0.45 ms live over XPC).
- `live` is not an MCP tool. The MCP tool set is now ten tools.
- No git: each task was checkpointed with scratchpad snapshots and diff packages, and reviewed from those.

#### Files and modules
- **New:** `SystemReader`, `ActivityTracker`, `AlertMonitor`, `NetTop` (Collectors); `BatteryInvestigator`, `NetworkInvestigator`, `DiskInvestigator` (InvestigationKit); `App/GhostTraceApp/SystemView.swift`; `docs/screenshots/system-pane.png`; `docs/adr/0007-system-monitor.md`.
- **Changed:** `ResourceSample.system` and per-process energy and disk fields; `EventKind.alert`; `GapReason.systemMonitorOff`; IPC (`live`, `investigateBattery|Network|Disk`, `Request.systemMonitor`, `RecorderStatus.systemMonitor`); `Recorder` (alerts, `nettop`, the switch); CLI (`system`, `investigate battery|network|disk`, `config --system`); MCP (three tools); the menu bar app (banners, Show Alerts, Record System Activity); README, privacy, troubleshooting.

#### Open items
- **Banner check:** the idle load raised `sustained_load`; no banner showed while macOS notifications were off for GhostTrace; after the user allowed them, a banner appeared on a re-sent alert; its click opened Overview, not the Timeline. Fixed in the final fix wave (model built with `State(initialValue:)`), and verified on screen 2026-10-30: the user opened the window with `--select-event` for the 22:39 alert and it opened on Timeline with the alert selected. The real banner click (warm and cold) is still a Phase 7 re-test.
- **Final fix wave** (final-review-report.md, final-fix-report.md): alert names now list processes that started since the previous sample (lifetime averages), "among your processes", each with its figure, duplicates collapsed; the menu says when banners are off; banner click and window races; a pause resets the tracker; unmeasured bytes are nil, not 0; the battery investigator's divide-by-zero trap; failed free-space lookups cached; "while you were away" only when idle was read.
- **Not looked at on screen:** the menu checkmark, the System pane toggle, the "Banners Are Off" menu line, the Timeline opening from a click, the "Explain" button; the screenshot is dark mode only.
- **Deferred from reviews** (full list in ADR 0007): no hysteresis at 80% for the store trigger; alert windows restart after a recorder restart; `nettop` names cut to 15 characters; per-process identity is by name; Recorder wiring has no tests.
- `ADR 0006` and the Phase 5 entry still list seven MCP tools, correctly for that phase.

### 2026-10-31 — Phase 7 handoff (steps 1–2)

**Step 1, final debug: closed 2026-10-31.** The full suite passes (202 tests), and the Release build has no project warnings. Every bug below was found live and fixed; each has a test unless it is a one-line UI change.

#### Bugs fixed
- `ghosttrace system` printed "average 0 KB/s" for network and disk: `UInt64?.map(Double.init)` resolves to `Double(bitPattern:)`. Averages now come from `ResourceSummary.average(_:)` in InvestigationKit; the alert's disk-writer ranking had the same conversion.
- Release warnings: `EventTimelineView.maxEvents` (main actor) and "not stripping RecorderAgent because it is signed" (`COPY_PHASE_STRIP = NO`).
- `ghosttrace logs` showed `<private>` after lifecycle markers with no detail.
- Disk and network sizes used binary units labelled GB (317.5 GB where Finder says 340.9 GB). They now use decimal units (`ResourceSample.fileBytes`) everywhere; memory stays binary, as Activity Monitor shows it.
- MCP investigation replies were too large for agents (24 h battery 500 KB, wake 200 KB). The user chose slimmer evidence: each evidence event keeps id, kind, times, source, subject, payload without `sample`, and quality; `get_event` returns the rest. 24 h now: battery 69 KB, memory 25, network 15, disk 22, wake 155 (its findings are the bulk). The MCP server's version said 0.5.0.
- The Timeline's Week and 30 Days ranges showed the *oldest* 5,000 events under "Showing the newest 5,000". `EventQuery.newestFirst` (optional, so older clients still decode) pages newest first; the Overview's recent activity is now one 6-event query.
- UI labels: "Mcp Access Allowed" → MCP; raw `system_monitor_off` gap reason → "System activity off"; the System pane's Memory tile said "of 17.18 GB" (decimal) → 16 GB; "Zero KB/s" → "0 KB/s".

#### Verified live
- Every CLI command, bad-input exits, export hashing; all ten MCP tools from a Claude session (access allowed, then denied again); two reinstalls (launchd re-registered the recorder each time).
- All four panes, the Timeline filter and inspector, Explain this range with evidence, and the Record System Activity switch (driven in the background with computer use; the menu bar instance had to be quit by PID so the tools bound to the window instance).
- Load alert: `sustained_load` started after 5 min idle at ≥80% CPU and named the load ("yes ×5 475%"), stayed open while the load hovered at 70%, and ended a minute after the load stopped. A first run never fired because the trackpad registered touches (idle peaked at 271 s): correct behaviour.
- Warm banner click: opened the Timeline with the alert selected.
- Budget (10 min idle, on battery): recorder 0.028% of a core and 5,025 KB; menu bar app 0.00 s and 11 MB; energy impact 0.0 for both.

#### Deferred or not verified
- With the user's agreement: the cold launch by a banner click, and pane polling across a real sleep.
- The menu items, Pause/Resume from the menu and the "Banners Are Off" line: the user ran them but reported no details.
- The permission prompt when Show Alerts is turned on can't be re-shown: notifications are already allowed, and macOS asks once.
- Known, not changed: every wake query re-reads `pmset -g log` (about 4 s, 3.5 s of CPU); alert names count at most the top 5 CPU users stored in a sample.

**Step 2, graphify map: done 2026-10-31.** A full pass over 81 files gives 1,611 nodes, 4,338 edges and 64 labelled communities (`graphify-out/GRAPH_REPORT.md`). The health check reports 34 dangling-endpoint edges and 25 self-loops. This plan's progress log was not semantically extracted past line 285.

## Pending input: Figma UI design (to slot in before or with Phase 4)

The user will supply a Figma design for the GhostTrace app UI. When it arrives:
1. **Get the design.** Use a Figma link through the Figma connector, which must first be authorized in Claude Code with `/mcp` (it currently needs authentication), or exported frames or screenshots.
2. **Map it onto the plan's views:** Today, Timeline, Investigate, Evidence and Settings, plus the current recording-status and pause screen. Note any screen that needs data the recorder doesn't expose yet, and add that to the IPC contract first.
3. **Build it in SwiftUI in `App/GhostTraceApp`.**
   - All data comes through `RecorderClient` (the IPC contract); the app never opens the database.
   - Keep the honesty rules visible: observed / unverified / missing states, gaps, and "correlation is not causation".
   - Keep accessible labels, light and dark mode, and local-time formatting.
4. **Verify** with a real build and screenshots against the Figma frames, and record the differences here.
5. **Reuse the app icon** (`App/IconSource/ghosttrace-icon.webp`) unless the Figma file includes a newer one; if it does, reprocess it the same way and record the change.
