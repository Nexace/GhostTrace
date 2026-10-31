import Foundation
import InvestigationKit
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_100_000_000) })
private let start = Date(milliseconds: 1_793_000_000_000)
private let gb: UInt64 = 1 << 30
private let hour: TimeInterval = 3600

private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

/// A stored sample every half hour has a heartbeat of that long, so none of them is a gap.
private func sample(_ seconds: TimeInterval, charge: Int?, onBattery: Bool? = true, watts: Double? = 10, _ processes: [ProcessSample] = []) -> Event {
    var sample = ResourceSample(interval: 30, heartbeat: 1800, memoryTotal: 16 * gb, memoryUsed: 8 * gb, compressed: 0, swapUsed: 0, pressure: .normal,
                                processes: processes, readable: 500, unreadable: 200, tookMilliseconds: 7)
    sample.system = SystemActivity(onBattery: onBattery, charge: charge, watts: watts)
    return sample.event(at: at(seconds), clock: clock)
}

private func proc(_ name: String, pid: Int32, watts: Double?) -> ProcessSample {
    ProcessSample(pid: pid, name: name, startedAt: at(-hour), footprint: gb, energy: watts)
}

private func marker(_ kind: EventKind, _ seconds: TimeInterval) -> Event { Event(kind: kind, source: "test", occurredAt: at(seconds), clock: clock) }

private func darkWake(_ seconds: TimeInterval) -> Event {
    Event(kind: .diagnostic, source: "pmset", occurredAt: at(seconds), payload: ["entry": "dark_wake", "reason": "EC.SleepTimer"], clock: clock)
}

private func launch(_ name: String, _ seconds: TimeInterval) -> Event {
    Event(kind: .appLaunch, source: "app-lifecycle", occurredAt: at(seconds), subject: Subject(pid: 900, name: name), clock: clock)
}

/// 2 h on battery from 80% to 50%, a sample every 30 min, process energy as given.
private func twoHours(_ processes: [ProcessSample]) -> [Event] {
    [sample(0, charge: 80, [])] + (1...4).map { sample(Double($0) * 1800, charge: 80 - $0 * 30 / 4 , processes) }
}

private func investigate(_ events: [Event]) -> BatteryInvestigation {
    BatteryInvestigator.investigate(from: start, to: at(3 * hour), events: events, recordingSince: start)
}

@Test func aSessionReportsDrainAndTopUsers() throws {
    let events = twoHours([proc("A", pid: 1, watts: 3), proc("B", pid: 2, watts: 1)])
    let result = investigate(events)
    let session = try #require(result.sessions.first)
    #expect(result.hasBattery && result.sessions.count == 1)
    #expect(session.startCharge == 80 && session.endCharge == 50 && session.from == at(0) && session.to == at(2 * hour))
    #expect(session.drainPerHour == 15 && session.averageWatts == 10)
    let drained = try #require(session.findings.first { $0.statement.contains("drained 15% per hour") })
    #expect(drained.confidence == .observed)
    let top = try #require(session.findings.first { $0.statement.contains("A used the most energy among your processes (30% of battery power)") })
    #expect(top.confidence == .observed && top.evidence.count > 1)
    #expect(session.findings.contains { $0.confidence == .unknown && $0.statement.contains("main cause") })
    #expect(!session.findings.contains { $0.confidence == .likely })
    #expect(result.limits.map(\.statement).contains("Your measured processes account for at least 40% of battery power."))
    #expect(result.evidence.map(\.occurredAt) == result.evidence.map(\.occurredAt).sorted())
    #expect(Set(result.evidence.map(\.id)).isSubset(of: Set(events.map(\.id))))
}

@Test func oneDominantProcessIsLikely() throws {
    let result = investigate(twoHours([proc("A", pid: 1, watts: 6), proc("B", pid: 2, watts: 1)]))
    let session = try #require(result.sessions.first)
    let likely = try #require(session.findings.first { $0.confidence == .likely })
    #expect(likely.statement.contains("A") && likely.statement.contains("60%"))
    #expect(Set(likely.evidence).isSubset(of: Set(result.evidence.map(\.id))) && likely.evidence.count >= 4)
    #expect(session.summary.contains("Likely cause: A"))
    #expect(!session.findings.contains { $0.confidence == .unknown && $0.statement.contains("main cause") })
}

@Test func exactlyHalfIsNotLikely() throws {
    let session = try #require(investigate(twoHours([proc("A", pid: 1, watts: 5)])).sessions.first)
    #expect(!session.findings.contains { $0.confidence == .likely })
}

