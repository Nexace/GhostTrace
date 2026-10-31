import CoreServices
@testable import Collectors
import Foundation
import RecorderCore
import Testing

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Event] = []
    var events: [Event] { lock.withLock { stored } }
    func add(_ event: Event) { lock.withLock { stored.append(event) } }
}

// MARK: Resource sampling (live)

@Test func aLiveSampleReadsSystemMemoryAndThisUsersProcesses() throws {
    // Heartbeat 0: every check is stored, so the second one has deltas.
    let sampler = ResourceSampler(interval: 5, heartbeat: 0)
    let first = try #require(try sampler.takeSample(at: Date()))
    #expect(first.memoryTotal > 0 && first.memoryUsed > 0 && first.memoryUsed <= first.memoryTotal)
    #expect(first.readable > 0 && first.heartbeat == 0)
    #expect(first.processes.count >= ResourceSampler.topByMemory)
    #expect(first.processes.allSatisfy { $0.cpu == nil && $0.footprintChange == nil && !$0.name.isEmpty && $0.startedAt != nil })
    #expect(first.processes.map(\.footprint) == first.processes.map(\.footprint).sorted(by: >))

    usleep(200_000)
    let second = try #require(try sampler.takeSample(at: Date()))
    #expect(second.processes.contains { $0.footprintChange != nil && $0.cpu != nil })
    // The event carries the sample intact.
    let event = second.event(clock: .live)
    #expect(event.kind == .resourceSample && event.quality == .sampled)
    #expect(ResourceSample(event) == second)
}

@Test func aCheckWithNothingChangedStoresNothingUntilTheHeartbeat() throws {
    // A reading that never changes, so only memory and the heartbeat can trigger a store.
    let sampler = ResourceSampler(interval: 5, heartbeat: 600, reader: SystemReader { SystemReading(at: Date(timeIntervalSince1970: 1_800_000_000), cpu: CPUTicks(busy: 1, total: 10)) })
    let start = Date()
    #expect(try sampler.takeSample(at: start) != nil)
    // A fraction of a second later nothing has moved by 512 MB, so nothing is stored.
    #expect(try sampler.takeSample(at: start.addingTimeInterval(1)) == nil)
    #expect(try sampler.takeSample(at: start.addingTimeInterval(600)) != nil)
    sampler.systemMonitor = false
    #expect(try sampler.takeSample(at: start.addingTimeInterval(601)) != nil, "turning the system monitor off or on stores a sample")
    #expect(try sampler.takeSample(at: start.addingTimeInterval(602)) == nil)
}

@Test func aStoredSampleCarriesTheSystemActivityAndEveryCheckReportsIt() throws {
    final class Checks: @unchecked Sendable {
        let lock = NSLock()
        var stored: [Bool] = []
    }
    let checks = Checks()
    let sampler = ResourceSampler(interval: 5, heartbeat: 600, reader: SystemReader {
        SystemReading(at: Date(), network: NetworkBytes(received: 5, sent: 1), freeSpace: 7)
    })
    sampler.onCheck = { _, _, sample in checks.lock.withLock { checks.stored.append(sample != nil) } }
    let start = Date()
    let first = try #require(try sampler.takeSample(at: start))
    // The first check has nothing to diff with, so its bytes are not measured rather than zero.
    #expect(first.system?.freeSpace == 7 && first.system?.networkIn == nil && first.system?.onBattery == nil)
    #expect(try sampler.takeSample(at: start.addingTimeInterval(1)) == nil)
    #expect(checks.lock.withLock { checks.stored } == [true, false])
    let rows = sampler.systemCapabilities()
    #expect(rows.map(\.id) == ["gpu-utilization", "battery", "idle-time", "process-network", "process-gpu", "ssd-health"])
    #expect(rows.first { $0.id == "gpu-utilization" }?.state == .missing && rows.first { $0.id == "battery" }?.detail == "This Mac has no battery.")
}

