import Foundation
import RecorderCore

/// The four alert rules. Pure and in memory: the recorder feeds it every check (never while paused) and stores the
/// transitions it returns. `State` is `Codable` so an incident survives a recorder restart.
public struct AlertMonitor: Sendable {
    public enum Rule: String, Codable, CaseIterable, Sendable {
        case batteryDrain = "battery_drain", diskFull = "disk_full", memoryCritical = "memory_critical", sustainedLoad = "sustained_load"

        public var title: String {
            switch self {
            case .batteryDrain: "Battery drain"
            case .diskFull: "Low disk space"
            case .memoryCritical: "Critical memory pressure"
            case .sustainedLoad: "Sustained load"
            }
        }
    }

    public struct Transition: Codable, Sendable, Equatable {
        public var rule: Rule
        public var started: Bool
        public var at: Date
        public var message: String
        public var values: [String: String]
        public var names: [String]
    }

    /// What the rules need from one reading: not the whole `SystemReading`, to keep the saved state small.
    public struct Recent: Codable, Sendable, Equatable {
        var at: Date
        var cpuBusy: Double?
        var gpu: Int?
        var charge: Int?
        var pressure: MemoryPressure?
    }

    public struct State: Codable, Sendable, Equatable {
        var readings: [Recent] = []
        var active: [Rule: Date] = [:]
        var lastEnded: [Rule: Date] = [:]
        /// Which load started `sustained_load`, so that load alone decides when it ends.
        var loadIsGPU = false

        public init() {}
    }

    // 10 min at the default 30 s interval needs 21 readings to span the window; 24 leaves room for the timer's 3 s leeway. A shorter interval keeps more.
    static let maxReadings = 24
    static let highLoad = 0.8, lowLoad = 0.6
    static let cooldown: TimeInterval = 3600
    static let batteryWindow: TimeInterval = 600, loadWindow: TimeInterval = 300, memoryWindow: TimeInterval = 300
    static let batteryStart: TimeInterval = 2 * 3600, batteryEnd: TimeInterval = 3 * 3600
    static let diskStartBytes: UInt64 = 10_000_000_000, diskEndBytes: UInt64 = 15_000_000_000
    static let diskStartShare = 0.05, diskEndShare = 0.075
    static let idleNeeded: TimeInterval = 300

    public var state: State

    public init(state: State = .init()) { self.state = state }

    public mutating func check(_ reading: SystemReading, cpuBusy: Double?, latest: ResourceSample?, interval: TimeInterval) -> [Transition] {
        state.readings.append(Recent(at: reading.at, cpuBusy: cpuBusy, gpu: reading.gpuUtilization, charge: reading.battery?.charge, pressure: reading.pressure))
        state.readings.removeFirst(max(0, state.readings.count - max(Self.maxReadings, Int(Self.batteryWindow / interval) + 3)))
        var out: [Transition] = []
        for rule in Rule.allCases {
            let step = state.active[rule] == nil ? start(rule, reading, latest, interval) : end(rule, reading, interval)
            guard let (started, message, values, names) = step else { continue }
            if started { state.active[rule] = reading.at } else { state.active[rule] = nil; state.lastEnded[rule] = reading.at }
            out.append(Transition(rule: rule, started: started, at: reading.at, message: message, values: values, names: names))
        }
        return out
    }

    private typealias Step = (started: Bool, message: String, values: [String: String], names: [String])

    private mutating func start(_ rule: Rule, _ reading: SystemReading, _ latest: ResourceSample?, _ interval: TimeInterval) -> Step? {
        if let ended = state.lastEnded[rule], reading.at.timeIntervalSince(ended) < Self.cooldown { return nil }
        switch rule {
        case .batteryDrain:
            guard reading.battery?.onBattery == true, let window = window(Self.batteryWindow, interval),
                  let seconds = projection(window), seconds < Self.batteryStart else { return nil }
            let (names, list) = Self.top(latest, by: { $0.energy }) { String(format: "%.1f W", $0) }
            let minutes = Int((seconds / 60).rounded())
            return (true, "Battery draining fast: about \(minutes / 60) h \(minutes % 60) min left. Top users among your processes: \(list).",
                    ["projected_minutes": "\(minutes)", "charge": "\(reading.battery?.charge ?? 0)"], names)
        case .diskFull:
            guard let free = reading.freeSpace,
                  free < Self.diskStartBytes || share(free, of: reading.volumeCapacity).map({ $0 < Self.diskStartShare }) == true else { return nil }
            return (true, "Startup disk nearly full: \(Self.size(free)) free.",
                    ["free_bytes": "\(free)", "capacity_bytes": reading.volumeCapacity.map(String.init) ?? "unknown"],
                    Self.top(latest, by: { $0.diskWritten.map { Double($0) } }) { Self.size(UInt64($0)) }.names)
        case .memoryCritical:
            guard reading.pressure == .critical else { return nil }
            let (names, list) = Self.top(latest, by: { Double($0.footprint) }) { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }
            return (true, "Memory pressure is critical. Largest among your processes: \(list).", ["pressure": "critical"], names)
        case .sustainedLoad:
            guard let window = window(Self.loadWindow, interval), reading.idleSeconds.map({ $0 >= Self.idleNeeded }) ?? true else { return nil }
            let gpu = window.allSatisfy { ($0.gpu ?? 0) >= Int(Self.highLoad * 100) }
            guard gpu || window.allSatisfy({ ($0.cpuBusy ?? 0) >= Self.highLoad }) else { return nil }
            // Both loads high: report the CPU, which has names.
            let useGPU = gpu && !window.allSatisfy { ($0.cpuBusy ?? 0) >= Self.highLoad }
            let (names, list) = Self.top(latest, by: { $0.cpu }) { "\(Int($0.rounded()))%" }
            state.loadIsGPU = useGPU
            // Unreadable idle time drops the idle condition, so "away" is said only when it was read.
            let away = reading.idleSeconds == nil ? "" : " while you were away"
            return (true, "\(useGPU ? "GPU" : "CPU") has been above 80% for 5 minutes\(away). Top CPU users among your processes: \(list)."
                    + (useGPU ? " Which process is unknown." : ""), ["load": useGPU ? "gpu" : "cpu"], names)
        }
    }

