import Collectors
import Foundation
import InvestigationKit
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_100_000_000) })
private let start = Date(milliseconds: 1_793_000_000_000)
private let mb: UInt64 = 1 << 20

private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private func sample(_ seconds: TimeInterval, received: UInt64 = 0, sent: UInt64 = 0, peak: UInt64 = 0) -> Event {
    var sample = ResourceSample(interval: 30, heartbeat: nil, memoryTotal: 16 << 30, memoryUsed: 8 << 30, compressed: 0, swapUsed: 0, pressure: .normal,
                                processes: [], readable: 500, unreadable: 200, tookMilliseconds: 7)
    sample.system = SystemActivity(networkIn: received, networkOut: sent, networkPeakRate: peak)
    return sample.event(at: at(seconds), clock: clock)
}

private func snapshot(_ seconds: TimeInterval, _ edge: ActivityTracker.Edge, _ entries: [(String, Int32, UInt64)]) -> Event {
    NetTop.event(.success(entries.map { .init(name: $0.0, pid: $0.1, received: $0.2, sent: 0) }), edge: edge,
                 clock: RecorderClock(now: { at(seconds) }))
}

private func darkWake(_ seconds: TimeInterval) -> Event {
    Event(kind: .diagnostic, source: PowerLog.source, occurredAt: at(seconds), payload: ["entry": "dark_wake", "reason": "EC.DarkPME/ARPT"], quality: .imported, clock: clock)
}

private func sleep(_ seconds: TimeInterval) -> Event {
    Event(kind: .diagnostic, source: PowerLog.source, occurredAt: at(seconds), payload: ["entry": "sleep", "reason": "Maintenance Sleep"], quality: .imported, clock: clock)
}

/// Calm, two busy checks (peak over 10 MB/s, 420 MB in all), calm.
private let busy = [sample(0), sample(30, received: 300 * mb, sent: 20 * mb, peak: 30 * mb), sample(60, received: 100 * mb, sent: 0, peak: 12 * mb), sample(90)]

private func investigate(_ events: [Event]) -> NetworkInvestigation {
    NetworkInvestigator.investigate(from: at(-60), to: at(120), events: events, recordingSince: at(-3600))
}

@Test func aCalmWindowHasNoSpikes() {
    let result = investigate([sample(0, received: 5 * mb, peak: mb), sample(30, received: 9 * mb, peak: 2 * mb)])
    #expect(result.spikes.isEmpty && result.evidence.isEmpty)
}

@Test func busyChecksMergeIntoOneObservedSpike() throws {
    let spike = try #require(investigate(busy).spikes.first)
    #expect(investigate(busy).spikes.count == 1)
    #expect(spike.from == at(0) && spike.to == at(60))
    #expect(spike.received == 400 * mb && spike.sent == 20 * mb && spike.peakRate == 30 * mb)
    #expect(spike.findings.first?.confidence == .observed)
}

@Test func bytesAloneMakeASpikeWhenNoSingleCheckWasFast() {
    // 150 MB between two samples at under 10 MB/s peak: still a spike.
    #expect(investigate([sample(0), sample(30, received: 150 * mb, peak: 5 * mb)]).spikes.count == 1)
}

@Test func aSpikeWithBothSnapshotsNamesTheLikelyProcess() throws {
    let started = snapshot(30.2, .started, [("A", 1, 10 * mb), ("B", 2, 100 * mb)])
    let ended = snapshot(60.2, .ended, [("A", 1, 15 * mb), ("B", 2, 400 * mb)])
    let result = investigate(busy + [started, ended])
    let spike = try #require(result.spikes.first)
    let likely = try #require(spike.findings.first { $0.confidence == .likely })
    #expect(likely.statement.contains("B") && spike.summary.contains("B") && !spike.summary.contains("unknown"))
    #expect(Set(likely.evidence) == [started.id, ended.id])
    #expect(result.evidence.contains { $0.id == started.id } && result.evidence.contains { $0.id == ended.id })
}

@Test func noProcessIsNamedWhenGrowthIsSpreadEvenly() throws {
    let started = snapshot(30.2, .started, [("A", 1, 0), ("B", 2, 0), ("C", 3, 0)])
    let ended = snapshot(60.2, .ended, [("A", 1, 100 * mb), ("B", 2, 110 * mb), ("C", 3, 90 * mb)])
    let spike = try #require(investigate(busy + [started, ended]).spikes.first)
    #expect(!spike.findings.contains { $0.confidence == .likely } && spike.findings.contains { $0.confidence == .unknown })
}

@Test func noProcessIsNamedWhenItsGrowthCannotExplainTheTraffic() throws {
    // 420 MB moved, but the only process that grew did so by 2 MB: nettop missed the traffic.
    let started = snapshot(30.2, .started, [("A", 1, 10 * mb)])
    let ended = snapshot(60.2, .ended, [("A", 1, 12 * mb)])
    let spike = try #require(investigate(busy + [started, ended]).spikes.first)
    #expect(!spike.findings.contains { $0.confidence == .likely } && spike.summary.contains("unknown"))
}

