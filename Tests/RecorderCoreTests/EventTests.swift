import Foundation
import RecorderCore
import Testing

let fixedClock = RecorderClock(now: { Date(milliseconds: 1_793_050_200_123) }, monotonicNanos: { 42 }, bootSessionID: "boot-A")

private func marker(_ name: String = "x") -> Event {
    Event(kind: .collectorStatus, source: "test", payload: ["state": name], clock: fixedClock)
}

/// Records written batches; can be told to fail the next write.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [Event] = []
    var failNext = false

    var events: [Event] { lock.withLock { written } }

    func write(_ batch: [Event]) throws {
        try lock.withLock {
            if failNext {
                failNext = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
            written += batch
        }
    }
}

@Test func jsonRoundTripKeepsMillisecondsAndWritesUTC() throws {
    let event = Event(kind: .appLaunch, source: "test",
                      subject: Subject(pid: 7, bundleID: "com.example.app", startedAt: Date(timeIntervalSince1970: 1_793_050_000.0004)),
                      payload: ["k": "v"], clock: fixedClock)
    let data = try GhostTraceJSON.encoder().encode(event)
    #expect(String(decoding: data, as: UTF8.self).contains(#""occurredAt":"2026-10-26T21:30:00.123Z""#))
    #expect(try GhostTraceJSON.decoder().decode(Event.self, from: data) == event)
}

@Test func firstRunHasNoGap() {
    #expect(Event.startupGap(lastAlive: nil, cleanStop: false, lastBootSessionID: nil, clock: fixedClock) == nil)
}

@Test(arguments: [(true, GapReason.recorderStopped), (false, .recorderInterrupted)])
func previousRunLeavesAGapLabelledByHowItEnded(cleanStop: Bool, reason: GapReason) throws {
    let lastAlive = Date(milliseconds: 1_793_040_000_000)
    let gap = try #require(Event.startupGap(lastAlive: lastAlive, cleanStop: cleanStop, lastBootSessionID: "boot-A", clock: fixedClock))
    #expect(gap.kind == .eventGap)
    #expect(gap.occurredAt == lastAlive)
    #expect(gap.endedAt == fixedClock.now())
    #expect(gap.payload["reason"] == reason.rawValue)
    #expect(gap.payload["boot_changed"] == "false")
}

@Test func rebootBetweenRunsIsMarkedOnTheGap() {
    let lastAlive = Date(milliseconds: 1_793_040_000_000)
    #expect(Event.startupGap(lastAlive: lastAlive, cleanStop: true, lastBootSessionID: "boot-Z", clock: fixedClock)?.payload["boot_changed"] == "true")
    #expect(Event.startupGap(lastAlive: lastAlive, cleanStop: true, lastBootSessionID: nil, clock: fixedClock)?.payload["boot_changed"] == "unknown")
}

@Test func overflowDropsEventsAndRecordsAGapWithTheCount() throws {
    let sink = Sink()
    let ingestor = Ingestor(capacity: 2, clock: fixedClock) { try sink.write($0) }
    for _ in 0..<5 { ingestor.submit(marker()) }
    #expect(ingestor.droppedCount == 3)
    try ingestor.flush()
    let gap = try #require(sink.events.last)
    #expect(sink.events.count == 3)
    #expect(gap.kind == .eventGap)
    #expect(gap.payload["reason"] == GapReason.queueOverflow.rawValue)
    #expect(gap.payload["dropped_count"] == "3")
}

@Test func failedWriteKeepsEventsForTheNextFlush() throws {
    let sink = Sink()
    let ingestor = Ingestor(clock: fixedClock) { try sink.write($0) }
    let event = marker()
    ingestor.submit(event)
    sink.failNext = true
    #expect(throws: CocoaError.self) { try ingestor.flush() }
    try ingestor.flush()
    #expect(sink.events.map(\.id) == [event.id])
}

@Test func pausedIngestorDiscardsCollectorEventsButKeepsRecorderMarkers() throws {
    let sink = Sink()
    let ingestor = Ingestor(clock: fixedClock) { try sink.write($0) }
    ingestor.isPaused = true
    ingestor.submit(marker("collector"))
    let kept = marker("paused")
    ingestor.submit(kept, whilePaused: true)
    try ingestor.flush()
    #expect(sink.events.map(\.id) == [kept.id])
    #expect(ingestor.droppedCount == 0)
}

