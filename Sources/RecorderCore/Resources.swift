import Foundation

/// macOS's own memory-pressure level (`kern.memorystatus_vm_pressure_level`). Ordered from best to worst.
public enum MemoryPressure: String, Codable, Sendable, Comparable, CaseIterable {
    case normal, warn, critical

    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// One process in a resource sample.
public struct ProcessSample: Codable, Sendable, Equatable {
    public var pid: Int32
    /// The executable's file name. The full path isn't stored: it was most of a sample's size (ADR 0004).
    public var name: String
    /// With `pid`, identifies the process: pids are reused.
    public var startedAt: Date?
    /// `phys_footprint`, which Activity Monitor shows as "Memory".
    public var footprint: UInt64
    /// Change since the previous stored sample, even if the process wasn't listed in it. Nil if it started since then.
    public var footprintChange: Int64?
    /// Average percent of one core since the previous stored sample (time asleep excluded), or since it started if it started since then.
    public var cpu: Double?
    /// Average watts since the previous stored sample (`ri_energy_nj`), or since it started if it started since then.
    public var energy: Double?
    /// Bytes read from and written to disk since the previous stored sample, or since it started if it started since then.
    public var diskRead: UInt64?
    public var diskWritten: UInt64?

    public init(pid: Int32, name: String, startedAt: Date? = nil, footprint: UInt64, footprintChange: Int64? = nil, cpu: Double? = nil,
                energy: Double? = nil, diskRead: UInt64? = nil, diskWritten: UInt64? = nil) {
        self.pid = pid
        self.name = name
        self.startedAt = startedAt.map(Date.init(roundingToMilliseconds:))
        self.footprint = footprint
        self.footprintChange = footprintChange
        self.cpu = cpu
        self.energy = energy
        self.diskRead = diskRead
        self.diskWritten = diskWritten
    }

    /// Identity across samples.
    public var key: String { "\(pid)@\(startedAt?.milliseconds ?? 0)" }
}

/// What the whole system did since the previous stored sample (ADR 0004's rule: checked often, stored on change). A field the
/// system wouldn't give, or that this Mac doesn't have (battery on a desktop), is nil.
public struct SystemActivity: Codable, Sendable, Equatable {
    /// Fractions 0...1: the average since the last stored sample, and the highest single check.
    public var cpuBusy: Double?
    public var cpuPeak: Double?
    /// Percent: the average, the highest check, and the latest memory in use.
    public var gpuUtilization: Int?
    public var gpuPeak: Int?
    public var gpuMemoryInUse: UInt64?
    /// Bytes since the last stored sample, and the fastest check in bytes/s.
    public var networkIn: UInt64?
    public var networkOut: UInt64?
    public var networkPeakRate: UInt64?
    public var diskRead: UInt64?
    public var diskWritten: UInt64?
    public var diskPeakRate: UInt64?
    public var freeSpace: UInt64?
    public var onBattery: Bool?
    public var charge: Int?
    public var watts: Double?
    public var minutesToEmpty: Int?
    /// True if a network or disk counter went backwards in the span: that check's bytes aren't in the totals.
    public var countersReset: Bool?

