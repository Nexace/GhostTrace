import Foundation
import RecorderCore

/// Turns raw `SystemReading`s into what a stored sample reports (totals and peaks since the last stored sample) and says
/// when something changed enough to store one. Pure and in memory: the sampler feeds it every check.
public struct ActivityTracker: Sendable {
    public static let highLoad = 0.8
    public static let busyRate: UInt64 = 10 << 20
    public static let chargeDrop = 5
    public static let freeSpaceDrop: UInt64 = 1 << 30

    public enum Edge: Sendable, Equatable { case started, ended }

    public struct CheckResult: Sendable, Equatable {
        /// Busy fraction 0...1 between the previous check and this one.
        public var cpuBusy: Double?
        /// Bytes/s since the previous check, by wall time (so a long sleep doesn't inflate it). Sent plus received.
        public var networkRate: UInt64?
        public var diskRate: UInt64?
        public var storeNow = false
        public var networkBusyEdge: Edge?
    }

    private struct Totals {
        var busyTicks: UInt64 = 0
        var totalTicks: UInt64 = 0
        var cpuPeak: Double?
        var gpuSum = 0
        var gpuChecks = 0
        var gpuPeak = 0
        var networkIn: UInt64 = 0
        var networkOut: UInt64 = 0
        var networkPeak: UInt64 = 0
        var diskRead: UInt64 = 0
        var diskWritten: UInt64 = 0
        var diskPeak: UInt64 = 0
        /// Check-to-check spans where both readings had the counters: none means the bytes weren't measured, not that none moved.
        var networkSpans = 0
        var diskSpans = 0
        var reset = false
    }

    private var last: SystemReading?
    private var totals = Totals()
    private var loadHigh = false
    private var networkBusy = false
    private var diskBusy = false
    /// The charge and free space when the last sample was stored (or first seen): drops are counted from there.
    private var storedCharge: Int?
    private var storedFreeSpace: UInt64?

    public init() {}

    public mutating func check(_ now: SystemReading) -> CheckResult {
        var result = CheckResult()
        var high = (now.gpuUtilization ?? 0) >= Int(Self.highLoad * 100)
        if let gpu = now.gpuUtilization {
            totals.gpuSum += gpu
            totals.gpuChecks += 1
            totals.gpuPeak = max(totals.gpuPeak, gpu)
        }
        storedCharge = storedCharge ?? now.battery?.charge
        storedFreeSpace = storedFreeSpace ?? now.freeSpace
        defer { last = now }
        // The first check has nothing to compare with: no rates, and nothing to store for.
        guard let before = last else {
            loadHigh = high
            return result
        }
        let seconds = now.at.timeIntervalSince(before.at)

        if let a = before.cpu, let b = now.cpu, b.total > a.total, b.busy >= a.busy {
            let busy = min(1, Double(b.busy - a.busy) / Double(b.total - a.total))
            result.cpuBusy = busy
            totals.busyTicks += b.busy - a.busy
            totals.totalTicks += b.total - a.total
            totals.cpuPeak = max(totals.cpuPeak ?? 0, busy)
            high = high || busy >= Self.highLoad
        }
        if high != loadHigh { result.storeNow = true }
        loadHigh = high

        if let a = before.network, let b = now.network, let moved = bytesMoved((a.received, a.sent), (b.received, b.sent)) {
            totals.networkSpans += 1
            totals.networkIn += moved.0
            totals.networkOut += moved.1
            if seconds > 0 {
                let rate = UInt64(Double(moved.0 + moved.1) / seconds)
                result.networkRate = rate
                totals.networkPeak = max(totals.networkPeak, rate)
                if (rate >= Self.busyRate) != networkBusy {
                    networkBusy.toggle()
                    result.networkBusyEdge = networkBusy ? .started : .ended
                    result.storeNow = true
                }
            }
        } else if before.network != nil, now.network != nil {
            totals.networkSpans += 1
            totals.reset = true
        }
        if let a = before.disk, let b = now.disk, let moved = bytesMoved((a.read, a.written), (b.read, b.written)) {
            totals.diskSpans += 1
            totals.diskRead += moved.0
            totals.diskWritten += moved.1
            if seconds > 0 {
                let rate = UInt64(Double(moved.0 + moved.1) / seconds)
                result.diskRate = rate
                totals.diskPeak = max(totals.diskPeak, rate)
                if (rate >= Self.busyRate) != diskBusy {
                    diskBusy.toggle()
                    result.storeNow = true
                }
            }
        } else if before.disk != nil, now.disk != nil {
            totals.diskSpans += 1
            totals.reset = true
        }

        if let was = before.battery?.onBattery, let isNow = now.battery?.onBattery, was != isNow { result.storeNow = true }
        if let charge = now.battery?.charge, let stored = storedCharge, stored - charge >= Self.chargeDrop { result.storeNow = true }
        if let free = now.freeSpace, let stored = storedFreeSpace, stored > free, stored - free >= Self.freeSpaceDrop { result.storeNow = true }
        return result
    }

    /// Totals and peaks since the previous `take`, from the checks made since. Starts a new accumulation.
    public mutating func take(at: Date) -> SystemActivity {
        let t = totals
        let now = last
        totals = Totals()
        storedCharge = now?.battery?.charge
        storedFreeSpace = now?.freeSpace
        return SystemActivity(
            cpuBusy: t.totalTicks > 0 ? Double(t.busyTicks) / Double(t.totalTicks) : nil, cpuPeak: t.cpuPeak,
            gpuUtilization: t.gpuChecks > 0 ? Int((Double(t.gpuSum) / Double(t.gpuChecks)).rounded()) : nil,
            gpuPeak: t.gpuChecks > 0 ? t.gpuPeak : nil, gpuMemoryInUse: now?.gpuMemoryInUse,
            networkIn: t.networkSpans == 0 ? nil : t.networkIn, networkOut: t.networkSpans == 0 ? nil : t.networkOut,
            networkPeakRate: t.networkSpans == 0 ? nil : t.networkPeak,
            diskRead: t.diskSpans == 0 ? nil : t.diskRead, diskWritten: t.diskSpans == 0 ? nil : t.diskWritten,
            diskPeakRate: t.diskSpans == 0 ? nil : t.diskPeak, freeSpace: now?.freeSpace,
            onBattery: now?.battery?.onBattery, charge: now?.battery?.charge, watts: now?.battery?.watts, minutesToEmpty: now?.battery?.minutesToEmpty,
            countersReset: t.reset ? true : nil)
    }

    /// Bytes moved on a pair of counters, or nil if either went backwards: within one recorder life that is an interface or
    /// drive disappearing, and counting the whole current total would fake a spike.
    private func bytesMoved(_ before: (UInt64, UInt64), _ now: (UInt64, UInt64)) -> (UInt64, UInt64)? {
        let first = Counter.delta(now.0, since: before.0), second = Counter.delta(now.1, since: before.1)
        return first.reset || second.reset ? nil : (first.bytes, second.bytes)
    }
}