// MARK: Resource samples and export redaction

@Test func aResourceSampleRoundTripsThroughAnEvent() throws {
    let clock = RecorderClock(now: { Date(milliseconds: 1_793_050_200_123) })
    let sample = ResourceSample(interval: 30, memoryTotal: 16 << 30, memoryUsed: 12 << 30, compressed: 5 << 30, swapUsed: 0, pressure: .warn,
                                processes: [ProcessSample(pid: 42, name: "Xcode",
                                                          startedAt: Date(milliseconds: 1_793_000_000_000), footprint: 3 << 30, footprintChange: -5, cpu: 12.5)],
                                readable: 560, unreadable: 220, tookMilliseconds: 7)
    let event = sample.event(clock: clock)
    #expect(event.payload["memory_used"] == "12.0 GB" && event.payload["pressure"] == "warn")
    let stored = try GhostTraceJSON.decoder().decode(Event.self, from: GhostTraceJSON.encoder().encode(event))
    #expect(ResourceSample(stored) == sample)
    #expect(ResourceSample(Event(kind: .wake, source: "x", clock: clock)) == nil)
    #expect(ResourceSample.bytes(350 << 20) == "350 MB" && ResourceSample.bytes(Int64(-1536) << 20) == "-1.5 GB")
    // Disk and traffic in Finder's decimal units: 340.9 GB free must not read as 317.5 GB.
    #expect(ResourceSample.fileBytes(UInt64(340_918_626_640)) == "340.9 GB" && ResourceSample.fileBytes(52_428_800) == "52 MB" && ResourceSample.fileBytes(-1_500_000_000) == "-1.5 GB")
    #expect(MemoryPressure.critical > .warn && MemoryPressure.warn > .normal)
}

@Test func aPrePhase6SampleStillDecodes() throws {
    let json = """
    {"interval":30,"memoryTotal":17179869184,"memoryUsed":8589934592,"compressed":0,"swapUsed":0,"pressure":"normal",\
    "processes":[{"pid":1,"name":"launchd","footprint":1000}],"readable":10,"unreadable":2,"tookMilliseconds":3}
    """
    let sample = try GhostTraceJSON.decoder().decode(ResourceSample.self, from: Data(json.utf8))
    #expect(sample.system == nil && sample.processes[0].energy == nil && sample.processes[0].diskRead == nil && sample.processes[0].diskWritten == nil)
}

@Test func redactionHashesSensitivePathsConsistently() {
    let clock = RecorderClock(now: { Date(milliseconds: 1_793_050_200_123) })
    let file = Event(kind: .fileChange, source: "file-watch/FSEvents", subject: Subject(path: "/Users/me/secret.txt"), privacyClass: .sensitive, clock: clock)
    let app = Event(kind: .appLaunch, source: "app", subject: Subject(name: "Mail", path: "/System/Applications/Mail.app"), clock: clock)
    let marker = Event(kind: .collectorStatus, source: "recorder", payload: ["state": "watch_added", "path": "/Users/me/secret.txt"], clock: clock)
    let redacted = [file, app, marker].map { $0.redacted() }
    #expect(redacted[0].subject?.path?.hasPrefix("redacted-") == true)
    #expect(redacted[0].subject?.path == redacted[2].payload["path"])
    #expect(redacted[1] == app)
    #expect(redacted[2].payload["state"] == "watch_added")
}

@Test func theIngestorAsksForOneFlushPerBatch() throws {
    final class Calls: @unchecked Sendable { var count = 0 }
    let clock = RecorderClock(now: { Date(milliseconds: 1_793_050_200_123) })
    let calls = Calls()
    let ingestor = Ingestor(clock: clock, write: { _ in }, whenBuffered: { _ in calls.count += 1 })
    ingestor.submit(Event(kind: .wake, source: "t", clock: clock))
    ingestor.submit(Event(kind: .sleep, source: "t", clock: clock))
    #expect(calls.count == 1)
    #expect(try ingestor.flush() == 2)
    // Nothing buffered: no new request. The next event asks again.
    #expect(calls.count == 1)
    ingestor.submit(Event(kind: .wake, source: "t", clock: clock))
    #expect(calls.count == 2)
    ingestor.isPaused = true
    _ = try ingestor.flush()
    ingestor.submit(Event(kind: .wake, source: "t", clock: clock))
    #expect(calls.count == 2)
}