@Test func drainWhileAsleepIsSeparate() throws {
    // Asleep from 40 min to 100 min: 70% before the sleep, 62% after the wake.
    let events = [sample(0, charge: 80), sample(1800, charge: 75), sample(2400, charge: 70), sample(6000, charge: 62), sample(7200, charge: 60),
                  marker(.sleep, 2500), marker(.wake, 5900), darkWake(3600), darkWake(9000)]
    let result = investigate(events)
    let session = try #require(result.sessions.first)
    #expect(session.asleepSeconds == 3400 && session.asleepDrop == 8)
    #expect(session.findings.contains { $0.confidence == .observed && $0.statement.contains("8 points") })
    #expect(session.findings.contains { $0.confidence == .unknown && $0.statement.contains("while asleep") })
    let dark = session.findings.filter { $0.confidence == .correlated && $0.statement.contains("dark wake") }
    #expect(dark.count == 1 && dark[0].evidence == [events[7].id])
    #expect(session.findings.allSatisfy { $0.confidence != .likely })
    // The sleep is not a gap in sampling.
    #expect(!result.limits.contains { $0.statement.contains("Sampling stopped") })
}

@Test func aLaunchWithoutEnergyIsOnlyCorrelated() throws {
    let result = investigate(twoHours([proc("A", pid: 1, watts: 1)]) + [launch("Notes", 1000), launch("Late", 3 * hour - 1)])
    let session = try #require(result.sessions.first)
    let launched = session.findings.filter { $0.statement.contains("Notes") }
    #expect(launched.count == 1 && launched[0].confidence == .correlated)
    #expect(!session.findings.contains { $0.statement.contains("Late") })
}

@Test func noBattery() {
    let events = [sample(0, charge: nil, onBattery: nil, watts: nil), sample(1800, charge: nil, onBattery: nil, watts: nil)]
    let result = investigate(events)
    #expect(!result.hasBattery && result.sessions.isEmpty)
    #expect(result.limits.map(\.statement) == ["This Mac has no battery, or GhostTrace couldn't read it."])
}

@Test func aGapNoSleepExplainsEndsTheSession() throws {
    let gap = Event.gap(from: at(4000), to: at(4500), reason: .recorderStopped, clock: clock)
    // No sleep explains the 3 h hole between 3600 and 14400, so it is two sessions rather than one drain across it.
    let events = [sample(0, charge: 90), sample(1800, charge: 85), sample(3600, charge: 80), sample(14400, charge: 40), sample(16200, charge: 35), gap]
    let result = BatteryInvestigator.investigate(from: start, to: at(5 * hour), events: events, recordingSince: start)
    #expect(result.sessions.map(\.endCharge) == [80, 35] && result.sessions.map(\.startCharge) == [90, 40])
    #expect(result.limits.contains { $0.evidence == [gap.id] })
    #expect(result.limits.contains { $0.statement.contains("Sampling stopped") })
}

@Test func aRecorderGapBetweenCloseSamplesEndsTheSession() {
    let gap = Event.gap(from: at(650), to: at(700), reason: .recorderInterrupted, clock: clock)
    let events = [sample(0, charge: 90), sample(600, charge: 89), sample(1200, charge: 88), sample(1800, charge: 87), gap]
    let result = investigate(events)
    #expect(result.sessions.count == 2 && result.limits.contains { $0.evidence == [gap.id] })
}

@Test func aGapStartingOnASampleTimeIsCountedOnceAndDropsNoSample() {
    // The gap starts exactly when the second sample was taken (the recorder was last alive then).
    let gap = Event.gap(from: at(600), to: at(700), reason: .recorderInterrupted, clock: clock)
    let events = [sample(0, charge: 90), sample(600, charge: 89), sample(1200, charge: 88), sample(1800, charge: 87), gap]
    let result = investigate(events)
    #expect(result.sessions.map(\.startCharge) == [90, 88] && result.sessions.map(\.endCharge) == [89, 87])
    #expect(result.limits.filter { $0.evidence == [gap.id] }.count == 1)
}

@Test func aGapSpanningSamplesIsOneHoleReportedOnce() {
    // The gap covers the samples at 1200 (and the stretch around it): the sessions before and after it are still reported.
    let gap = Event.gap(from: at(650), to: at(1500), reason: .recorderInterrupted, clock: clock)
    let events = [sample(0, charge: 90), sample(600, charge: 89), sample(1200, charge: 88), sample(1800, charge: 87), sample(2400, charge: 86), gap]
    let result = investigate(events)
    #expect(result.sessions.map(\.startCharge) == [90, 87] && result.sessions.map(\.endCharge) == [89, 86])
    #expect(result.limits.filter { $0.evidence == [gap.id] }.count == 1)
}

@Test func aGapInsideASleepDoesNotSplitTheSession() {
    let gap = Event.gap(from: at(3000), to: at(4000), reason: .recorderStopped, clock: clock)
    let events = [sample(0, charge: 80), sample(1800, charge: 75), sample(2400, charge: 70), sample(6000, charge: 62), sample(7200, charge: 60),
                  marker(.sleep, 2500), marker(.wake, 5900), gap]
    let result = investigate(events)
    #expect(result.sessions.count == 1 && result.limits.contains { $0.evidence == [gap.id] })
}