@Test func twoEqualContributorsAreATieAndNameNoOne() throws {
    let started = snapshot(30.2, .started, [("A", 1, 0), ("B", 2, 0)])
    let ended = snapshot(60.2, .ended, [("A", 1, 150 * mb), ("B", 2, 150 * mb)])
    let spike = try #require(investigate(busy + [started, ended]).spikes.first)
    #expect(!spike.findings.contains { $0.confidence == .likely } && spike.summary.contains("unknown"))
}

@Test func anEndSnapshotFromAnEarlierSpikeIsNotPaired() throws {
    // The previous spike's "ended" snapshot (10 s before this spike's first sample) is in the window, before the start.
    let earlier = snapshot(-10, .ended, [("B", 2, 0)])
    let started = snapshot(30.2, .started, [("B", 2, 0)])
    let spike = try #require(investigate(busy + [earlier, started]).spikes.first)
    #expect(!spike.findings.contains { $0.confidence == .likely } && spike.summary.contains("unknown"))
    // With this spike's own end, the pair is made from the right snapshots.
    let ended = snapshot(60.2, .ended, [("B", 2, 400 * mb)])
    let paired = try #require(investigate(busy + [earlier, started, ended]).spikes.first)
    let likely = try #require(paired.findings.first { $0.confidence == .likely })
    #expect(Set(likely.evidence) == [started.id, ended.id])
}

@Test func busySamplesAcrossASamplingGapAreTwoSpikes() {
    let events = [sample(30, received: 300 * mb, peak: 30 * mb), sample(200, received: 300 * mb, peak: 30 * mb)]
    let result = NetworkInvestigator.investigate(from: at(0), to: at(300), events: events, recordingSince: at(-3600))
    #expect(result.spikes.count == 2 && result.spikes.map(\.from) == [at(30), at(200)])
    #expect(result.limits.contains { $0.statement.contains("Sampling stopped") })
}

@Test func aSpikeWithoutSnapshotsIsUnknown() throws {
    let spike = try #require(investigate(busy).spikes.first)
    #expect(spike.summary.contains("unknown") && spike.findings.contains { $0.confidence == .unknown })
    #expect(!spike.findings.contains { $0.confidence == .likely })
}

@Test func oneSnapshotIsNotEnoughToNameAProcess() throws {
    let spike = try #require(investigate(busy + [snapshot(30.2, .started, [("B", 2, 900 * mb)])]).spikes.first)
    #expect(!spike.findings.contains { $0.confidence == .likely } && spike.summary.contains("unknown"))
}

@Test func aSpikeDuringADarkWakeIsCorrelated() throws {
    let wake = darkWake(-5)
    let result = investigate(busy + [wake, sleep(100)])
    let finding = try #require(result.spikes.first?.findings.first { $0.confidence == .correlated })
    #expect(finding.evidence == [wake.id] && finding.statement.contains("dark wake"))
    // A dark wake that ended before the spike isn't correlated.
    #expect(!(investigate(busy + [darkWake(-50), sleep(-20)]).spikes.first?.findings.contains { $0.confidence == .correlated } ?? true))
}

@Test func aFailedSnapshotIsALimit() throws {
    let failed = NetTop.event(.failure(.commandFailed("nettop (started) exited with status 3")), edge: .started, clock: RecorderClock(now: { at(30.2) }))
    let ended = snapshot(60.2, .ended, [("B", 2, 400 * mb)])
    let result = investigate(busy + [failed, ended])
    let limit = try #require(result.limits.first { $0.evidence == [failed.id] })
    #expect(limit.statement.contains("exited with status 3"))
    #expect(!(result.spikes.first?.findings.contains { $0.confidence == .likely } ?? true))
    #expect(result.evidence.contains { $0.id == failed.id })
}

@Test func nettopCoverageIsAlwaysALimitWhenThereIsASpike() {
    #expect(investigate(busy).limits.contains { $0.statement.contains("recent connections") })
}

@Test func aSpikeInTheWindowsFirstSampleHasNoStartingPoint() throws {
    let spike = try #require(investigate([sample(0, received: 300 * mb, peak: 30 * mb), sample(30)]).spikes.first)
    #expect(spike.from == at(0))
    #expect(spike.findings.allSatisfy { !$0.statement.contains("0 s") && Set($0.evidence).count == $0.evidence.count })
    #expect(spike.findings.first?.statement.contains("since the sample before") == true)
}

@Test func aSystemMonitorOffSpanInTheWindowIsALimitNotQuiet() {
    let off = Event.gap(from: at(-50), to: at(100), reason: .systemMonitorOff, clock: clock)
    let result = investigate([sample(0), sample(30), off])
    #expect(result.spikes.isEmpty)
    #expect(result.limits.contains { $0.evidence == [off.id] && $0.statement.hasPrefix("System recording was turned off from ") })
    #expect(!result.limits.contains { $0.statement.contains("system_monitor_off") }, "only the off span's own limit, not the generic one")
}
