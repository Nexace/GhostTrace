import Darwin
import Foundation
import IOKit
import IOKit.ps
import os
import RecorderCore

/// One cheap look at the whole system, with no permission needed. Every part that fails leaves its field nil.
public struct SystemReader: Sendable {
    public var read: @Sendable () -> SystemReading

    public init(read: @escaping @Sendable () -> SystemReading) {
        self.read = read
    }

    public static let live = SystemReader {
        let memory = ResourceSampler.systemMemory()
        let gpu = gpuStats()
        let volume = volumeSpace()
        return SystemReading(
            at: Date(), cpu: cpu(), network: network(), disk: disk(),
            gpuUtilization: gpu?.utilization, gpuMemoryInUse: gpu?.memory,
            memoryUsed: memory?.used, memoryTotal: memory?.total, pressure: memory?.pressure,
            freeSpace: volume?.free, volumeCapacity: volume?.capacity,
            battery: battery(), idleSeconds: idleSeconds())
    }

    /// The value of `key` on every registry entry of an IOKit class.
    private static func registryValues(_ service: String, _ key: String) -> [Any] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(service), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var values: [Any] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { values.append(value) }
        }
        return values
    }

    private static func cpu() -> CPUTicks? {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in 0..<Int(cores) {
            let ticks = (0..<Int(CPU_STATE_MAX)).map { UInt64(UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + $0])) }
            total += ticks.reduce(0, +)
            busy += ticks[Int(CPU_STATE_USER)] + ticks[Int(CPU_STATE_SYSTEM)] + ticks[Int(CPU_STATE_NICE)]
        }
        return CPUTicks(busy: busy, total: total)
    }

    /// Only `en*` (Ethernet and Wi-Fi): tunnels (utun) repeat the traffic of the interface they ride on, and transient
    /// interfaces (awdl, llw) come and go, which would make the sum drop and read as a reset.
    private static func network() -> NetworkBytes? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Slack, so an interface appearing between the size query and the fetch doesn't fail the read.
        var buffer = [UInt8](repeating: 0, count: size + size / 8)
        size = buffer.count
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= size {
            let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self) }
            guard header.ifm_msglen > 0 else { break }
            defer { offset += Int(header.ifm_msglen) }
            guard Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size else { continue }
            let message = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
            guard isEthernetName(buffer, link: offset + MemoryLayout<if_msghdr2>.size, end: min(size, offset + Int(header.ifm_msglen))) else { continue }
            received += message.ifm_data.ifi_ibytes
            sent += message.ifm_data.ifi_obytes
        }
        return NetworkBytes(received: received, sent: sent)
    }

    /// Whether the `sockaddr_dl` that follows an `RTM_IFINFO2` message names an `en*` interface. Read in place:
    /// `if_indextoname` runs its own sysctl per interface, which was most of a check's network cost (~0.9 ms).
    static func isEthernetName(_ buffer: [UInt8], link: Int, end: Int) -> Bool {
        // sockaddr_dl: sdl_len, sdl_family, sdl_index (2), sdl_type, sdl_nlen, sdl_alen, sdl_slen, then sdl_data starts with the name.
        guard link + 10 <= end, buffer[link + 1] == UInt8(AF_LINK), buffer[link + 5] >= 2 else { return false }
        return buffer[link + 8] == UInt8(ascii: "e") && buffer[link + 9] == UInt8(ascii: "n")
    }

    private static func disk() -> DiskBytes? {
        let statistics = registryValues("IOBlockStorageDriver", "Statistics").compactMap { $0 as? [String: Any] }
        guard !statistics.isEmpty else { return nil }
        func sum(_ key: String) -> UInt64 { statistics.reduce(0) { $0 + (($1[key] as? NSNumber)?.uint64Value ?? 0) } }
        return DiskBytes(read: sum("Bytes (Read)"), written: sum("Bytes (Write)"))
    }

    private static func gpuStats() -> (utilization: Int, memory: UInt64)? {
        for case let stats as [String: Any] in registryValues("IOAccelerator", "PerformanceStatistics") {
            if let utilization = stats["Device Utilization %"] as? NSNumber, let memory = stats["In use system memory"] as? NSNumber {
                return (utilization.intValue, memory.uint64Value)
            }
        }
        return nil
    }

    /// "Available for important usage" (free plus purgeable space) takes a CacheDelete lookup, 4 ms warm but ~16 ms of CPU
    /// after a 30 s idle on battery, so it is asked at most once per 10 min (the sample heartbeat), or when free space has
    /// moved by 256 MB (purging or filling the disk moves it). `statfs` is cheap and read every time: the cached purgeable
    /// amount is added to it.
    private struct Volume { var checkedAt: Date, free: UInt64, purgeable: UInt64 }
    private static let volume = OSAllocatedUnfairLock<Volume?>(initialState: nil)
    private static let volumeRefresh: TimeInterval = 600
    private static let volumeMovement: UInt64 = 256 << 20

    static func volumeSpace(now: Date = Date()) -> (free: UInt64, capacity: UInt64)? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let capacity = UInt64(stats.f_blocks) * UInt64(stats.f_bsize)
        let free = UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
        let cached = volume.withLock { $0 }
        if let cached, now.timeIntervalSince(cached.checkedAt) < volumeRefresh, now >= cached.checkedAt,
           free.distance(to: cached.free).magnitude < volumeMovement.magnitude {
            return (free + cached.purgeable, capacity)
        }
        let important = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
        // A failed lookup is cached too, as no purgeable space, so it isn't repeated on every check.
        let purgeable = important.map { $0 > free ? $0 - free : 0 } ?? 0
        volume.withLock { $0 = Volume(checkedAt: now, free: free, purgeable: purgeable) }
        return (free + purgeable, capacity)
    }

    private static func battery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let charge = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let minutes = description[kIOPSTimeToEmptyKey] as? Int
            // AppleSmartBattery reports milliamps and millivolts; the sign only says which way the current flows.
            let watts = (registryValues("AppleSmartBattery", "Amperage").first as? NSNumber).flatMap { amps in
                (registryValues("AppleSmartBattery", "Voltage").first as? NSNumber).map { abs(Double(amps.int64Value) * Double($0.int64Value)) / 1e6 }
            }
            return BatteryReading(onBattery: description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                                  charging: description[kIOPSIsChargingKey] as? Bool ?? false, charge: charge,
                                  watts: watts, minutesToEmpty: minutes.flatMap { $0 >= 0 ? $0 : nil })
        }
        return nil
    }

    private static func idleSeconds() -> Double? {
        (registryValues("IOHIDSystem", "HIDIdleTime").first as? NSNumber).map { Double($0.uint64Value) / 1e9 }
    }
}
