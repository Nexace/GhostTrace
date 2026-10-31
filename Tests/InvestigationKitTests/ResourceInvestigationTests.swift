import Foundation
import InvestigationKit
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_100_000_000) })
private let start = Date(milliseconds: 1_793_000_000_000)
private let gb: UInt64 = 1 << 30
private let mb: UInt64 = 1 << 20

private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private func process(_ name: String, pid: Int32, _ footprint: UInt64, change: Int64? = 0, startedAt: Date = start.addingTimeInterval(-3600)) -> ProcessSample {
    ProcessSample(pid: pid, name: name, startedAt: startedAt, footprint: footprint, footprintChange: change)
}

private func sample(_ seconds: TimeInterval, used: UInt64, pressure: MemoryPressure = .normal, interval: TimeInterval = 30,
                    heartbeat: TimeInterval? = nil, system: SystemActivity? = nil, _ processes: [ProcessSample]) -> Event {
    var sample = ResourceSample(interval: interval, heartbeat: heartbeat, memoryTotal: 16 * gb, memoryUsed: used, compressed: 0, swapUsed: 0, pressure: pressure, processes: processes,
                                readable: 500, unreadable: 200, tookMilliseconds: 7)
    sample.system = system
    return sample.event(at: at(seconds), clock: clock)
}

private func launch(_ name: String, _ seconds: TimeInterval) -> Event {
    Event(kind: .appLaunch, source: "app-lifecycle/NSWorkspaceDidLaunchApplicationNotification", occurredAt: at(seconds),
          subject: Subject(pid: 900, name: name), clock: clock)
}

private let steady = process("Safari", pid: 10, 3 * gb)

// MARK: Downsampling

@Test func samplesDownsampleIntoChartPointsAndRankProcessesByPeak() {
    // One hour at 30 s: 120 samples into 60 points of two samples each.
    let events = (0..<120).map { i in
        sample(Double(i) * 30, used: (8 + UInt64(i % 4)) * gb, [steady, process("Mail", pid: 11, (i == 50 ? 4 : 1) * gb)])
    }
    let summary = ResourceAnalyzer.summarize(from: start, to: at(3600), events: events, points: 60, top: 1, recordingSince: start)
    #expect(summary.sampleCount == 120)
    #expect(summary.points.count == 60)
    #expect(summary.points.allSatisfy { $0.samples == 2 })
    #expect(summary.points[0].memoryUsedAverage == UInt64(8.5 * Double(gb)) && summary.points[0].memoryUsedPeak == 9 * gb)
    #expect(summary.top.map(\.name) == ["Mail"])
    #expect(summary.top[0].peakFootprint == 4 * gb && summary.top[0].peakAt == at(1500) && summary.top[0].latestFootprint == gb)
    #expect(summary.samplingGaps.isEmpty)
}

@Test func aSamplingGapLeavesEmptyPointsOutAndIsReported() {
    // Samples for the first and last 10 minutes only: the Mac slept in between.
    let events = (0..<20).map { sample(Double($0) * 30, used: 8 * gb, [steady]) } + (100..<120).map { sample(Double($0) * 30, used: 8 * gb, [steady]) }
    let summary = ResourceAnalyzer.summarize(from: start, to: at(3600), events: events, points: 60, recordingSince: start)
    #expect(summary.points.count == 20)
    #expect(summary.samplingGaps == [DateInterval(start: at(570), end: at(3000))])
    #expect(summary.limits.contains { $0.statement.contains("Sampling stopped 1 time") })
}

@Test func noSamplesBeforeRecordingStartedSaysSo() {
    let summary = ResourceAnalyzer.summarize(from: start, to: at(3600), events: [], recordingSince: at(7200))
    #expect(summary.points.isEmpty && summary.top.isEmpty)
    #expect(summary.limits.map(\.statement) == ["GhostTrace wasn't recording yet, so there are no resource samples in this window."])
}

@Test func changingTheIntervalIsNotAGap() {
    let events = [sample(0, used: 8 * gb, interval: 30, [steady]), sample(40, used: 8 * gb, interval: 5, [steady]), sample(45, used: 8 * gb, interval: 5, [steady])]
    #expect(ResourceAnalyzer.summarize(from: start, to: at(60), events: events, recordingSince: start).samplingGaps.isEmpty)
}

// MARK: Memory spikes

