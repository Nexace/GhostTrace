@testable import Collectors
import Foundation
import RecorderCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Readings 30 s apart unless `after` says otherwise.
private func reading(_ n: Int, after seconds: TimeInterval = 30, cpu: CPUTicks? = nil, network: NetworkBytes? = nil, disk: DiskBytes? = nil,
                     freeSpace: UInt64? = nil, battery: BatteryReading? = nil) -> SystemReading {
    SystemReading(at: t0.addingTimeInterval(TimeInterval(n) * seconds), cpu: cpu, network: network, disk: disk, freeSpace: freeSpace, battery: battery)
}

/// 100 ticks per check, `busy` percent of them busy.
private func cpuAt(_ n: Int, busy: UInt64) -> CPUTicks { CPUTicks(busy: UInt64(n) * busy, total: UInt64(n) * 100) }

@Test func crossingHighLoadStoresOnceEachWay() {
    var tracker = ActivityTracker()
    // The first reading is only a baseline: CPU load needs two tick readings.
    _ = tracker.check(reading(0, cpu: cpuAt(0, busy: 0)))
    var ticks = CPUTicks(busy: 0, total: 0)
    var stores: [Bool] = []
    for busy in [50, 90, 95, 40] as [UInt64] {
        ticks = CPUTicks(busy: ticks.busy + busy, total: ticks.total + 100)
        stores.append(tracker.check(reading(stores.count + 1, cpu: ticks)).storeNow)
    }
    #expect(stores == [false, true, false, true])
}

@Test func networkAndDiskBusyEdgesStore() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, network: NetworkBytes(received: 0, sent: 0), disk: DiskBytes(read: 0, written: 0)))
    var total: UInt64 = 0
    var results: [ActivityTracker.CheckResult] = []
    for rate in [1, 20, 2] as [UInt64] {
        total += (rate << 20) * 30
        results.append(tracker.check(reading(results.count + 1, network: NetworkBytes(received: total, sent: 0), disk: DiskBytes(read: 0, written: total))))
    }
    #expect(results.map(\.storeNow) == [false, true, true])
    #expect(results.map(\.networkBusyEdge) == [nil, .started, .ended])
    #expect(results[1].networkRate == 20 << 20 && results[1].diskRate == 20 << 20)
}

@Test func theFirstCheckHasNoRatesAndDoesNotStore() {
    var tracker = ActivityTracker()
    let first = tracker.check(reading(0, cpu: CPUTicks(busy: 99, total: 100), network: NetworkBytes(received: 1 << 40, sent: 0), battery: BatteryReading(onBattery: true, charging: false, charge: 50)))
    #expect(!first.storeNow && first.cpuBusy == nil && first.networkRate == nil && first.diskRate == nil && first.networkBusyEdge == nil)
}

@Test func chargeDropOfFivePointsStores() {
    var tracker = ActivityTracker()
    func battery(_ charge: Int) -> BatteryReading { BatteryReading(onBattery: true, charging: false, charge: charge) }
    _ = tracker.check(reading(0, battery: battery(80)))
    #expect(!tracker.check(reading(1, battery: battery(77))).storeNow)
    #expect(tracker.check(reading(2, battery: battery(75))).storeNow)
    // Counted from the last stored sample, not the last check.
    _ = tracker.take(at: t0)
    #expect(!tracker.check(reading(3, battery: battery(72))).storeNow)
    #expect(tracker.check(reading(4, battery: battery(70))).storeNow)
}

@Test func powerSourceChangeStores() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, battery: BatteryReading(onBattery: false, charging: true, charge: 80)))
    #expect(!tracker.check(reading(1, battery: BatteryReading(onBattery: false, charging: true, charge: 81))).storeNow)
    #expect(tracker.check(reading(2, battery: BatteryReading(onBattery: true, charging: false, charge: 81))).storeNow)
    #expect(!tracker.check(reading(3, battery: BatteryReading(onBattery: true, charging: false, charge: 81))).storeNow)
}

