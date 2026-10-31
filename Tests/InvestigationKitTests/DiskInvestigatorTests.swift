import Foundation
import InvestigationKit
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_100_000_000) })
private let start = Date(milliseconds: 1_793_000_000_000)
private let mb: UInt64 = 1 << 20
private let gb: UInt64 = 1 << 30

private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private func sample(_ seconds: TimeInterval, free: UInt64, written: UInt64 = 0, read: UInt64 = 0, peak: UInt64 = 0, _ processes: [ProcessSample] = []) -> Event {
    var sample = ResourceSample(interval: 30, heartbeat: nil, memoryTotal: 16 << 30, memoryUsed: 8 << 30, compressed: 0, swapUsed: 0, pressure: .normal,
                                processes: processes, readable: 500, unreadable: 200, tookMilliseconds: 7)
    sample.system = SystemActivity(diskRead: read, diskWritten: written, diskPeakRate: peak, freeSpace: free)
    return sample.event(at: at(seconds), clock: clock)
}

private func proc(_ name: String, pid: Int32, written: UInt64) -> ProcessSample {
    ProcessSample(pid: pid, name: name, footprint: 100 << 20, diskWritten: written)
}

private func change(_ path: String, _ seconds: TimeInterval) -> Event {
    Event(kind: .fileChange, source: "fsevents", occurredAt: at(seconds), subject: Subject(path: path), payload: ["path": path, "changes": "created"],
          privacyClass: .sensitive, clock: clock)
}

private let watches = [WatchedPath(path: "/Users/me/Downloads", since: at(-86400))]

private func investigate(_ events: [Event]) -> DiskInvestigation {
    DiskInvestigator.investigate(from: at(-60), to: at(120), events: events, watches: watches, recordingSince: at(-3600))
}

@Test func aFreeSpaceDropWithAWriterIsAttributed() throws {
    // Free space falls 5 GB; the system wrote 6 GB, A 4 GB and B a little.
    let events = [sample(0, free: 100 * gb), sample(30, free: 95 * gb, written: 6 * gb, peak: 300 * mb, [proc("A", pid: 1, written: 4 * gb), proc("B", pid: 2, written: 60 * mb)])]
    let result = investigate(events)
    let incident = try #require(result.incidents.first)
    #expect(result.incidents.count == 1)
    #expect(incident.freeSpaceBefore == 100 * gb && incident.freeSpaceAfter == 95 * gb && incident.written == 6 * gb)
    #expect(incident.findings.first?.confidence == .observed)
    let likely = try #require(incident.findings.first { $0.confidence == .likely })
    #expect(likely.statement.contains("A") && likely.statement.contains("67%"))
    #expect(incident.summary.contains("A") && !incident.summary.contains("unknown"))
    #expect(result.limits.contains { $0.statement.contains("at least 67%") })
    #expect(result.evidence.map(\.id) == events.map(\.id))
}

@Test func aDropWithoutWritesBlamesNoProcess() throws {
    // 3 GB of free space gone with only 50 MB written: A wrote most of that, but writes can't explain the drop.
    let result = investigate([sample(0, free: 100 * gb), sample(30, free: 97 * gb, written: 50 * mb, peak: 2 * mb, [proc("A", pid: 1, written: 40 * mb)])])
    let incident = try #require(result.incidents.first)
    #expect(!incident.findings.contains { $0.confidence == .likely })
    #expect(incident.findings.contains { $0.confidence == .unknown && $0.statement.contains("52 MB") })
    #expect(incident.summary.contains("unknown"))
    #expect(result.limits.contains { $0.statement.contains("APFS snapshots") && $0.statement.contains("purgeable") })
}

@Test func watchedFolderChangesAreCorrelated() throws {
    let events = [sample(0, free: 100 * gb), sample(30, free: 98 * gb, written: 2 * gb, peak: 100 * mb),
                  change("/Users/me/Downloads/big.dmg", 20), change("/Users/me/Downloads/other.zip", 25), change("/Users/me/Downloads/late.txt", 100)]
    let incident = try #require(investigate(events).incidents.first)
    let correlated = try #require(incident.findings.first { $0.confidence == .correlated })
    #expect(correlated.statement.contains("2 file changes") && correlated.statement.contains("/Users/me/Downloads"))
    #expect(Set(correlated.evidence) == [events[2].id, events[3].id])
    // The finding names the watched folder, never the files in it.
    #expect(!correlated.statement.contains("big.dmg"))
}

