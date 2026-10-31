import Collectors
import EventStore
import Foundation
import GhostTraceIPC
import InvestigationKit
import notify
import os
import RecorderCore

/// Owns the store and the collectors, and answers IPC requests.
actor Recorder {
    static let retentionDays = 30
    static let maxRows = 1_000_000

    private enum Key {
        static let lastAliveAt = "last_alive_at"
        static let cleanStop = "clean_stop"
        static let bootSessionID = "boot_session_id"
        static let pausedAt = "paused_at"
        static let powerLogSince = "power_log_since"
        static let powerLogThrough = "power_log_through"
        static let sampleInterval = "sample_interval"
        static let watchedPaths = "watched_paths"
        /// "<FSEvents id> <ms>": the file watcher's checkpoint and when it was saved.
        static let fseventsCheckpoint = "fsevents_checkpoint"
        /// "1" once the user allows MCP clients; anything else means not allowed.
        static let mcpAccess = "mcp_access"
        /// `AlertMonitor.State` as JSON, saved when an alert starts or ends so an incident survives a restart.
        static let alertState = "alert_state"
        /// "Record System Activity": the time (ms) it was turned off; absent while on, the default.
        static let systemMonitor = "system_monitor"
    }

    let store: EventStore
    let clock: RecorderClock
    let collectors: [any Collector]
    let sampler: ResourceSampler
    let watcher: FileWatcher
    let ingestor: Ingestor
    let startedAt: Date
    /// Flushes, heartbeats and retention all run here, so the ingestor is only ever flushed from one queue.
    private let writer: DispatchQueue
    private var timers: [any DispatchSourceTimer] = []
    private var pausedAt: Date?
    /// When "Record System Activity" was turned off; nil while on. The span becomes a `system_monitor_off` gap when it's turned on.
    private var systemOffAt: Date?
    private var monitor = AlertMonitor()
    /// When `nettop` ran, in memory only: a restart may snapshot again, which is harmless.
    private var netTopGate = NetTop.Gate()
    /// Bridges the sampler's queue and the actor. A stored sample's event is emitted just after `onCheck` returns, so
    /// the check waits for it (to cite its id) in `pending`.
    private struct CheckFeed: Sendable {
        var pending: (reading: SystemReading, check: ActivityTracker.CheckResult, sample: ResourceSample)?
        /// The last stored sample and its event id: an alert's names and its evidence always come from this one sample.
        var last: (id: UUID, sample: ResourceSample)?
    }
    private let feed = OSAllocatedUnfairLock(initialState: CheckFeed())
    private var failedCollectors: [String: String] = [:]
    /// Signing and entitlements can't change while the process runs, and reading them is most of a status call's cost (~0.8 ms).
    private let fixedCapabilities = SystemCapabilities.report()
    private var powerLog = CapabilityStatus(id: "power-log", name: "Power log (pmset -g log)", state: .unverified, detail: "Not read yet.")

    /// `sampler` and `watcher` are configured over IPC, so they are passed separately as well as started with the other collectors.
    init(store: EventStore, clock: RecorderClock, collectors: [any Collector], sampler: ResourceSampler, watcher: FileWatcher) {
        self.store = store
        self.clock = clock
        self.collectors = collectors + [sampler, watcher]
        self.sampler = sampler
        self.watcher = watcher
        startedAt = Date(roundingToMilliseconds: clock.now())
        let writer = DispatchQueue(label: "ghosttrace.writer")
        self.writer = writer
        // Flushed a second after events arrive, not on a timer, so an idle recorder doesn't wake up.
        ingestor = Ingestor(clock: clock, write: { [store] batch in try store.insert(batch) }, whenBuffered: { ingestor in
            Self.flush(ingestor, on: writer, after: 1)
        })
        let feed = feed
        sampler.onCheck = { [weak self] reading, check, sample in
            if let sample {
                feed.withLock { $0.pending = (reading, check, sample) }
            } else if let self {
                let last = feed.withLock { $0.last }
                Task { await self.checkAlerts(reading, check, latest: last) }
            }
        }
    }

    private static func flush(_ ingestor: Ingestor, on writer: DispatchQueue, after seconds: Int) {
        writer.asyncAfter(deadline: .now() + .seconds(seconds), qos: .utility) {
            do { try ingestor.flush() } catch {
                log("flush failed, will retry: \(error)")
                flush(ingestor, on: writer, after: 5)
            }
        }
    }

    func start() async throws {
        if let moved = store.recoveredCorruptFile {
            record("storage_recovered", ["moved_to": moved,
                                         "detail": "The database failed SQLite's integrity check and was moved aside. Earlier events are only in that file."])
        }
        if let backup = store.migrationBackup {
            record("storage_migrated", ["schema_version": String(EventStore.schemaVersion), "backup": backup])
        }
        if let gap = Event.startupGap(lastAlive: try store.state(Key.lastAliveAt).flatMap(Int64.init).map(Date.init(milliseconds:)),
                                      cleanStop: try store.state(Key.cleanStop) == "1",
                                      lastBootSessionID: try store.state(Key.bootSessionID), clock: clock) {
            ingestor.submit(gap, whilePaused: true)
        }
        record("recorder_started", ["pid": String(getpid())])
        try store.setState(Key.cleanStop, "0")
        try store.setState(Key.bootSessionID, clock.bootSessionID)
        try store.setState(Key.lastAliveAt, String(clock.now().milliseconds))
        if let paused = try store.state(Key.pausedAt).flatMap(Int64.init) {
            pausedAt = Date(milliseconds: paused)
            ingestor.isPaused = true
        }
        if let saved = try store.state(Key.alertState).flatMap({ try? GhostTraceJSON.decoder().decode(AlertMonitor.State.self, from: Data($0.utf8)) }) {
            monitor = AlertMonitor(state: saved)
        }
        if let interval = try store.state(Key.sampleInterval).flatMap(Double.init) { sampler.setInterval(interval) }
        if let off = try store.state(Key.systemMonitor).flatMap(Int64.init) {
            systemOffAt = Date(milliseconds: off)
            sampler.systemMonitor = false
        }
        watcher.setPaths(Self.streamPaths(try watches()))
        if pausedAt == nil, let saved = try store.state(Key.fseventsCheckpoint)?.split(separator: " "), saved.count == 2,
           let id = UInt64(saved[0]), let savedAt = Int64(saved[1]).map(Date.init(milliseconds:)) {
            // Changes recorded live after the checkpoint (a crash between heartbeats) aren't replayed a second time.
            let recorded = (try? allEvents(from: savedAt.addingTimeInterval(-1), to: clock.now(), kinds: [.fileChange]))?
                .compactMap { $0.payload["fsevent_id"].flatMap(UInt64.init) }.max()
            // A change still in FSEvents' ~1 s delivery delay at the checkpoint happened just before it.
            watcher.replayChanges(since: max(id, recorded ?? 0), from: savedAt.addingTimeInterval(-5))
        }
        if pausedAt == nil { await startCollectors() }
        let (store, clock, watcher) = (store, clock, watcher)
        timers = [
            // Every 5 min: a crash's gap may start up to 5 min early, which overstates rather than hides missed time.
            repeating(every: 300) {
                do {
                    try store.setState(Key.lastAliveAt, String(clock.now().milliseconds))
                    try Self.saveCheckpoint(watcher.checkpoint, at: clock.now(), in: store)
                } catch { log("heartbeat failed: \(error)") }
            },
            repeating(every: 86400, now: true) {
                let cutoff = clock.now().addingTimeInterval(-Double(Self.retentionDays) * 86400)
                do { try store.purge(before: cutoff, keepingAtMost: Self.maxRows) } catch { log("retention purge failed: \(error)") }
            },
            // pmset keeps about a week of log; a daily import keeps wake reasons for the full retention period.
            // Investigations import first anyway, so their answers are current.
            repeating(every: 86400, now: true) { Task { _ = await self.importPowerLog() } },
        ]
    }

    func shutdown() async {
        // Read while the stream still runs; stopping it clears the checkpoint.
        let checkpoint = watcher.checkpoint
        for collector in collectors { await collector.stop() }
        timers.forEach { $0.cancel() }
        record("recorder_stopped")
        let (ingestor, store, clock) = (ingestor, store, clock)
        writer.sync {
            do {
                try ingestor.flush()
                try store.setState(Key.lastAliveAt, String(clock.now().milliseconds))
                try Self.saveCheckpoint(checkpoint, at: clock.now(), in: store)
                try store.setState(Key.cleanStop, "1")
            } catch {
                log("clean stop not recorded; the next start will report an interruption: \(error)")
            }
        }
    }

    func handle(_ request: Request) async -> Response {
        do {
            if request.client == .mcp {
                if let refusal = request.mcpRefusal(accessAllowed: try mcpAccess()) { return Response(error: refusal) }
                // An audit trail of what agents read, without the arguments.
                logger.notice("mcp \(request.method.rawValue, privacy: .public)")
            }
            switch request.method {
            case .status:
                flushNow()
                return Response(status: try await status())
            case .events:
                guard let query = request.query, query.from < query.to, query.cursor == nil || query.parsedCursor != nil else {
                    return .failure(.badRequest, "'events' needs a query with from < to and, if given, a cursor from a previous page.")
                }
                flushNow()
                return Response(page: try store.page(query))
            case .event:
                guard let id = request.eventID else { return .failure(.badRequest, "'event' needs an eventID.") }
                flushNow()
                guard let event = try store.event(id: id) else {
                    return .failure(.notFound, "No event \(id). It may be older than the \(Self.retentionDays)-day retention.")
                }
                return Response(event: event)
            case .pause:
                try await pause()
                return Response(status: try await status())
            case .resume:
                try await resume()
                return Response(status: try await status())
            case .investigateWake:
                guard let window = request.window, window.duration > 0, window.duration <= WakeInvestigator.maxWindow else {
                    return .failure(.badRequest, "'investigate_wake' needs a window longer than 0 and at most \(Int(WakeInvestigator.maxWindow / 3600)) hours.")
                }
                flushNow()
                let powerLogError = await importPowerLog()
                let events = try allEvents(from: window.start.addingTimeInterval(-WakeInvestigator.lookback),
                                           to: window.end.addingTimeInterval(WakeInvestigator.followUp), kinds: [.diagnostic, .wake, .appLaunch])
                let coverage = Coverage(recordingSince: try recordingSince(),
                                        powerLogSince: try store.state(Key.powerLogSince).flatMap(Int64.init).map(Date.init(milliseconds:)),
                                        powerLogThrough: try store.state(Key.powerLogThrough).flatMap(Int64.init).map(Date.init(milliseconds:)),
                                        powerLogError: powerLogError)
                return Response(investigation: WakeInvestigator.investigate(from: window.start, to: window.end, events: events, coverage: coverage))
            case .resources:
                let window = try window(request, max: ResourceAnalyzer.maxWindow)
                flushNow()
                var summary = ResourceAnalyzer.summarize(from: window.start, to: window.end,
                                                         events: try allEvents(from: window.start, to: window.end, kinds: [.resourceSample]),
                                                         points: request.points ?? 60, top: request.top ?? 10, recordingSince: try recordingSince())
                // An empty window after recording began gets only the "may have been paused" limit; with the switch off, say why instead.
                if let off = systemOffAt, off < window.end, summary.sampleCount == 0 {
                    summary.limits = [Limit(statement: "Record System Activity has been off since \(GhostTraceJSON.string(from: off)), so CPU, GPU, network, disk and battery aren't recorded. Memory samples are still stored when memory changes, and at least every \(Int(ResourceSampler.defaultHeartbeat / 60)) min.", evidence: [])]
                }
                return Response(resources: summary)
            case .live:
                guard systemOffAt == nil else {
                    return .failure(.badRequest, "System recording is turned off. Turn it on with: ghosttrace config --system on")
                }
                return Response(live: sampler.read())
            case .investigateMemory:
                let window = try window(request, max: MemoryInvestigator.maxWindow)
                flushNow()
                return Response(memoryInvestigation: MemoryInvestigator.investigate(
                    from: window.start, to: window.end,
                    events: try allEvents(from: window.start, to: window.end, kinds: [.resourceSample, .appLaunch]), recordingSince: try recordingSince()))
            case .investigateFileChange:
                let window = try window(request, max: FileChangeInvestigator.maxWindow)
                guard let path = request.path, path.hasPrefix("/") else { return .failure(.badRequest, "'investigate_file_change' needs an absolute path.") }
                flushNow()
                // Earlier launches are fetched too, for the ones just before the first change.
                let events = try allEvents(from: window.start.addingTimeInterval(-FileChangeInvestigator.launchLookback), to: window.end,
                                           kinds: [.fileChange, .appLaunch])
                return Response(fileChangeInvestigation: FileChangeInvestigator.investigate(
                    path: FileWatcher.canonicalPath(path), from: window.start, to: window.end, events: events, watches: try watches()))
            case .investigateBattery:
                let window = try window(request, max: BatteryInvestigator.maxWindow)
                flushNow()
                let powerLogError = await importPowerLog()
                var investigation = BatteryInvestigator.investigate(from: window.start, to: window.end,
                                                                    events: try allEvents(from: window.start, to: window.end, kinds: [.resourceSample, .sleep, .wake, .diagnostic, .appLaunch]),
                                                                    recordingSince: try recordingSince())
                if let powerLogError { investigation.limits.append(Self.powerLogLimit(powerLogError)) }
                investigation.limits += systemOffLimit(window)
                return Response(batteryInvestigation: investigation)
            case .investigateNetwork:
                let window = try window(request, max: NetworkInvestigator.maxWindow)
                flushNow()
                let powerLogError = await importPowerLog()
                // A dark wake can start before the spike it overlaps.
                var investigation = NetworkInvestigator.investigate(from: window.start, to: window.end,
                                                                    events: try allEvents(from: window.start.addingTimeInterval(-NetworkInvestigator.maxDarkWake), to: window.end, kinds: [.resourceSample, .diagnostic, .sleep, .wake]),
                                                                    recordingSince: try recordingSince())
                if let powerLogError { investigation.limits.append(Self.powerLogLimit(powerLogError)) }
                investigation.limits += systemOffLimit(window)
                return Response(networkInvestigation: investigation)
            case .investigateDisk:
                let window = try window(request, max: DiskInvestigator.maxWindow)
                flushNow()
                var investigation = DiskInvestigator.investigate(
                    from: window.start, to: window.end, events: try allEvents(from: window.start, to: window.end, kinds: [.resourceSample, .fileChange]),
                    watches: try watches(), recordingSince: try recordingSince())
                investigation.limits += systemOffLimit(window)
                return Response(diskInvestigation: investigation)
            case .watchAdd:
                try addWatch(request.path)
                return Response(status: try await status())
            case .watchRemove:
                try removeWatch(request.path)
                return Response(status: try await status())
            case .configure:
                guard request.sampleInterval != nil || request.mcpAccess != nil || request.systemMonitor != nil else {
                    return .failure(.badRequest, "'configure' needs a sampleInterval, mcpAccess or systemMonitor.")
                }
                if let interval = request.sampleInterval {
                    guard ResourceSampler.intervalRange.contains(interval) else {
                        return .failure(.badRequest, "'configure' needs a sampleInterval of \(Int(ResourceSampler.intervalRange.lowerBound)) to \(Int(ResourceSampler.intervalRange.upperBound)) seconds.")
                    }
                    try store.setState(Key.sampleInterval, String(interval))
                    sampler.setInterval(interval)
                    record("sampling_configured", ["interval_seconds": String(Int(interval))])
                }
                if let allowed = request.mcpAccess {
                    try store.setState(Key.mcpAccess, allowed ? "1" : "0")
                    record(allowed ? "mcp_access_allowed" : "mcp_access_denied")
                }
                if let on = request.systemMonitor { try setSystemMonitor(on) }
                return Response(status: try await status())
            }
        } catch let error as ServiceError {
            return Response(error: error)
        } catch {
            return .failure(.internalError, "\(error)")
        }
    }

    /// Imports powerd's sleep/wake lines. Returns why the log wasn't read, or nil. Skipped while paused: pausing stops all recording.
    private func importPowerLog() async -> String? {
        guard pausedAt == nil else { return "recording is paused" }
        let readAt = Date(roundingToMilliseconds: clock.now())
        do {
            let previousThrough = try store.state(Key.powerLogThrough).flatMap(Int64.init).map(Date.init(milliseconds:))
            // Lines up to an hour before the last read are already stored (ids make overlap harmless).
            let snapshot = try await Task.detached { [clock] in
                PowerLog.parse(try PowerLog.read(), since: previousThrough?.addingTimeInterval(-3600), clock: clock)
            }.value
            defer { releaseFreeMemory() }
            guard pausedAt == nil else { return "recording is paused" }
            if let previousThrough, let first = snapshot.coversFrom, first > previousThrough {
                try store.insert([.gap(from: previousThrough, to: first, reason: .powerLogHole,
                                       provenance: "The power log's oldest entry is newer than the previous import, so the entries in between rolled off before GhostTrace read them.",
                                       clock: clock)])
            }
            let added = try store.insert(snapshot.events)
            if let first = snapshot.coversFrom, try store.state(Key.powerLogSince).flatMap(Int64.init).map({ first.milliseconds < $0 }) ?? true {
                try store.setState(Key.powerLogSince, String(first.milliseconds))
            }
            try store.setState(Key.powerLogThrough, String(readAt.milliseconds))
            powerLog = CapabilityStatus(id: powerLog.id, name: powerLog.name, state: .observed,
                                        detail: "Read at \(GhostTraceJSON.string(from: readAt)): \(snapshot.events.count) sleep, wake and wake-request entries since the previous read, \(added) new.")
            return nil
        } catch {
            // A failed read proves nothing about availability (ADR 0001), so it is unverified, not missing.
            powerLog = CapabilityStatus(id: powerLog.id, name: powerLog.name, state: .unverified, detail: "Last read failed: \(error)")
            return "\(error)"
        }
    }

    /// The off span still running has no gap event yet (it's stored when turned on), so it's stated here.
    private func systemOffLimit(_ window: DateInterval) -> [Limit] {
        guard let off = systemOffAt, off < window.end else { return [] }
        return [Limit(statement: "System recording has been turned off since \(GhostTraceJSON.string(from: off)), so nothing was recorded since then.", evidence: [])]
    }

    private static func powerLogLimit(_ error: String) -> Limit {
        Limit(statement: "macOS's power log wasn't read (\(error)), so dark wakes since the last read may be missing.", evidence: [])
    }

    /// Every event in the range (of `kinds`, plus gaps), in order. Refuses rather than investigating a silently truncated set.
    private func allEvents(from: Date, to: Date, kinds: [EventKind?] = [nil]) throws -> [Event] {
        var events: [UUID: Event] = [:]
        for kind in kinds {
            var query = EventQuery(from: from, to: to, kind: kind, limit: EventQuery.maxLimit)
            repeat {
                let page = try store.page(query)
                for event in page.events { events[event.id] = event }
                query.cursor = page.nextCursor
                guard events.count <= 100_000 else { throw ServiceError(.badRequest, "Too many events in this window to investigate. Use a shorter window.") }
            } while query.cursor != nil
        }
        return events.values.sorted { ($0.occurredAt, $0.recordedAt) < ($1.occurredAt, $1.recordedAt) }
    }

    private func window(_ request: Request, max: TimeInterval) throws -> DateInterval {
        guard let window = request.window, window.duration > 0, window.duration <= max else {
            throw ServiceError(.badRequest, "'\(request.method.rawValue)' needs a window longer than 0 and at most \(Int(max / 3600)) hours.")
        }
        return window
    }

    /// Recorder markers and gaps exist only from the first run on, so the earliest one bounds what collectors could have seen.
    private func mcpAccess() throws -> Bool { try store.state(Key.mcpAccess) == "1" }

    private func recordingSince() throws -> Date? {
        try store.page(EventQuery(from: .distantPast, to: .distantFuture, kind: .collectorStatus, limit: 1)).events.first?.occurredAt
    }

    private func watches() throws -> [WatchedPath] {
        try store.state(Key.watchedPaths).map { try GhostTraceJSON.decoder().decode([WatchedPath].self, from: Data($0.utf8)) } ?? []
    }

    private func saveWatches(_ watches: [WatchedPath]) throws {
        try store.setState(Key.watchedPaths, String(decoding: try GhostTraceJSON.encoder().encode(watches), as: UTF8.self))
        watcher.setPaths(Self.streamPaths(watches))
    }

    /// A watch inside another stays listed (it keeps its own `since`), but only the outer path goes to FSEvents.
    static func streamPaths(_ watches: [WatchedPath]) -> [String] {
        watches.map(\.path).filter { path in !watches.contains { $0.path != path && $0.covers(path) } }
    }

    private func addWatch(_ raw: String?) throws {
        guard let raw, raw.hasPrefix("/") else { throw ServiceError(.badRequest, "'watch_add' needs an absolute path.") }
        let path = FileWatcher.canonicalPath(raw)
        guard FileManager.default.fileExists(atPath: path) else { throw ServiceError(.notFound, "Nothing exists at \(path).") }
        guard path != "/" else { throw ServiceError(.badRequest, "Watching the whole disk would record every change on the Mac. Choose a narrower folder.") }
        var watches = try watches()
        guard !watches.contains(where: { $0.path == path }) else { return }
        guard watches.count < FileWatcher.maxPaths else {
            throw ServiceError(.badRequest, "At most \(FileWatcher.maxPaths) paths can be watched. Remove one first.")
        }
        watches.append(WatchedPath(path: path, since: clock.now()))
        try saveWatches(watches)
        record("watch_added", ["path": path])
    }

    private func removeWatch(_ raw: String?) throws {
        guard let raw, raw.hasPrefix("/") else { throw ServiceError(.badRequest, "'watch_remove' needs an absolute path.") }
        let path = FileWatcher.canonicalPath(raw)
        var watches = try watches()
        guard watches.contains(where: { $0.path == path }) else {
            throw ServiceError(.notFound, "\(path) isn't watched. Watched: \(watches.isEmpty ? "nothing" : watches.map(\.path).joined(separator: ", ")).")
        }
        watches.removeAll { $0.path == path }
        try saveWatches(watches)
        record("watch_removed", ["path": path])
    }

    private func status() async throws -> RecorderStatus {
        var capabilities = fixedCapabilities
        capabilities.append(powerLog)
        for collector in collectors {
            if let failure = failedCollectors[collector.id] {
                capabilities.append(CapabilityStatus(id: collector.id, name: collector.id, state: .missing, detail: "Failed to start: \(failure)"))
            } else {
                capabilities.append(await collector.status())
            }
        }
        capabilities += sampler.systemCapabilities()
        let summary = try store.summary()
        // The WAL holds recent writes until a checkpoint folds them into the main file, so both count.
        let bytes = ["", "-wal"].compactMap { (try? FileManager.default.attributesOfItem(atPath: store.path + $0)[.size] as? NSNumber)??.int64Value }
        return RecorderStatus(state: pausedAt != nil ? .paused : failedCollectors.isEmpty ? .running : .permissionLimited,
                              pid: getpid(), startedAt: startedAt, pausedAt: pausedAt, databasePath: store.path,
                              eventCount: summary.count, retainedSince: summary.oldest, retentionDays: Self.retentionDays,
                              droppedEvents: ingestor.droppedCount, capabilities: capabilities,
                              sampleInterval: sampler.interval, watchedPaths: try watches(),
                              databaseBytes: bytes.reduce(0, +), schemaVersion: EventStore.schemaVersion, mcpAccess: try mcpAccess(),
                              systemMonitor: systemOffAt == nil)
    }

    /// Runs on the actor after each sampler check; never while paused or with the system monitor off (active alerts are kept as they are).
    private func checkAlerts(_ reading: SystemReading, _ check: ActivityTracker.CheckResult, latest: (id: UUID, sample: ResourceSample)?) {
        guard pausedAt == nil, systemOffAt == nil else { return }
        if let edge = check.networkBusyEdge { snapshotNetwork(edge) }
        let transitions = monitor.check(reading, cpuBusy: check.cpuBusy, latest: latest?.sample, interval: sampler.interval)
        guard !transitions.isEmpty else { return }
        // Saved only here (not every check): the readings are rebuilt after a restart, the incident state must not be lost.
        do {
            try store.setState(Key.alertState, String(decoding: try GhostTraceJSON.encoder().encode(monitor.state), as: UTF8.self))
        } catch { log("alert state not saved; a restart may repeat an alert: \(error)") }
        for transition in transitions {
            ingestor.submit(AlertMonitor.event(transition, evidence: latest.map { [$0.id] } ?? [], clock: clock))
        }
        notify_post(GhostTracePaths.alertNotification)
    }

    /// Only on a busy edge, gated by `NetTop.Gate`. The run takes seconds, so it goes to its own queue, not the sampler's or the actor's.
    private func snapshotNetwork(_ edge: ActivityTracker.Edge) {
        guard netTopGate.allow(edge, at: clock.now()) else { return }
        let (ingestor, clock) = (ingestor, clock)
        DispatchQueue.global(qos: .utility).async {
            ingestor.submit(NetTop.event(NetTop.snapshot(edge: edge), edge: edge, clock: clock))
        }
    }

    private func startCollectors() async {
        let (ingestor, feed) = (ingestor, feed)
        for collector in collectors {
            do {
                try await collector.start { [weak self] event in
                    ingestor.submit(event)
                    guard event.kind == .resourceSample else { return }
                    let pending = feed.withLock { state in
                        defer { state.pending = nil }
                        if let sample = state.pending?.sample { state.last = (event.id, sample) }
                        return state.pending
                    }
                    if let self, let pending { Task { await self.checkAlerts(pending.reading, pending.check, latest: (event.id, pending.sample)) } }
                }
                failedCollectors[collector.id] = nil
            } catch {
                failedCollectors[collector.id] = "\(error)"
                record("collector_failed", ["collector": collector.id, "error": "\(error)"])
            }
        }
    }

    /// Persisted, so a restarted recorder stays paused until the user resumes it. Collectors are stopped, not just
    /// ignored, so a paused recorder does no sampling or watching at all.
    private func pause() async throws {
        guard pausedAt == nil else { return }
        record("paused")
        let now = Date(roundingToMilliseconds: clock.now())
        try store.setState(Key.pausedAt, String(now.milliseconds))
        ingestor.isPaused = true
        pausedAt = now
        for collector in collectors { await collector.stop() }
        // File changes made while paused aren't replayed later.
        try store.setState(Key.fseventsCheckpoint, nil)
    }

    private func resume() async throws {
        guard let since = pausedAt else { return }
        ingestor.isPaused = false
        ingestor.submit(.gap(from: since, to: clock.now(), reason: .paused, provenance: "Recording was paused by the user.", clock: clock))
        record("resumed")
        try store.setState(Key.pausedAt, nil)
        pausedAt = nil
        await startCollectors()
    }

    /// Persisted like a pause. Off stops only system readings, alerts and `nettop`; memory, wakes, launches and file changes go on.
    private func setSystemMonitor(_ on: Bool) throws {
        guard on == (systemOffAt != nil) else { return }
        let now = Date(roundingToMilliseconds: clock.now())
        // Persisted first: if this throws, a retry still finds the switch off and writes the gap once.
        try store.setState(Key.systemMonitor, on ? nil : String(now.milliseconds))
        if let since = systemOffAt {
            ingestor.submit(.gap(from: since, to: now, reason: .systemMonitorOff, provenance: "System recording was turned off by the user.", clock: clock), whilePaused: true)
        }
        systemOffAt = on ? nil : now
        sampler.systemMonitor = on
        record(on ? "system_monitor_on" : "system_monitor_off")
    }

    private static func saveCheckpoint(_ id: UInt64?, at: Date, in store: EventStore) throws {
        try store.setState(Key.fseventsCheckpoint, id.map { "\($0) \(at.milliseconds)" })
    }

    /// Recorder lifecycle markers are kept even while paused, and also go to the unified log.
    private func record(_ state: String, _ detail: [String: String] = [:]) {
        // An empty detail would still show as "<private>" in `ghosttrace logs`.
        if detail.isEmpty { logger.notice("\(state, privacy: .public)") } else { logger.notice("\(state, privacy: .public) \("\(detail)", privacy: .private)") }
        ingestor.submit(Event(kind: .collectorStatus, source: "recorder", payload: detail.merging(["state": state]) { _, new in new },
                              clock: clock), whilePaused: true)
    }

    /// Read-your-writes for queries: anything a collector has submitted is stored before the query runs.
    private func flushNow() {
        let ingestor = ingestor
        writer.sync { _ = try? ingestor.flush() }
    }

    /// Wall-clock timers, so a daily timer fires daily even on a Mac that sleeps most of the day.
    /// The leeway lets macOS batch the wake-ups with others.
    private func repeating(every seconds: Int, now: Bool = false, _ work: @escaping @Sendable () -> Void) -> any DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: writer)
        timer.schedule(wallDeadline: .now() + (now ? .seconds(0) : .seconds(seconds)), repeating: .seconds(seconds),
                       leeway: .seconds(max(1, seconds / 10)))
        timer.setEventHandler(handler: work)
        timer.resume()
        return timer
    }
}

/// Returns freed heap pages to macOS after large, short-lived allocations (imports, big queries), so the
/// recorder's footprint drops back instead of staying at its peak.
func releaseFreeMemory() {
    malloc_zone_pressure_relief(nil, 0)
}

/// Under launchd stderr goes nowhere, so problems go to the unified log: `ghosttrace logs`.
let logger = Logger(subsystem: GhostTracePaths.logSubsystem, category: "recorder")

func log(_ message: String, level: OSLogType = .error) {
    logger.log(level: level, "\(message, privacy: .public)")
    FileHandle.standardError.write(Data("RecorderAgent: \(message)\n".utf8))
}
