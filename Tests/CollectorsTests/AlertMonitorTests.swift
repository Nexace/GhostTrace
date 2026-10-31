@testable import Collectors
import Foundation
import RecorderCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let gb: UInt64 = 1_000_000_000

/// Readings 30 s apart unless `step` says otherwise.
private func reading(_ n: Int, step: TimeInterval = 30, gpu: Int? = nil, pressure: MemoryPressure? = nil, free: UInt64? = nil, capacity: UInt64? = nil,
                     battery: BatteryReading? = nil, idle: Double? = nil) -> SystemReading {
    SystemReading(at: t0.addingTimeInterval(TimeInterval(n) * step), gpuUtilization: gpu, pressure: pressure, freeSpace: free, volumeCapacity: capacity,
                  battery: battery, idleSeconds: idle)
}

private func onBattery(_ charge: Int, _ onBattery: Bool = true) -> BatteryReading { BatteryReading(onBattery: onBattery, charging: !onBattery, charge: charge) }

private func sample(_ processes: [ProcessSample]) -> ResourceSample {
    ResourceSample(interval: 30, memoryTotal: 0, memoryUsed: 0, compressed: 0, swapUsed: 0, pressure: .normal, processes: processes, readable: 0, unreadable: 0, tookMilliseconds: 0)
}

/// Feeds each reading and returns every transition as `(rule, started)`.
private func feed(_ monitor: inout AlertMonitor, _ readings: [SystemReading], cpu: Double? = nil, latest: ResourceSample? = nil, interval: TimeInterval = 30)
    -> [(AlertMonitor.Rule, Bool)] {
    readings.flatMap { monitor.check($0, cpuBusy: cpu, latest: latest, interval: interval) }.map { ($0.rule, $0.started) }
}

@Test func batteryDrainStartsOnceAndEndsWhenPluggedIn() {
    var monitor = AlertMonitor()
    // 60 -> 52 over 10 min projects 65 min.
    let drain = (0...20).map { reading($0, battery: onBattery(60 - $0 * 2 / 5)) }
    let procs = sample([ProcessSample(pid: 1, name: "Chrome", footprint: 1, energy: 4), ProcessSample(pid: 2, name: "Xcode", footprint: 1, energy: 9),
                        ProcessSample(pid: 3, name: "idle", footprint: 1, energy: 0)])
    let started = feed(&monitor, drain, latest: procs)
    #expect(started.map(\.0) == [.batteryDrain] && started.map(\.1) == [true])
    #expect(monitor.state.active[.batteryDrain] != nil)
    let more = monitor.check(reading(21, battery: onBattery(52)), cpuBusy: nil, latest: procs, interval: 30)
    #expect(more.isEmpty)
    let end = monitor.check(reading(22, battery: onBattery(52, false)), cpuBusy: nil, latest: nil, interval: 30)
    #expect(end.map(\.started) == [false] && end.first?.message == "Battery drain is over.")
}

@Test func batteryDrainMessageNamesTheTopUsers() {
    var monitor = AlertMonitor()
    let procs = sample([ProcessSample(pid: 1, name: "Chrome", footprint: 1, energy: 4), ProcessSample(pid: 2, name: "Xcode", footprint: 1, energy: 9)])
    let ts = (0...20).flatMap { monitor.check(reading($0, battery: onBattery(60 - $0 * 2 / 5)), cpuBusy: nil, latest: procs, interval: 30) }
    #expect(ts.first?.message == "Battery draining fast: about 1 h 5 min left. Top users among your processes: Xcode 9.0 W, Chrome 4.0 W.")
    #expect(ts.first?.names == ["Xcode", "Chrome"])
}

@Test func diskFullUsesBothThresholds() {
    var monitor = AlertMonitor()
    func step(_ n: Int, free: UInt64) -> [Bool] {
        monitor.check(reading(n, free: free, capacity: 500 * gb), cpuBusy: nil, latest: nil, interval: 30).map(\.started)
    }
    #expect(step(0, free: 9 * gb) == [true])
    #expect(step(1, free: 12 * gb).isEmpty)
    #expect(step(2, free: 16 * gb).isEmpty)  // 3.2%
    #expect(step(3, free: 40 * gb) == [false])
}