@Test func oneProcessGrowingNamesItLikelyAndLeavesSteadyAndLaterProcessesOut() throws {
    let events = [
        sample(0, used: 8 * gb, [steady, process("Xcode", pid: 20, 1 * gb)]),
        sample(30, used: 10 * gb, [steady, process("Xcode", pid: 20, 2 * gb + 512 * mb, change: Int64(1536 * mb))]),
        sample(60, used: 10 * gb, [steady, process("Xcode", pid: 20, 2 * gb + 512 * mb)]),
        // Misleading: launched after the rise, with a large footprint of its own.
        sample(90, used: 10 * gb + 300 * mb, [steady, process("Xcode", pid: 20, 2 * gb + 512 * mb), process("Photos", pid: 30, 900 * mb, change: nil, startedAt: at(75))]),
        launch("Photos", 75),
        launch("Notes", 15),
    ].sorted { $0.occurredAt < $1.occurredAt }
    let investigation = MemoryInvestigator.investigate(from: start, to: at(120), events: events, recordingSince: start)
    let spike = try #require(investigation.spikes.first)
    #expect(investigation.spikes.count == 1)
    #expect((spike.from, spike.to) == (at(0), at(30)))
    #expect(spike.summary == "Likely cause: Xcode, which grew by 1.5 GB.")
    let likely = spike.findings.filter { $0.confidence == .likely }
    #expect(likely.count == 1 && likely[0].statement.hasPrefix("Xcode accounts for most of the rise (about 75%"))
    #expect(!spike.findings.contains { $0.statement.contains("Safari") || $0.statement.contains("Photos") })
    // Notes launched during the rise but didn't grow: correlated, never more.
    #expect(spike.findings.filter { $0.statement.contains("Notes") }.map(\.confidence) == [.correlated])
    #expect(spike.findings.allSatisfy { !$0.evidence.isEmpty })
    #expect(Set(investigation.evidence.map(\.id)) == Set(spike.findings.flatMap(\.evidence)))
}

@Test func growthSpreadAcrossManyProcessesIsUnknown() throws {
    let before = (0..<5).map { process("Helper \($0)", pid: 40 + Int32($0), 200 * mb) }
    let after = (0..<5).map { process("Helper \($0)", pid: 40 + Int32($0), 500 * mb, change: Int64(300 * mb)) }
    let events = [sample(0, used: 8 * gb, before), sample(30, used: 10 * gb, after)]
    let spike = try #require(MemoryInvestigator.investigate(from: start, to: at(60), events: events, recordingSince: start).spikes.first)
    #expect(!spike.findings.contains { $0.confidence == .likely })
    #expect(spike.findings.contains { $0.confidence == .unknown && $0.statement == "No sampled process accounts for most of this rise." })
    #expect(spike.findings.filter { $0.confidence == .observed && $0.statement.contains("grew by 300 MB") }.count == 5)
    #expect(spike.summary == "Memory in use rose by 2.0 GB; the cause is unknown.")
}

@Test func pressureRisingIsObservedEvenWithoutABigRise() throws {
    let events = [sample(0, used: 14 * gb, [steady]), sample(30, used: 14 * gb + 200 * mb, pressure: .warn, [steady])]
    let spike = try #require(MemoryInvestigator.investigate(from: start, to: at(60), events: events, recordingSince: start).spikes.first)
    #expect(spike.findings.contains { $0.confidence == .observed && $0.statement == "macOS's memory pressure went from normal to warn." })
    #expect(spike.summary == "Memory pressure rose to warn; the cause is unknown.")
}

@Test func aProcessStartedBetweenSamplesCountsFromNothing() throws {
    let events = [sample(0, used: 8 * gb, [steady]),
                  sample(5, used: 8 * gb + 800 * mb, interval: 5, [steady, process("Python", pid: 50, 2 * gb, change: nil, startedAt: at(2))])]
    let spike = try #require(MemoryInvestigator.investigate(from: start, to: at(10), events: events, recordingSince: start).spikes.first)
    #expect(spike.findings.contains { $0.confidence == .observed && $0.statement == "Python (pid 50) started during the rise and reached 2.0 GB." })
    #expect(spike.findings.contains { $0.confidence == .likely && $0.statement.hasPrefix("Python accounts for the rise") })
}

@Test func aRiseAcrossASamplingGapIsNotASpike() {
    // Asleep for 2 h: the rise isn't between consecutive samples, so nothing is claimed about it.
    let events = [sample(0, used: 6 * gb, [steady]), sample(7200, used: 12 * gb, [steady])]
    let investigation = MemoryInvestigator.investigate(from: start, to: at(7300), events: events, recordingSince: start)
    #expect(investigation.spikes.isEmpty)
    #expect(investigation.samplingGaps == [DateInterval(start: start, end: at(7200))])
}