@Test func freeSpaceDropOfOneGiBStores() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, freeSpace: 100 << 30))
    #expect(!tracker.check(reading(1, freeSpace: (100 << 30) - (1 << 29))).storeNow)
    #expect(tracker.check(reading(2, freeSpace: (99 << 30) - 1)).storeNow)
}

@Test func takeReturnsTotalsAndPeaksSinceLastTake() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, network: NetworkBytes(received: 0, sent: 0)))
    var received: UInt64 = 0
    for (n, megabytes) in ([10, 30, 5] as [UInt64]).enumerated() {
        received += megabytes << 20
        _ = tracker.check(reading(n + 1, network: NetworkBytes(received: received, sent: 0)))
    }
    let activity = tracker.take(at: t0)
    #expect(activity.networkIn == 45 << 20 && activity.networkOut == 0)
    #expect(activity.networkPeakRate == (30 << 20) / 30)
    // No check since: nothing was measured, which is not the same as nothing moved.
    #expect(tracker.take(at: t0).networkIn == nil)
}

@Test func theFirstTakeAfterAFreshStartMeasuredNoBytes() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, network: NetworkBytes(received: 5 << 30, sent: 0), disk: DiskBytes(read: 1 << 30, written: 0)))
    let activity = tracker.take(at: t0)
    #expect(activity.networkIn == nil && activity.networkOut == nil && activity.networkPeakRate == nil)
    #expect(activity.diskRead == nil && activity.diskWritten == nil && activity.diskPeakRate == nil)
}

@Test func aFailedLastReadingKeepsTheTotals() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, network: NetworkBytes(received: 0, sent: 0)))
    _ = tracker.check(reading(1, network: NetworkBytes(received: 10 << 20, sent: 1)))
    _ = tracker.check(reading(2))
    let activity = tracker.take(at: t0)
    #expect(activity.networkIn == 10 << 20 && activity.networkOut == 1)
}

@Test func takeAveragesCPUAndKeepsThePeak() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, cpu: CPUTicks(busy: 0, total: 0)))
    _ = tracker.check(reading(1, cpu: CPUTicks(busy: 20, total: 100)))
    _ = tracker.check(reading(2, cpu: CPUTicks(busy: 80, total: 200)))
    let activity = tracker.take(at: t0)
    #expect(activity.cpuBusy == 0.4 && activity.cpuPeak == 0.6)
    #expect(activity.networkIn == nil && activity.onBattery == nil && activity.countersReset == nil)
}

@Test func takeReportsTheLatestBatteryAndFreeSpace() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, freeSpace: 50, battery: BatteryReading(onBattery: false, charging: true, charge: 40)))
    _ = tracker.check(reading(1, freeSpace: 40, battery: BatteryReading(onBattery: true, charging: false, charge: 38, watts: 7.5, minutesToEmpty: 300)))
    let activity = tracker.take(at: t0)
    #expect(activity.freeSpace == 40 && activity.onBattery == true && activity.charge == 38 && activity.watts == 7.5 && activity.minutesToEmpty == 300)
}

@Test func aCounterResetIsMarkedAndCountsNothing() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, disk: DiskBytes(read: 1000, written: 0)))
    let check = tracker.check(reading(1, disk: DiskBytes(read: 10, written: 0)))
    // A counter that went backwards gives no rate: its whole current total would fake a spike.
    #expect(check.diskRate == nil && !check.storeNow)
    let activity = tracker.take(at: t0)
    #expect(activity.countersReset == true && activity.diskRead == 0 && activity.diskPeakRate == 0)
    #expect(tracker.take(at: t0).countersReset == nil)
}

@Test func aLongSleepDoesNotInflateRates() {
    var tracker = ActivityTracker()
    _ = tracker.check(reading(0, network: NetworkBytes(received: 0, sent: 0)))
    let check = tracker.check(reading(1, after: 7200, network: NetworkBytes(received: 100 << 20, sent: 0)))
    #expect(check.networkRate == (100 << 20) / 7200 && check.networkBusyEdge == nil && !check.storeNow)
    #expect(tracker.take(at: t0).networkIn == 100 << 20)
}