@Test func diskFullMessage() {
    var monitor = AlertMonitor()
    let ts = monitor.check(reading(0, free: 9 * gb, capacity: 500 * gb), cpuBusy: nil, latest: nil, interval: 30)
    #expect(ts.first?.message == "Startup disk nearly full: 9 GB free.")
}

@Test func memoryCriticalEndsAfterFiveMinutesBelow() {
    var monitor = AlertMonitor()
    #expect(feed(&monitor, [reading(0, pressure: .critical)]).map(\.1) == [true])
    // 9 readings = 240 s below critical, and a critical one resets the count.
    #expect(feed(&monitor, (1...9).map { reading($0, pressure: .warn) }).isEmpty)
    #expect(feed(&monitor, [reading(10, pressure: .critical)]).isEmpty)
    #expect(feed(&monitor, (11...20).map { reading($0, pressure: .warn) }).isEmpty)  // 300 s span, but reading 10 is inside it
    #expect(feed(&monitor, [reading(21, pressure: .normal)]).map(\.1) == [false])
}

@Test func sustainedLoadNeedsFiveMinutesAndIdle() {
    func run(idle: Double?) -> [Bool] {
        var monitor = AlertMonitor()
        return feed(&monitor, (0...10).map { reading($0, idle: idle) }, cpu: 0.9).map(\.1)
    }
    #expect(run(idle: 400) == [true])
    #expect(run(idle: 10).isEmpty)
    #expect(run(idle: nil) == [true])

    var monitor = AlertMonitor()
    _ = feed(&monitor, (0...10).map { reading($0, idle: 400) }, cpu: 0.9)
    #expect(feed(&monitor, [reading(11, idle: 400)], cpu: 0.5).isEmpty)
    #expect(feed(&monitor, [reading(12, idle: 400)], cpu: 0.5).map(\.1) == [false])
}

@Test func sustainedLoadNamesEachUserWithItsShareAndCollapsesDuplicates() {
    let procs = sample([ProcessSample(pid: 1, name: "yes", footprint: 1, cpu: 99), ProcessSample(pid: 2, name: "yes", footprint: 1, cpu: 98.4),
                        ProcessSample(pid: 3, name: "Claude", footprint: 1, cpu: 3), ProcessSample(pid: 4, name: "idle", footprint: 1)])
    func message(idle: Double?) -> String? {
        var monitor = AlertMonitor()
        return (0...10).flatMap { monitor.check(reading($0, idle: idle), cpuBusy: 0.9, latest: procs, interval: 30) }.first?.message
    }
    #expect(message(idle: 400) == "CPU has been above 80% for 5 minutes while you were away. Top CPU users among your processes: yes ×2 197%, Claude 3%.")
    // Idle time unreadable: the rule drops the idle condition, so it doesn't claim the user was away.
    #expect(message(idle: nil) == "CPU has been above 80% for 5 minutes. Top CPU users among your processes: yes ×2 197%, Claude 3%.")
}

@Test func sustainedLoadReportsTheGPUWhenOnlyItIsBusy() {
    var monitor = AlertMonitor()
    let ts = (0...10).flatMap { monitor.check(reading($0, gpu: 85, idle: 400), cpuBusy: 0.2, latest: nil, interval: 30) }
    #expect(ts.first?.message.hasPrefix("GPU has been above 80% for 5 minutes while you were away.") == true)
    #expect(ts.first?.message.hasSuffix("Which process is unknown.") == true)
    // The CPU being quiet doesn't end a GPU load; the GPU dropping does.
    #expect(monitor.check(reading(11, gpu: 85), cpuBusy: 0.1, latest: nil, interval: 30).isEmpty)
    _ = monitor.check(reading(12, gpu: 10), cpuBusy: 0.1, latest: nil, interval: 30)
    #expect(monitor.check(reading(13, gpu: 10), cpuBusy: 0.1, latest: nil, interval: 30).map(\.started) == [false])
}

@Test func aRuleStaysQuietForAnHourAfterEnding() {
    var monitor = AlertMonitor()
    func step(_ n: Int, free: UInt64) -> [Bool] {
        monitor.check(reading(n, free: free, capacity: 500 * gb), cpuBusy: nil, latest: nil, interval: 30).map(\.started)
    }
    #expect(step(0, free: 9 * gb) == [true])
    #expect(step(1, free: 40 * gb) == [false])
    #expect(step(2, free: 9 * gb).isEmpty)
    #expect(step(119, free: 9 * gb).isEmpty)  // 3570 s after the end
    #expect(step(122, free: 9 * gb) == [true])  // 3600 s after the end
}