    private mutating func end(_ rule: Rule, _ reading: SystemReading, _ interval: TimeInterval) -> Step? {
        let over: Bool
        switch rule {
        case .batteryDrain:
            over = reading.battery.map { !$0.onBattery } == true || window(Self.batteryWindow, interval).flatMap(projection).map { $0 > Self.batteryEnd } == true
        case .diskFull:
            over = reading.freeSpace.map { free in free > Self.diskEndBytes && share(free, of: reading.volumeCapacity).map { $0 > Self.diskEndShare } != false } == true
        case .memoryCritical:
            over = window(Self.memoryWindow, interval)?.allSatisfy { $0.pressure.map { $0 != .critical } == true } == true
        case .sustainedLoad:
            let last = state.readings.suffix(2)
            over = last.count == 2 && last.allSatisfy { r in
                state.loadIsGPU ? r.gpu.map { $0 < Int(Self.lowLoad * 100) } == true : r.cpuBusy.map { $0 < Self.lowLoad } == true
            }
        }
        return over ? (false, "\(rule.title) is over.", [:], []) : nil
    }

    /// The trailing readings that span at least `length` with no gap over `max(2 × interval, 90 s)`; a sleep gap resets it.
    private func window(_ length: TimeInterval, _ interval: TimeInterval) -> ArraySlice<Recent>? {
        let r = state.readings
        guard let last = r.last else { return nil }
        let maxGap = max(2 * interval, 90)
        var i = r.count - 1
        while i > 0, r[i].at.timeIntervalSince(r[i - 1].at) <= maxGap {
            i -= 1
            if last.at.timeIntervalSince(r[i].at) >= length { return r[i...] }
        }
        return nil
    }

    /// Seconds until empty at the window's rate of drop; infinite if the charge isn't falling.
    private func projection(_ window: ArraySlice<Recent>) -> TimeInterval? {
        guard let first = window.first, let last = window.last, let from = first.charge, let to = last.charge else { return nil }
        let drop = from - to
        return drop > 0 ? Double(to) / (Double(drop) / last.at.timeIntervalSince(first.at)) : .infinity
    }

    private func share(_ free: UInt64, of capacity: UInt64?) -> Double? {
        capacity.flatMap { $0 > 0 ? Double(free) / Double($0) : nil }
    }

    /// The top three names by `key` in the sample (only this user's processes are readable), same-named processes summed,
    /// and a list such as "yes ×3 297%, Xcode 4%" so a small figure can't pass as the cause of a big load.
    private static func top(_ latest: ResourceSample?, by key: (ProcessSample) -> Double?, format: (Double) -> String) -> (names: [String], list: String) {
        var groups: [String: (total: Double, count: Int)] = [:]
        for p in latest?.processes ?? [] {
            guard let value = key(p), value > 0 else { continue }
            groups[p.name, default: (0, 0)].total += value
            groups[p.name]?.count += 1
        }
        let top = groups.sorted { ($0.value.total, $1.key) > ($1.value.total, $0.key) }.prefix(3)
        let list = top.map { "\($0.key)\($0.value.count > 1 ? " ×\($0.value.count)" : "") \(format($0.value.total))" }
        return (top.map(\.key), list.isEmpty ? "none measurable" : list.joined(separator: ", "))
    }

    /// Decimal units, as Finder shows disk sizes.
    private static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal) }

    public static let source = "alerts"

    public static func event(_ t: Transition, evidence: [UUID], clock: RecorderClock) -> Event {
        var payload = t.values
        payload["rule"] = t.rule.rawValue
        payload["state"] = t.started ? "started" : "ended"
        payload["message"] = t.message
        payload["names"] = t.names.joined(separator: ", ")
        payload["evidence"] = evidence.map(\.uuidString).joined(separator: ",")
        return Event(kind: .alert, source: source, occurredAt: t.at, payload: payload, quality: .inferred,
                     provenance: "Rule evaluated on recent system readings; names come from the latest resource sample.", clock: clock)
    }
}
