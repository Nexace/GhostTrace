import Darwin
import Foundation
import RecorderCore

/// Checks system memory and per-process memory and CPU on a timer, and stores a sample only when something changed
/// enough since the last stored one, or the heartbeat is due. Needs no permission, but macOS only lets a process read
/// the usage of processes owned by the same user: system daemons and other users' processes are counted, not read.
public final class ResourceSampler: Collector, @unchecked Sendable {
    public static let defaultInterval: TimeInterval = 30
    public static let intervalRange: ClosedRange<TimeInterval> = 5...600
    /// A sample is stored at least this often while sampling runs, so a stretch without samples means sampling stopped.
    public static let defaultHeartbeat: TimeInterval = 600
    static let topByMemory = 6
    static let topByCPU = 3
    static let topByEnergy = 3
    static let topByDiskWrites = 3
    static let systemChange = ResourceSample.storeOnSystemChange
    /// A process that changed this much is always listed.
    static let processChange = ResourceSample.storeOnProcessChange

    typealias Usage = (footprint: UInt64, cpuNanos: UInt64, energyNanojoules: UInt64, diskRead: UInt64, diskWritten: UInt64)

    /// pid plus start time (mach absolute, from rusage): pids are reused, and this needs no extra system call.
    struct Key: Hashable {
        let pid: Int32
        let start: UInt64
    }

    public let id = "resource-sampling"
    private let clock: RecorderClock
    private let heartbeat: TimeInterval
    private let reader: SystemReader
    let queue = DispatchQueue(label: "ghosttrace.resources", qos: .utility)
    private let lock = NSLock()
    private var currentInterval: TimeInterval
    private var timer: (any DispatchSourceTimer)?
    private var lastStored: (at: Date, sample: ResourceSample)?
    private var lastCheck: (at: Date, milliseconds: Int)?
    private var lastFailure: String?
    private var lastReading: SystemReading?
    private var monitorsSystem = true
    /// Called after every check with the stored sample, or nil if nothing was stored. Set before `start`.
    public var onCheck: (@Sendable (SystemReading, ActivityTracker.CheckResult, ResourceSample?) -> Void)?
    /// Touched only by `takeSample`, which runs on `queue`.
    private var tracker = ActivityTracker()
    /// Every readable process's usage; a seam for tests.
    var usageReader: () -> (usage: [Key: Usage], unreadable: Int) = ResourceSampler.readUsage
    /// The last stored sample's full reading. Touched only by `takeSample`, which runs on `queue`.
    private var baseline: (uptime: UInt64, at: Date, used: UInt64, pressure: MemoryPressure, processes: [Key: Usage], system: Bool)?

    public init(interval: TimeInterval = defaultInterval, heartbeat: TimeInterval = defaultHeartbeat, clock: RecorderClock = .live, reader: SystemReader = .live) {
        currentInterval = interval
        self.heartbeat = heartbeat
        self.clock = clock
        self.reader = reader
    }

    /// One raw look at the whole system, for callers that want it now rather than at the next check.
    public func read() -> SystemReading { reader.read() }

    /// "Record System Activity": when false, checks read only memory and CPU; no system reading, rates, energy, disk I/O or `onCheck`.
    public var systemMonitor: Bool {
        get { lock.withLock { monitorsSystem } }
        set { lock.withLock { monitorsSystem = newValue } }
    }

    /// The rows for what the system reading gives or can't give, from the last check.
    public func systemCapabilities() -> [CapabilityStatus] {
        let (last, on) = lock.withLock { (lastReading, monitorsSystem) }
        guard on else {
            return [("gpu-utilization", "GPU utilization"), ("battery", "Battery"), ("idle-time", "Idle time"), ("process-network", "Per-process network")]
                .map { CapabilityStatus(id: $0, name: $1, state: .unverified, detail: "Turned off in GhostTrace.") } + [
                CapabilityStatus(id: "process-gpu", name: "Per-process GPU", state: .missing, detail: "macOS doesn't report GPU use per process."),
                CapabilityStatus(id: "ssd-health", name: "SSD health", state: .missing, detail: "No SMART data is exposed to apps."),
            ]
        }
        func row(_ id: String, _ name: String, _ present: Bool?, found: String, absent: String) -> CapabilityStatus {
            guard last != nil else { return CapabilityStatus(id: id, name: name, state: .unverified, detail: "No check yet.") }
            return present == true ? CapabilityStatus(id: id, name: name, state: .observed, detail: found) : CapabilityStatus(id: id, name: name, state: .missing, detail: absent)
        }
        return [
            last?.gpuUtilization == nil && last != nil
                ? CapabilityStatus(id: "gpu-utilization", name: "GPU utilization", state: .missing, detail: "No GPU statistics were found. IOKit's GPU statistics keys are undocumented.")
                : CapabilityStatus(id: "gpu-utilization", name: "GPU utilization", state: .unverified, detail: "IOKit's GPU statistics keys are undocumented."),
            row("battery", "Battery", last.map { $0.battery != nil }, found: "Charge, power source and draw.", absent: "This Mac has no battery."),
            row("idle-time", "Idle time", last.map { $0.idleSeconds != nil }, found: "Seconds since the last keyboard or mouse input.", absent: "Idle time can't be read, so the sustained-load alert fires without waiting for you to be away."),
            CapabilityStatus(id: "process-network", name: "Per-process network", state: .missing, detail: "Only on demand through nettop, when traffic passes 10 MB/s."),
            CapabilityStatus(id: "process-gpu", name: "Per-process GPU", state: .missing, detail: "macOS doesn't report GPU use per process."),
            CapabilityStatus(id: "ssd-health", name: "SSD health", state: .missing, detail: "No SMART data is exposed to apps."),
        ]
    }