    public init(cpuBusy: Double? = nil, cpuPeak: Double? = nil, gpuUtilization: Int? = nil, gpuPeak: Int? = nil, gpuMemoryInUse: UInt64? = nil,
                networkIn: UInt64? = nil, networkOut: UInt64? = nil, networkPeakRate: UInt64? = nil,
                diskRead: UInt64? = nil, diskWritten: UInt64? = nil, diskPeakRate: UInt64? = nil, freeSpace: UInt64? = nil,
                onBattery: Bool? = nil, charge: Int? = nil, watts: Double? = nil, minutesToEmpty: Int? = nil, countersReset: Bool? = nil) {
        self.cpuBusy = cpuBusy
        self.cpuPeak = cpuPeak
        self.gpuUtilization = gpuUtilization
        self.gpuPeak = gpuPeak
        self.gpuMemoryInUse = gpuMemoryInUse
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.networkPeakRate = networkPeakRate
        self.diskRead = diskRead
        self.diskWritten = diskWritten
        self.diskPeakRate = diskPeakRate
        self.freeSpace = freeSpace
        self.onBattery = onBattery
        self.charge = charge
        self.watts = watts
        self.minutesToEmpty = minutesToEmpty
        self.countersReset = countersReset
    }
}

/// A snapshot of system memory and the busiest processes, as of `Event.occurredAt`.
/// Memory is checked every `interval`, but a sample is stored only when it changed enough, or after `heartbeat` (ADR 0004).
public struct ResourceSample: Codable, Sendable, Equatable {
    public var interval: TimeInterval
    /// Longest time between stored samples while sampling runs. Nil in samples stored before this rule (every check was stored).
    public var heartbeat: TimeInterval?
    public var memoryTotal: UInt64
    /// App memory + wired + compressed, as Activity Monitor counts "Memory Used".
    public var memoryUsed: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64
    public var pressure: MemoryPressure
    /// The largest by memory, the busiest by CPU, and any that grew sharply since the previous sample.
    public var processes: [ProcessSample]
    /// Processes that could be read (this user's).
    public var readable: Int
    /// Processes that couldn't be read (other users', including system daemons).
    public var unreadable: Int
    public var tookMilliseconds: Int
    /// CPU, GPU, network, disk and battery since the previous stored sample. Nil in samples stored before Phase 6.
    public var system: SystemActivity?

    public init(interval: TimeInterval, heartbeat: TimeInterval? = nil, memoryTotal: UInt64, memoryUsed: UInt64, compressed: UInt64, swapUsed: UInt64, pressure: MemoryPressure,
                processes: [ProcessSample], readable: Int, unreadable: Int, tookMilliseconds: Int) {
        self.interval = interval
        self.heartbeat = heartbeat
        self.memoryTotal = memoryTotal
        self.memoryUsed = memoryUsed
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.pressure = pressure
        self.processes = processes
        self.readable = readable
        self.unreadable = unreadable
        self.tookMilliseconds = tookMilliseconds
    }

    public static let source = "resources/proc_pid_rusage+host_statistics64"
    /// A sample is stored when memory in use changes this much since the last stored one…
    public static let storeOnSystemChange: Int64 = 1 << 30
    /// …or one process's footprint does (a new process counts from zero), or the pressure level changes.
    public static let storeOnProcessChange: Int64 = 512 << 20
    static let payloadKey = "sample"

    /// The sample travels as JSON in the string payload, with a few readable keys beside it for `ghosttrace events`.
    public func event(at: Date? = nil, clock: RecorderClock) -> Event {
        let json = String(decoding: try! GhostTraceJSON.encoder().encode(self), as: UTF8.self)
        return Event(kind: .resourceSample, source: Self.source, occurredAt: at,
                     payload: [Self.payloadKey: json, "memory_used": Self.bytes(memoryUsed), "pressure": pressure.rawValue],
                     quality: .sampled,
                     provenance: heartbeat.map { "Checked every \(Int(interval)) s, stored on change or every \(Int($0 / 60)) min. Own processes only." }
                         ?? "Snapshot taken every \(Int(interval)) s. Only this user's processes can be read; values between samples aren't known.",
                     clock: clock)
    }

    public init?(_ event: Event) {
        guard event.kind == .resourceSample, let json = event.payload[Self.payloadKey],
              let sample = try? GhostTraceJSON.decoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = sample
    }

    /// `1.2 GB`, `350 MB`: binary units, as Activity Monitor shows them.
    public static func bytes(_ value: some BinaryInteger) -> String {
        let (gb, mb) = (1_073_741_824.0, 1_048_576.0)
        let magnitude = Double(value.magnitude)
        let sign = value < 0 ? "-" : ""
        return magnitude >= gb ? sign + String(format: "%.1f GB", magnitude / gb) : sign + "\(Int((magnitude / mb).rounded())) MB"
    }

    /// Decimal units, as Finder and the System pane show disk space and traffic; memory stays in `bytes`' binary units, as Activity Monitor shows it.
    public static func fileBytes(_ value: some BinaryInteger) -> String {
        let magnitude = Double(value.magnitude)
        let sign = value < 0 ? "-" : ""
        return magnitude >= 1e9 ? sign + String(format: "%.1f GB", magnitude / 1e9) : sign + "\(Int((magnitude / 1e6).rounded())) MB"
    }
}