@Test func writeBurstsAreObserved() throws {
    // No free-space drop, but one check wrote at 50 MB/s.
    let result = investigate([sample(0, free: 100 * gb), sample(30, free: 100 * gb, written: 900 * mb, peak: 50 * mb, [proc("dd", pid: 9, written: 800 * mb)]),
                              sample(60, free: 100 * gb, written: mb, peak: mb)])
    let incident = try #require(result.incidents.first)
    #expect(result.incidents.count == 1)
    #expect(incident.from == at(0) && incident.to == at(30) && incident.written == 900 * mb)
    #expect(incident.findings.first { $0.confidence == .observed }?.statement.contains("944 MB") == true)
    #expect(incident.findings.contains { $0.confidence == .likely && $0.statement.contains("dd") })
}

@Test func aCalmWindowHasNoIncidents() {
    let result = investigate([sample(0, free: 100 * gb), sample(30, free: 100 * gb - 512 * mb, written: 5 * mb, peak: mb)])
    #expect(result.incidents.isEmpty && result.evidence.isEmpty)
}

@Test func aBurstInTheWindowsFirstSampleHasNoStartingPoint() throws {
    // Its bytes began before the window, at a sample this window doesn't hold: no "before" free space and no made-up duration.
    let incident = try #require(investigate([sample(0, free: 100 * gb, written: 900 * mb, peak: 50 * mb), sample(30, free: 100 * gb)]).incidents.first)
    #expect(incident.freeSpaceBefore == nil && incident.from == at(0))
    #expect(incident.findings.allSatisfy { !$0.statement.contains("0 s") && Set($0.evidence).count == $0.evidence.count })
}

@Test func aReadHeavyBurstIsLeftOutWithALimit() {
    let result = investigate([sample(0, free: 100 * gb), sample(30, free: 100 * gb, written: 100 * mb, read: 900 * mb, peak: 50 * mb)])
    #expect(result.incidents.isEmpty)
    #expect(result.limits.contains { $0.statement == "1 read-heavy burst was left out: GhostTrace can't separate read and write rates." })
}

@Test func aFreeSpaceDropIsKeptEvenWhenReadsDominate() {
    let result = investigate([sample(0, free: 100 * gb), sample(30, free: 95 * gb, written: 100 * mb, read: 900 * mb, peak: 50 * mb)])
    #expect(result.incidents.count == 1)
    #expect(!result.limits.contains { $0.statement.contains("read-heavy") })
}

@Test func aProcessShareIsNeverOver100Percent() throws {
    // The process counted more than the system did (other volumes, deleted writes).
    let incident = try #require(investigate([sample(0, free: 100 * gb), sample(30, free: 100 * gb, written: 100 * mb, peak: 50 * mb, [proc("A", pid: 1, written: 300 * mb)])]).incidents.first)
    #expect(incident.findings.allSatisfy { !$0.statement.contains("300%") } && incident.findings.contains { $0.statement.contains("100%") })
}

@Test func aProcessWithExactlyHalfIsNotLikelyButJustOverIs() throws {
    let half = try #require(investigate([sample(0, free: 100 * gb), sample(30, free: 100 * gb, written: 200 * mb, peak: 50 * mb, [proc("A", pid: 1, written: 100 * mb)])]).incidents.first)
    #expect(!half.findings.contains { $0.confidence == .likely } && half.findings.contains { $0.confidence == .unknown })
    let over = try #require(investigate([sample(0, free: 100 * gb), sample(30, free: 100 * gb, written: 200 * mb, peak: 50 * mb, [proc("A", pid: 1, written: 100 * mb + 1)])]).incidents.first)
    #expect(over.findings.contains { $0.confidence == .likely })
}

@Test func nothingWrittenIsNeverLikely() throws {
    // A free-space drop with no system writes (reads can't make it read-heavy here) while a process claims writes.
    let incident = try #require(investigate([sample(0, free: 100 * gb), sample(30, free: 98 * gb, written: 0, peak: 50 * mb, [proc("A", pid: 1, written: 10 * mb)])]).incidents.first)
    #expect(!incident.findings.contains { $0.confidence == .likely })
}

@Test func readHeavyBurstsNeverTakeSlotsFromWriteBursts() {
    // 25 read bursts, then one write burst, each pair of samples 600 s apart so they are separate runs.
    var events: [Event] = []
    for i in 0..<26 {
        let t = Double(i) * 600
        events.append(sample(t, free: 100 * gb))
        events.append(sample(t + 30, free: 100 * gb, written: i == 25 ? 900 * mb : 10 * mb, read: i == 25 ? 0 : 900 * mb, peak: 50 * mb))
    }
    let result = DiskInvestigator.investigate(from: at(-60), to: at(26 * 600), events: events, watches: watches, recordingSince: at(-3600))
    #expect(result.incidents.count == 1 && result.incidents[0].written == 900 * mb)
    #expect(result.limits.contains { $0.statement == "25 read-heavy bursts were left out: GhostTrace can't separate read and write rates." })
}