/// The recorder doesn't call `check` while paused (Task 6 enforces it), so a monitor that isn't fed keeps its state.
@Test func nothingFiresWhilePaused() {
    let monitor = AlertMonitor()
    #expect(monitor.state == AlertMonitor.State())
}

@Test func noBatteryMeansNoDrainAlert() {
    var monitor = AlertMonitor()
    #expect(feed(&monitor, (0...30).map { reading($0, battery: nil) }).isEmpty)
}

@Test func aSleepGapIsNotSustained() {
    var monitor = AlertMonitor()
    #expect(feed(&monitor, [reading(0), reading(1)], cpu: 0.9).isEmpty)
    // Two hours asleep, then busy again: the readings before the gap don't count.
    let wake = t0.addingTimeInterval(7200)
    func after(_ s: TimeInterval) -> SystemReading { SystemReading(at: wake.addingTimeInterval(s), idleSeconds: 400) }
    #expect(monitor.check(after(0), cpuBusy: 0.9, latest: nil, interval: 30).isEmpty)
    #expect((1..<10).flatMap { monitor.check(after(TimeInterval($0) * 30), cpuBusy: 0.9, latest: nil, interval: 30) }.isEmpty)
    #expect(monitor.check(after(300), cpuBusy: 0.9, latest: nil, interval: 30).map(\.started) == [true])
}

@Test func windowsWorkAtTheLongestInterval() {
    var monitor = AlertMonitor()
    // 55 left after a 5 point drop in 600 s projects 110 min.
    let ts = feed(&monitor, [reading(0, step: 600, battery: onBattery(60)), reading(1, step: 600, battery: onBattery(55))], interval: 600)
    #expect(ts.map(\.0) == [.batteryDrain] && ts.map(\.1) == [true])
}

@Test func aShortIntervalStillSpansTheWindows() {
    var monitor = AlertMonitor()
    // 5 s checks: 5 min needs 61 readings, more than the default cap.
    let started = feed(&monitor, (0...60).map { reading($0, step: 5, idle: 400) }, cpu: 0.9, interval: 5)
    #expect(started.map(\.0) == [.sustainedLoad] && started.map(\.1) == [true])
}

@Test func stateSurvivesARestart() throws {
    var monitor = AlertMonitor()
    let busy = (0...10).map { reading($0, idle: 400) }
    #expect(feed(&monitor, busy, cpu: 0.9).count == 1)
    var restarted = AlertMonitor(state: try JSONDecoder().decode(AlertMonitor.State.self, from: JSONEncoder().encode(monitor.state)))
    #expect(restarted.state == monitor.state)
    #expect(feed(&restarted, (11...14).map { reading($0, idle: 400) }, cpu: 0.9).isEmpty)
}

/// The recorder saves the state in the store's JSON format, which rounds times to milliseconds.
@Test func stateSurvivesTheRecordersStorageFormat() throws {
    var monitor = AlertMonitor()
    #expect(feed(&monitor, (0...10).map { reading($0, idle: 400) }, cpu: 0.9).count == 1)
    let saved = String(decoding: try GhostTraceJSON.encoder().encode(monitor.state), as: UTF8.self)
    var restarted = AlertMonitor(state: try GhostTraceJSON.decoder().decode(AlertMonitor.State.self, from: Data(saved.utf8)))
    #expect(restarted.state.active == monitor.state.active)
    #expect(feed(&restarted, (11...14).map { reading($0, idle: 400) }, cpu: 0.9).isEmpty)
}

@Test func theEventCarriesTheRuleStateAndEvidence() {
    let id = UUID()
    let t = AlertMonitor.Transition(rule: .diskFull, started: true, at: t0, message: "m", values: ["free_bytes": "1"], names: ["a", "b"])
    let e = AlertMonitor.event(t, evidence: [id], clock: RecorderClock(now: { t0 }))
    #expect(e.kind == .alert && e.source == "alerts" && e.occurredAt == t0)
    #expect(e.payload["rule"] == "disk_full" && e.payload["state"] == "started" && e.payload["message"] == "m")
    #expect(e.payload["names"] == "a, b" && e.payload["free_bytes"] == "1" && e.payload["evidence"] == id.uuidString)
}