@Test func aSamplerWithTheSystemMonitorOffNeverReadsTheSystem() throws {
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var reads = 0
        var checks = 0
    }
    let calls = Calls()
    let sampler = ResourceSampler(interval: 5, heartbeat: 0, reader: SystemReader {
        calls.lock.withLock { calls.reads += 1 }
        return SystemReading(at: Date(), network: NetworkBytes(received: 5, sent: 1), freeSpace: 7)
    })
    sampler.onCheck = { _, _, _ in calls.lock.withLock { calls.checks += 1 } }
    sampler.systemMonitor = false
    let first = try #require(try sampler.takeSample(at: Date()))
    usleep(200_000)
    let second = try #require(try sampler.takeSample(at: Date()))
    #expect(calls.lock.withLock { (calls.reads, calls.checks) } == (0, 0))
    #expect(first.system == nil && second.system == nil)
    #expect(second.processes.contains { $0.cpu != nil }, "memory and CPU keep recording")
    #expect(second.processes.allSatisfy { $0.energy == nil && $0.diskRead == nil && $0.diskWritten == nil })
    #expect(sampler.systemCapabilities().filter { $0.detail == "Turned off in GhostTrace." }.map(\.id) == ["gpu-utilization", "battery", "idle-time", "process-network"])
    sampler.systemMonitor = true
    let third = try #require(try sampler.takeSample(at: Date()))
    #expect(third.system?.freeSpace == 7 && calls.lock.withLock { calls.reads } == 1)
}

@Test func aProcessThatStartedSinceTheLastSampleIsAveragedOverItsLife() throws {
    let me = getpid()
    let sampler = ResourceSampler(interval: 5, heartbeat: 0, reader: SystemReader { SystemReading(at: Date()) })
    let old = ResourceSampler.Key(pid: me, start: 1)
    sampler.usageReader = { ([old: (1, 0, 0, 0, 0)], 0) }
    _ = try #require(try sampler.takeSample(at: Date()))
    let born = mach_absolute_time()
    usleep(200_000)
    let fresh = ResourceSampler.Key(pid: me, start: born)
    // Started before the last sample but not read then (it was unreadable or missed): its figures stay unknown.
    let missed = ResourceSampler.Key(pid: me, start: 2)
    sampler.usageReader = { ([old: (1, 0, 0, 0, 0), fresh: (2, 100_000_000, 1_000_000_000, 7, 9), missed: (3, 100_000_000, 1, 1, 1)], 0) }
    let sample = try #require(try sampler.takeSample(at: Date()))
    let new = try #require(sample.processes.first { $0.footprint == 2 })
    // 0.1 s of CPU and 1 J over its life of about 0.2 s: about 50% and 5 W.
    #expect((1...51).contains(new.cpu ?? 0) && (0.1...5.1).contains(new.energy ?? 0))
    #expect(new.diskRead == 7 && new.diskWritten == 9 && new.footprintChange == nil)
    let skipped = try #require(sample.processes.first { $0.footprint == 3 })
    #expect(skipped.cpu == nil && skipped.energy == nil && skipped.diskWritten == nil)
}

@Test func aPauseStartsTheTotalsAfresh() throws {
    final class Bytes: @unchecked Sendable {
        let lock = NSLock()
        var received: UInt64 = 0
    }
    let bytes = Bytes()
    let sampler = ResourceSampler(interval: 5, heartbeat: 0, reader: SystemReader {
        SystemReading(at: Date(), network: NetworkBytes(received: bytes.lock.withLock { bytes.received }, sent: 0))
    })
    _ = try sampler.takeSample(at: Date())
    sampler.stop()
    sampler.queue.sync {}
    // Moved while paused: never read back.
    bytes.lock.withLock { bytes.received = 5 << 30 }
    let first = try #require(try sampler.takeSample(at: Date()))
    #expect(first.system?.networkIn == nil)
    bytes.lock.withLock { bytes.received += 1 << 20 }
    let second = try #require(try sampler.takeSample(at: Date().addingTimeInterval(30)))
    #expect(second.system?.networkIn == 1 << 20)
}

@Test func samplerStatusIsObservedOnlyAfterASample() async throws {
    let sampler = ResourceSampler(interval: 5)
    #expect(sampler.status().state == .unverified)
    let received = Received()
    try sampler.start { received.add($0) }
    defer { sampler.stop() }
    for _ in 0..<50 where received.events.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
    #expect(received.events.first?.kind == .resourceSample)
    #expect(sampler.status().state == .observed)
}