@Test func recorderGapsDuringASpikeAreLimitsButPowerLogHolesAreNot() throws {
    let stopped = Event.gap(from: at(10), to: at(20), reason: .recorderInterrupted, clock: clock)
    let hole = Event.gap(from: at(-86400), to: at(100), reason: .powerLogHole, clock: clock)
    let events = [sample(0, used: 8 * gb, [steady]), stopped, sample(30, used: 11 * gb, [steady]), hole]
    let spike = try #require(MemoryInvestigator.investigate(from: start, to: at(60), events: events, recordingSince: start).spikes.first)
    #expect(spike.limits.map(\.evidence) == [[stopped.id]])
}

@Test func storedOnChangeSamplesAreAGapOnlyBeyondTheHeartbeat() {
    // Stored at most 10 min apart while sampling runs: 9 min apart is normal, 40 min is a stop.
    let events = [sample(0, used: 8 * gb, heartbeat: 600, [steady]), sample(540, used: 8 * gb, heartbeat: 600, [steady]),
                  sample(2940, used: 8 * gb, heartbeat: 600, [steady])]
    let summary = ResourceAnalyzer.summarize(from: start, to: at(3000), events: events, recordingSince: start)
    #expect(summary.samplingGaps == [DateInterval(start: at(540), end: at(2940))])
    #expect(summary.limits.contains { $0.statement.hasPrefix("Memory is checked every 30 s, and a sample is stored only when") })
}

// MARK: System series

@Test func pointsCarrySystemSeries() throws {
    // The first sample has no earlier one to span from, so its bytes don't count; the second moved 60 MB in 60 s.
    let events = [sample(0, used: 8 * gb, system: SystemActivity(cpuBusy: 0.2, cpuPeak: 0.5, gpuUtilization: 10, gpuPeak: 30, networkIn: 5 * mb, networkPeakRate: 3 * mb,
                                                                  diskRead: mb, diskPeakRate: mb, freeSpace: 90 * gb, onBattery: true, charge: 80), [steady]),
                  sample(60, used: 8 * gb, system: SystemActivity(cpuBusy: 0.4, cpuPeak: 0.9, gpuUtilization: 20, gpuPeak: 60, networkIn: 40 * mb, networkOut: 20 * mb, networkPeakRate: 7 * mb,
                                                                   diskRead: 30 * mb, diskWritten: 30 * mb, diskPeakRate: 2 * mb, freeSpace: 89 * gb, onBattery: false, charge: 79), [steady])]
    let point = try #require(ResourceAnalyzer.summarize(from: start, to: at(120), events: events, points: 1, recordingSince: start).points.first)
    #expect(point.samples == 2)
    #expect(point.networkRate == (60 * mb) / 60)
    #expect(point.networkPeakRate == 7 * mb)
    #expect(point.diskRate == (60 * mb) / 60)
    #expect(point.diskPeakRate == 2 * mb)
    #expect(abs(try #require(point.cpuBusyAverage) - 0.3) < 1e-9)
    #expect(point.cpuPeak == 0.9)
    #expect(point.gpuAverage == 15)
    #expect(point.gpuPeak == 60)
    #expect(point.charge == 79)
    #expect(point.freeSpace == 89 * gb)
    #expect(point.onBattery == false)
}

@Test func summaryAveragesRatesAsNumbersWeightedByPointLength() throws {
    // Two 60 s points at 1 MB/s and 3 MB/s average to 2 MB/s; a bit-pattern conversion of the UInt64 rate would give about 0.
    let events = [sample(0, used: 8 * gb, system: SystemActivity(networkIn: 0, diskRead: 0), [steady]),
                  sample(60, used: 8 * gb, system: SystemActivity(networkIn: 60 * mb, diskRead: 60 * mb), [steady]),
                  sample(120, used: 8 * gb, system: SystemActivity(networkIn: 180 * mb, diskRead: 180 * mb), [steady])]
    let summary = ResourceAnalyzer.summarize(from: start, to: at(180), events: events, points: 3, recordingSince: start)
    #expect(summary.points.compactMap(\.networkRate) == [mb, 3 * mb])
    #expect(summary.average(\.networkRate) == Double(2 * mb))
    #expect(summary.average(\.diskRate) == Double(2 * mb))
    #expect(summary.average(\.gpuAverage) == nil)
}

@Test func prePhase6SamplesLeaveTheSeriesNil() throws {
    let events = [sample(0, used: 8 * gb, [steady]), sample(60, used: 8 * gb, [steady])]
    let point = try #require(ResourceAnalyzer.summarize(from: start, to: at(120), events: events, points: 1, recordingSince: start).points.first)
    #expect(point.cpuBusyAverage == nil && point.cpuPeak == nil && point.gpuAverage == nil && point.gpuPeak == nil)
    #expect(point.networkRate == nil && point.networkPeakRate == nil && point.diskRate == nil && point.diskPeakRate == nil)
    #expect(point.charge == nil && point.freeSpace == nil && point.onBattery == nil)
}