@Test func aSecondSleepWithoutAWakeKeepsTheFirst() throws {
    // A dark wake posts a second sleep with no wake between: the nap began at the first.
    let events = [sample(0, charge: 80), sample(1800, charge: 75), sample(2400, charge: 70), sample(6000, charge: 62), sample(7200, charge: 60),
                  marker(.sleep, 2500), darkWake(3600), marker(.sleep, 4000), marker(.wake, 5900)]
    let session = try #require(investigate(events).sessions.first)
    #expect(session.asleepSeconds == 3400 && session.asleepDrop == 8)
    let dark = session.findings.filter { $0.confidence == .correlated && $0.statement.contains("dark wake") }
    #expect(dark.count == 1 && dark[0].evidence == [events[6].id] && dark[0].statement.contains("18 min"))
}

@Test func coverageRoundsDownNotUp() {
    // 29% of battery power must not print as 28% through floating point.
    let result = investigate(twoHours([proc("A", pid: 1, watts: 2.9)]))
    #expect(result.limits.map(\.statement).contains("Your measured processes account for at least 29% of battery power."))
}

@Test func plugCrossingEndsASession() {
    let events = [sample(0, charge: 80, []), sample(1800, charge: 75, []), sample(3600, charge: 80, onBattery: false), sample(5400, charge: 85, onBattery: false)]
    #expect(investigate(events).sessions.count == 1)
    #expect(investigate([sample(0, charge: 80, onBattery: false)] + [sample(1800, charge: 79)]).sessions.isEmpty)
}

@Test func aGapExtendingPastANapStillSplits() {
    // The nap covers only 1000-1100 of the gap: 1200 and 1800 are inside the gap, so no session ends or starts there.
    let gap = Event.gap(from: at(650), to: at(1900), reason: .recorderInterrupted, clock: clock)
    let events = [sample(0, charge: 90), sample(600, charge: 89), sample(1200, charge: 88), sample(1800, charge: 87), sample(2400, charge: 86), sample(3000, charge: 85),
                  marker(.sleep, 1000), marker(.wake, 1100), gap]
    let result = investigate(events)
    #expect(result.sessions.map(\.startCharge) == [90, 86] && result.sessions.map(\.endCharge) == [89, 85])
    #expect(result.limits.filter { $0.evidence == [gap.id] }.count == 1)
}

@Test func aShortNapDoesNotExcuseALongerSamplingGap() {
    // 100 s asleep doesn't explain 5400 s without samples.
    let events = [sample(0, charge: 90), sample(600, charge: 89), sample(6000, charge: 80), sample(6600, charge: 79), marker(.sleep, 1000), marker(.wake, 1100)]
    let result = investigate(events)
    #expect(result.sessions.count == 2 && result.limits.contains { $0.statement.contains("Sampling stopped") })
}

@Test func aShortNapIsLeftOutOfEnergy() throws {
    // The sample after the nap reads 100 W; its span holds the nap, so only the awake spans at 10 W count.
    let events = [sample(0, charge: 90), sample(600, charge: 89), sample(1200, charge: 88, watts: 100), sample(1800, charge: 87), marker(.sleep, 700), marker(.wake, 800)]
    let session = try #require(investigate(events).sessions.first)
    #expect(session.averageWatts == 10 && session.asleepSeconds == 100)
}

@Test func noMeasuredProcessEnergyIsSaidPlainly() {
    let result = investigate(twoHours([proc("A", pid: 1, watts: nil)]))
    let statements = result.limits.map(\.statement)
    #expect(statements.contains("None of your processes' energy was measured, so the main cause is unknown."))
    #expect(!statements.contains { $0.contains("at least 0%") })
}

@Test func aSystemMonitorOffSpanSplitsTheSessionWithItsOwnLimit() {
    let off = Event.gap(from: at(650), to: at(700), reason: .systemMonitorOff, clock: clock)
    let events = [sample(0, charge: 90), sample(600, charge: 89), sample(1200, charge: 88), sample(1800, charge: 87), off]
    let result = investigate(events)
    #expect(result.sessions.count == 2)
    #expect(result.limits.filter { $0.evidence == [off.id] }.map(\.statement)
            == ["System recording was turned off from \(GhostTraceJSON.string(from: at(650))) to \(GhostTraceJSON.string(from: at(700))), so nothing was recorded then."])
}

@Test func anEmptyWindowWithASystemMonitorOffSpanSaysSo() {
    let off = Event.gap(from: at(-100), to: at(2000), reason: .systemMonitorOff, clock: clock)
    let result = investigate([off])
    #expect(result.sessions.isEmpty)
    #expect(result.limits.contains { $0.evidence == [off.id] && $0.statement.hasPrefix("System recording was turned off from ") })
}

@Test func aZeroWattReadingWithProcessEnergyDoesNotTrap() throws {
    let processes = [proc("A", pid: 1, watts: 2)]
    let events = [sample(0, charge: 80, watts: 0)] + (1...4).map { sample(Double($0) * 1800, charge: 80 - $0 * 30 / 4, watts: 0, processes) }
    let session = try #require(investigate(events).sessions.first)
    #expect(!session.findings.contains { $0.confidence == .likely })
    #expect(session.findings.contains { $0.confidence == .unknown && $0.statement.contains("main cause") })
}