// MARK: FSEvents

@Test func fseventFlagsMapToChangeNames() {
    let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
    #expect(FileWatcher.describe(flags) == (["created", "modified"], "file"))
    #expect(FileWatcher.describe(FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)) == (["renamed"], "folder"))
}

@Test func pathsAreCanonicalEvenWhenMissing() {
    #expect(FileWatcher.canonicalPath("/var/tmp") == "/private/var/tmp")
    #expect(FileWatcher.canonicalPath("/var/tmp/no-such-dir-\(UUID())/x.txt").hasPrefix("/private/var/tmp/no-such-dir-"))
    #expect(FileWatcher.canonicalPath("/tmp/../tmp/a") == "/private/tmp/a")
}

@Test func aWatchedFolderReportsChangesButNotTheExcludedFolder() async throws {
    let dir = FileWatcher.canonicalPath(NSTemporaryDirectory() + "gt-watch-\(UUID().uuidString.prefix(8))")
    let excluded = dir + "/own-data"
    try FileManager.default.createDirectory(atPath: excluded, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let watcher = FileWatcher(excluding: excluded)
    watcher.setPaths([dir])
    let received = Received()
    watcher.start { received.add($0) }
    defer { watcher.stop() }
    #expect(watcher.status().state == .unverified)

    try Data("x".utf8).write(to: URL(fileURLWithPath: excluded + "/events.sqlite"))
    try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/note.txt"))
    for _ in 0..<50 where !received.events.contains(where: { $0.subject?.path == dir + "/note.txt" }) {
        try await Task.sleep(for: .milliseconds(100))
    }
    let event = try #require(received.events.first { $0.subject?.path == dir + "/note.txt" })
    #expect(event.kind == .fileChange && event.privacyClass == .sensitive)
    #expect(event.payload["changes"]?.contains("created") == true && event.payload["item"] == "file")
    #expect(event.payload["fsevent_id"].flatMap(UInt64.init) != nil)
    #expect(!received.events.contains { $0.subject?.path?.hasPrefix(excluded) == true })
    #expect(watcher.status().state == .observed)
}

@Test func anEmptyWatchListSaysHowToAddOne() {
    let watcher = FileWatcher(excluding: "/nonexistent")
    watcher.start { _ in }
    defer { watcher.stop() }
    #expect(watcher.status().detail.contains("ghosttrace watch add"))
}

@Test func changesMadeWhileStoppedAreReadBackFromTheCheckpoint() async throws {
    let dir = FileWatcher.canonicalPath(NSTemporaryDirectory() + "gt-replay-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(atPath: dir + "/own-data", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let before = FileWatcher(excluding: dir + "/own-data")
    before.setPaths([dir])
    #expect(before.checkpoint == nil)
    before.start { _ in }
    let checkpoint = try #require(before.checkpoint)
    let stoppedAt = Date()
    before.stop()
    #expect(before.checkpoint == nil)

    // Changed while nothing watches.
    try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/while-stopped.txt"))
    try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/own-data/events.sqlite"))
    try await Task.sleep(for: .seconds(2))

    let after = FileWatcher(excluding: dir + "/own-data")
    after.setPaths([dir])
    after.replayChanges(since: checkpoint, from: stoppedAt)
    let received = Received()
    after.start { received.add($0) }
    defer { after.stop() }
    for _ in 0..<50 where !received.events.contains(where: { $0.subject?.path == dir + "/while-stopped.txt" }) {
        try await Task.sleep(for: .milliseconds(100))
    }
    let event = try #require(received.events.first { $0.subject?.path == dir + "/while-stopped.txt" })
    #expect(event.payload["replayed"] == "true" && event.quality == .inferred && event.payload["changes"]?.contains("created") == true)
    #expect(event.occurredAt == Date(roundingToMilliseconds: stoppedAt) && event.endedAt != nil)
    #expect(!received.events.contains { $0.subject?.path?.hasPrefix(dir + "/own-data") == true })
    // Once the history is done, the checkpoint moves past it.
    #expect(try #require(after.checkpoint) > checkpoint)
}