    public var interval: TimeInterval { lock.withLock { currentInterval } }

    /// Takes effect from the next check.
    public func setInterval(_ seconds: TimeInterval) {
        lock.withLock {
            currentInterval = seconds
            timer?.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .seconds(Int(max(1, seconds / 10))))
        }
    }

    public func status() -> CapabilityStatus {
        let (interval, stored, check, failure, running) = lock.withLock { (currentInterval, lastStored, lastCheck, lastFailure, timer != nil) }
        let name = "CPU and memory sampling"
        if let failure { return CapabilityStatus(id: id, name: name, state: .missing, detail: "Last check failed: \(failure)") }
        guard running, let stored, let check else {
            return CapabilityStatus(id: id, name: name, state: .unverified, detail: running ? "Every \(Int(interval)) s. No sample taken yet." : "Not running.")
        }
        let s = stored.sample
        return CapabilityStatus(id: id, name: name, state: .observed,
                                detail: "Checked every \(Int(interval)) s (last took \(check.milliseconds) ms); stored on a change, at least every \(Int(heartbeat / 60)) min. Last stored at \(GhostTraceJSON.string(from: stored.at)): \(s.readable) of \(s.readable + s.unreadable) processes readable (the rest belong to the system or other users).")
    }

    public func start(emit: @escaping @Sendable (Event) -> Void) throws {
        guard Self.systemMemory() != nil else { throw CollectorError.commandFailed("host_statistics64 failed; system memory can't be read.") }
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: currentInterval, leeway: .seconds(Int(max(1, currentInterval / 10))))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let at = clock.now()
                do {
                    let sample = try takeSample(at: at)
                    lock.withLock { lastFailure = nil }
                    if let sample {
                        lock.withLock { lastStored = (at, sample) }
                        emit(sample.event(at: at, clock: clock))
                    }
                } catch {
                    lock.withLock { lastFailure = "\(error)" }
                }
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
        // After a pause, the first sample starts afresh rather than averaging CPU, bytes or rates over the paused time. Queued after any running check.
        queue.async {
            self.baseline = nil
            self.tracker = ActivityTracker()
        }
    }

    /// One check of every process: one `proc_pid_rusage` call each, about 2 ms for 800 processes in a release build.
    /// Returns a sample to store, or nil when nothing changed enough since the last one. Call one at a time.
    func takeSample(at: Date) throws -> ResourceSample? {
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { lock.withLock { lastCheck = (at, Int((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1_000_000)) } }
        guard let memory = Self.systemMemory() else { throw CollectorError.commandFailed("host_statistics64 failed") }
        let (usage, unreadable) = usageReader()
        let systemOn = systemMonitor
        let reading = systemOn ? reader.read() : nil
        // While off, the tracker starts afresh, so rates after turning it on never span the off time.
        let check = reading.map { tracker.check($0) } ?? ActivityTracker.CheckResult()
        if !systemOn { tracker = ActivityTracker() }
        lock.withLock { lastReading = reading ?? lastReading }
        if let base = baseline {
            // A sample on each switch, so investigators never join system readings across the off span.
            let changed = check.storeNow || systemOn != base.system || at.timeIntervalSince(base.at) >= heartbeat || memory.pressure != base.pressure
                || abs(Int64(memory.used) - Int64(base.used)) >= Self.systemChange
                || usage.contains { key, now in abs(Int64(now.footprint) - Int64(base.processes[key]?.footprint ?? 0)) >= Self.processChange }
            guard changed else {
                if let reading { onCheck?(reading, check, nil) }
                return nil
            }
        }

        // Uptime excludes sleep, so CPU use isn't diluted by time asleep.
        let elapsed = baseline.map { started - $0.uptime } ?? 0
        // Energy and disk I/O only when both ends were measured with the system monitor on.
        let measured = systemOn && baseline?.system == true
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let all = usage.map { key, now -> (Key, footprint: UInt64, change: Int64?, cpu: Double?, energy: Double?, read: UInt64?, written: UInt64?) in
            let before = baseline?.processes[key]
            // A process that started since the baseline counts from zero over its life, which lies inside this sample's span:
            // without this, a load that just started would be missing from the sample (and the alert names) that report it.
            let startNs = key.start * UInt64(timebase.numer) / UInt64(timebase.denom)
            let fresh = before == nil && baseline.map { startNs > $0.uptime } == true && started > startNs
            let from = before ?? (fresh ? (footprint: 0, cpuNanos: 0, energyNanojoules: 0, diskRead: 0, diskWritten: 0) : nil)
            let span = fresh ? started - startNs : elapsed
            let system = measured ? from : nil
            let cpu = from.flatMap { before -> Double? in
                guard span > 0, now.cpuNanos >= before.cpuNanos else { return nil }
                return (Double(now.cpuNanos - before.cpuNanos) / Double(span) * 1000).rounded() / 10
            }
            // Energy in watts and disk bytes over the span, when the counters only went up.
            let energy = system.flatMap { before -> Double? in
                guard span > 0, now.energyNanojoules >= before.energyNanojoules else { return nil }
                return (Double(now.energyNanojoules - before.energyNanojoules) / Double(span) * 100).rounded() / 100
            }
            let read = system.flatMap { now.diskRead >= $0.diskRead ? now.diskRead - $0.diskRead : nil }
            let written = system.flatMap { now.diskWritten >= $0.diskWritten ? now.diskWritten - $0.diskWritten : nil }
            return (key, now.footprint, before.map { Int64(now.footprint) - Int64($0.footprint) }, cpu, energy, read, written)
        }
        var keep = Set(all.sorted { $0.footprint > $1.footprint }.prefix(Self.topByMemory).map(\.0))
        keep.formUnion(all.filter { ($0.cpu ?? 0) >= 1 }.sorted { $0.cpu! > $1.cpu! }.prefix(Self.topByCPU).map(\.0))
        keep.formUnion(all.filter { ($0.energy ?? 0) > 0 }.sorted { $0.energy! > $1.energy! }.prefix(Self.topByEnergy).map(\.0))
        keep.formUnion(all.filter { ($0.written ?? 0) > 0 }.sorted { $0.written! > $1.written! }.prefix(Self.topByDiskWrites).map(\.0))
        keep.formUnion(all.filter { abs($0.change ?? Int64($0.footprint)) >= Self.processChange }.map(\.0))
        // Names and wall-clock start times only for the listed processes.
        let processes = all.filter { keep.contains($0.0) }.compactMap { key, footprint, change, cpu, energy, read, written -> ProcessSample? in
            guard let (name, startedAt) = Self.identity(key.pid) else { return nil }
            return ProcessSample(pid: key.pid, name: name, startedAt: startedAt, footprint: footprint, footprintChange: change, cpu: cpu,
                                 energy: energy, diskRead: read, diskWritten: written)
        }
        baseline = (started, at, memory.used, memory.pressure, usage, systemOn)
        var sample = ResourceSample(interval: interval, heartbeat: heartbeat, memoryTotal: memory.total, memoryUsed: memory.used,
                              compressed: memory.compressed, swapUsed: memory.swap, pressure: memory.pressure,
                              processes: processes.sorted { $0.footprint > $1.footprint },
                              readable: usage.count, unreadable: unreadable,
                              tookMilliseconds: Int((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1_000_000))
        if let reading {
            sample.system = tracker.take(at: at)
            onCheck?(reading, check, sample)
        }
        return sample
    }

    /// `proc_pid_rusage` fails with EPERM for processes owned by another user.
    static func readUsage() -> (usage: [Key: Usage], unreadable: Int) {
        var pids = [Int32](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        var usage: [Key: Usage] = [:]
        usage.reserveCapacity(max(count, 0))
        var unreadable = 0
        var info = rusage_info_v6()
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard rc == 0 else {
                unreadable += 1
                continue
            }
            // rusage times are in mach absolute time units.
            let cpu = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
            usage[Key(pid: pid, start: info.ri_proc_start_abstime)] = (info.ri_phys_footprint, cpu, info.ri_energy_nj, info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
        }
        return (usage, unreadable)
    }

    /// The executable's file name (the BSD name is cut at 31 characters) and the wall-clock start time.
    static func identity(_ pid: Int32) -> (name: String, startedAt: Date)? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let name = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
            ? (String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) as NSString).lastPathComponent
            : withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (name, Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6))
    }

    static func systemMemory() -> (total: UInt64, used: UInt64, compressed: UInt64, swap: UInt64, pressure: MemoryPressure)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        // sys/kern_memorystatus.h: 1 normal, 2 warn, 4 critical.
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let compressed = UInt64(stats.compressor_page_count) * page
        return (total, (appPages + UInt64(stats.wire_count)) * page + compressed, compressed, swap.xsu_used,
                level >= 4 ? .critical : level == 2 ? .warn : .normal)
    }
}
