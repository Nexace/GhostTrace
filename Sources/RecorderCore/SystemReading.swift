import Foundation

/// Cumulative CPU ticks across all cores. Load over a span is the change in `busy` over the change in `total`.
public struct CPUTicks: Codable, Sendable, Equatable {
    public var busy: UInt64
    public var total: UInt64

    public init(busy: UInt64, total: UInt64) {
        self.busy = busy
        self.total = total
    }
}

/// Cumulative bytes over every non-loopback network interface since boot.
public struct NetworkBytes: Codable, Sendable, Equatable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }
}

/// Cumulative bytes over every block storage driver since boot.
public struct DiskBytes: Codable, Sendable, Equatable {
    public var read: UInt64
    public var written: UInt64

    public init(read: UInt64, written: UInt64) {
        self.read = read
        self.written = written
    }
}

public struct BatteryReading: Codable, Sendable, Equatable {
    public var onBattery: Bool
    public var charging: Bool
    /// Percent, 0 to 100.
    public var charge: Int
    /// Power now, absolute (charging and draining both positive).
    public var watts: Double?
    public var minutesToEmpty: Int?

    public init(onBattery: Bool, charging: Bool, charge: Int, watts: Double? = nil, minutesToEmpty: Int? = nil) {
        self.onBattery = onBattery
        self.charging = charging
        self.charge = charge
        self.watts = watts
        self.minutesToEmpty = minutesToEmpty
    }
}

/// One raw look at the whole system. Counters are cumulative; rates come from two readings. A field the system
/// wouldn't give is nil, never zero.
public struct SystemReading: Codable, Sendable, Equatable {
    public var at: Date
    public var cpu: CPUTicks?
    public var network: NetworkBytes?
    public var disk: DiskBytes?
    /// Percent.
    public var gpuUtilization: Int?
    public var gpuMemoryInUse: UInt64?
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    public var pressure: MemoryPressure?
    /// Space available for important usage on the startup volume, and its total size.
    public var freeSpace: UInt64?
    public var volumeCapacity: UInt64?
    /// Nil on a Mac without a battery.
    public var battery: BatteryReading?
    /// Seconds since the last keyboard or mouse input.
    public var idleSeconds: Double?

    public init(at: Date, cpu: CPUTicks? = nil, network: NetworkBytes? = nil, disk: DiskBytes? = nil,
                gpuUtilization: Int? = nil, gpuMemoryInUse: UInt64? = nil,
                memoryUsed: UInt64? = nil, memoryTotal: UInt64? = nil, pressure: MemoryPressure? = nil,
                freeSpace: UInt64? = nil, volumeCapacity: UInt64? = nil,
                battery: BatteryReading? = nil, idleSeconds: Double? = nil) {
        self.at = Date(roundingToMilliseconds: at)
        self.cpu = cpu
        self.network = network
        self.disk = disk
        self.gpuUtilization = gpuUtilization
        self.gpuMemoryInUse = gpuMemoryInUse
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.pressure = pressure
        self.freeSpace = freeSpace
        self.volumeCapacity = volumeCapacity
        self.battery = battery
        self.idleSeconds = idleSeconds
    }
}

public enum Counter {
    /// Change in a cumulative counter. A counter that went down was reset (interface restart, reboot): the new value is
    /// what it counted since, and `reset` says so.
    public static func delta(_ now: UInt64, since before: UInt64) -> (bytes: UInt64, reset: Bool) {
        now >= before ? (now - before, false) : (now, true)
    }
}
