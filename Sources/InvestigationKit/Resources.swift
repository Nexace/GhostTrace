// Resource summaries for charts and `ghosttrace memory`, and the memory-spike investigator. Inputs are `resource_sample` events.
import Foundation
import RecorderCore

/// One chart point: the samples that fell in [start, end).
public struct ResourcePoint: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var samples: Int
    public var memoryUsedAverage: UInt64
    public var memoryUsedPeak: UInt64
    /// The worst level seen in the bucket.
    public var pressure: MemoryPressure
    public var swapUsedPeak: UInt64
    /// From `ResourceSample.system`; nil when no sample in the bucket has it (stored before Phase 6, or the system wouldn't say).
    /// CPU is a fraction 0...1, GPU a percent, rates bytes/s: the bucket's bytes over the time those samples spanned.
    public var cpuBusyAverage: Double?
    public var cpuPeak: Double?
    public var gpuAverage: Int?
    public var gpuPeak: Int?
    public var networkRate: UInt64?
    public var networkPeakRate: UInt64?
    public var diskRate: UInt64?
    public var diskPeakRate: UInt64?
    /// The latest in the bucket.
    public var charge: Int?
    public var freeSpace: UInt64?
    public var onBattery: Bool?
}

/// One process across a window. Only the samples it appeared in are known.
public struct ProcessUsage: Codable, Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var startedAt: Date?
    public var peakFootprint: UInt64
    public var peakAt: Date
    public var latestFootprint: UInt64
    public var latestAt: Date
    public var peakCPU: Double?
    /// Samples it appeared in (a process is sampled only while among the largest or busiest).
    public var samples: Int
}

public struct ResourceSummary: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var sampleCount: Int
    public var memoryTotal: UInt64?
    /// Downsampled for charts; empty buckets are left out, so a missing stretch shows as a break.
    public var points: [ResourcePoint]
    /// Ranked by peak memory.
    public var top: [ProcessUsage]
    /// Stretches with no sample, longer than 2.5 sampling intervals.
    public var samplingGaps: [DateInterval]
    public var limits: [Limit]

    /// Each point weighted by its duration, so busy stretches with more stored samples don't dominate; nil when no point has the metric.
    public func average(_ value: (ResourcePoint) -> Double?) -> Double? {
        let known = points.compactMap { p in value(p).map { ($0, p.end.timeIntervalSince(p.start)) } }
        return known.isEmpty ? nil : known.map { $0 * $1 }.reduce(0, +) / known.map(\.1).reduce(0, +)
    }

    // Not `.map(Double.init)`: on a UInt64 that picks Double(bitPattern:), which turned 500 KB/s into 0.
    public func average<T: BinaryInteger>(_ key: KeyPath<ResourcePoint, T?>) -> Double? { average { $0[keyPath: key].map { Double($0) } } }
}

public enum ResourceAnalyzer {
    public static let maxWindow: TimeInterval = 7 * 86400
    public static let maxPoints = 500
    public static let maxTop = 50

    public static func summarize(from: Date, to: Date, events: [Event], points: Int = 60, top: Int = 10, recordingSince: Date?) -> ResourceSummary {
        let samples = decode(events, from: from, to: to)
        let width = to.timeIntervalSince(from) / Double(min(max(points, 1), maxPoints))
        // A sample's span is the time since the previous stored one. The first in the window has none, so its bytes aren't counted in rates.
        let spans = [nil] + zip(samples, samples.dropFirst()).map { Optional($1.at.timeIntervalSince($0.at)) }
        let buckets = Dictionary(grouping: samples.indices) { Int((samples[$0].at.timeIntervalSince(from) / width).rounded(.down)) }
        let chart = buckets.keys.sorted().map { index in
            let group = buckets[index]!.map { samples[$0] }
            let series = buckets[index]!.map { (samples[$0].sample.system, spans[$0]) }
            return ResourcePoint(start: from.addingTimeInterval(Double(index) * width), end: from.addingTimeInterval(Double(index + 1) * width),
                                 samples: group.count,
                                 memoryUsedAverage: group.map(\.sample.memoryUsed).reduce(0, +) / UInt64(group.count),
                                 memoryUsedPeak: group.map(\.sample.memoryUsed).max()!,
                                 pressure: group.map(\.sample.pressure).max()!, swapUsedPeak: group.map(\.sample.swapUsed).max()!,
                                 cpuBusyAverage: average(series.compactMap { $0.0?.cpuBusy }), cpuPeak: series.compactMap { $0.0?.cpuPeak }.max(),
                                 gpuAverage: average(series.compactMap { $0.0?.gpuUtilization.map(Double.init) }).map { Int($0.rounded()) },
                                 gpuPeak: series.compactMap { $0.0?.gpuPeak }.max(),
                                 networkRate: rate(series) { sum($0.networkIn, $0.networkOut) }, networkPeakRate: series.compactMap { $0.0?.networkPeakRate }.max(),
                                 diskRate: rate(series) { sum($0.diskRead, $0.diskWritten) }, diskPeakRate: series.compactMap { $0.0?.diskPeakRate }.max(),
                                 charge: series.compactMap { $0.0?.charge }.last, freeSpace: series.compactMap { $0.0?.freeSpace }.last,
                                 onBattery: series.compactMap { $0.0?.onBattery }.last)
        }
        var usage: [String: ProcessUsage] = [:]
        for (at, _, sample) in samples {
            for p in sample.processes {
                var u = usage[p.key] ?? ProcessUsage(pid: p.pid, name: p.name, startedAt: p.startedAt, peakFootprint: 0, peakAt: at,
                                                     latestFootprint: 0, latestAt: at, peakCPU: nil, samples: 0)
                if p.footprint > u.peakFootprint { (u.peakFootprint, u.peakAt) = (p.footprint, at) }
                (u.latestFootprint, u.latestAt, u.samples) = (p.footprint, at, u.samples + 1)
                if let cpu = p.cpu { u.peakCPU = max(u.peakCPU ?? 0, cpu) }
                usage[p.key] = u
            }
        }
        let gaps = samplingGaps(samples, from: from, to: to)
        return ResourceSummary(from: from, to: to, sampleCount: samples.count, memoryTotal: samples.last?.sample.memoryTotal, points: chart,
                               top: Array(usage.values.sorted { $0.peakFootprint > $1.peakFootprint }.prefix(min(max(top, 1), maxTop))),
                               samplingGaps: gaps, limits: coverageLimits(samples, gaps: gaps, events: events, from: from, to: to, recordingSince: recordingSince))
    }

    private static func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }

    private static func sum(_ a: UInt64?, _ b: UInt64?) -> UInt64? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }

    /// The first sample in the window has no span, so its bytes are skipped; a `countersReset` sample's bytes already leave out the reset check, so it adds those bytes over its whole span.
    /// Summed bytes over the summed spans of the samples that reported bytes; nil if none did.
    private static func rate(_ series: [(SystemActivity?, TimeInterval?)], bytes: (SystemActivity) -> UInt64?) -> UInt64? {
        let counted = series.compactMap { system, span in span.flatMap { span in system.flatMap(bytes).map { ($0, span) } } }
        let seconds = counted.map(\.1).reduce(0, +)
        return seconds > 0 ? UInt64(Double(counted.map(\.0).reduce(0, +)) / seconds) : nil
    }

    typealias Timed = (at: Date, event: Event, sample: ResourceSample)

    static func decode(_ events: [Event], from: Date, to: Date) -> [Timed] {
        events.filter { $0.kind == .resourceSample && $0.occurredAt >= from && $0.occurredAt <= to }
            .compactMap { event in ResourceSample(event).map { (event.occurredAt, event, $0) } }
            .sorted { $0.at < $1.at }
    }

    /// Samples further apart than the heartbeat plus 1.5 checks weren't consecutive: something stopped sampling in between.
    /// Older samples have no heartbeat (every check was stored), which makes the limit 2.5 checks. The larger of the
    /// two samples' limits counts, so changing the interval doesn't look like a gap.
    static func isGap(_ a: Timed, _ b: Timed) -> Bool {
        let limit = { (s: ResourceSample) in (s.heartbeat ?? s.interval) + 1.5 * s.interval }
        return b.at.timeIntervalSince(a.at) > max(limit(a.sample), limit(b.sample))
    }

    static func samplingGaps(_ samples: [Timed], from: Date, to: Date) -> [DateInterval] {
        zip(samples, samples.dropFirst()).filter { isGap($0, $1) }.map { DateInterval(start: $0.at, end: $1.at) }
    }

    static func coverageLimits(_ samples: [Timed], gaps: [DateInterval], events: [Event], from: Date, to: Date, recordingSince: Date?) -> [Limit] {
        var limits: [Limit] = []
        if samples.isEmpty {
            limits.append(Limit(statement: recordingSince.map { $0 > to } ?? true
                                ? "GhostTrace wasn't recording yet, so there are no resource samples in this window."
                                : "There are no resource samples in this window. Sampling may have been paused or the recorder stopped.", evidence: []))
            return limits
        }
        if samples[0].at.timeIntervalSince(from) > (samples[0].sample.heartbeat ?? samples[0].sample.interval) + 1.5 * samples[0].sample.interval {
            limits.append(Limit(statement: "The first sample in this window is \(duration(samples[0].at.timeIntervalSince(from))) after it begins; nothing earlier was measured.", evidence: []))
        }
        if !gaps.isEmpty {
            limits.append(Limit(statement: "Sampling stopped \(gaps.count) time\(gaps.count == 1 ? "" : "s") in this window, for \(duration(gaps.map(\.duration).reduce(0, +))) in all (the Mac asleep, or GhostTrace paused or stopped). Nothing is known about those stretches.",
                                evidence: []))
        }
        let unreadable = samples.map(\.sample.unreadable).max() ?? 0
        if unreadable > 0 {
            limits.append(Limit(statement: "Only your own processes are measured. \(unreadable) others (system daemons such as WindowServer and kernel_task, and other users' processes) can't be read without privileges.", evidence: []))
        }
        let last = samples.last!.sample
        limits.append(Limit(statement: last.heartbeat == nil
                            ? "Samples are snapshots every \(duration(last.interval)). A spike shorter than that, between two samples, isn't seen."
                            : "Memory is checked every \(duration(last.interval)), and a sample is stored only when memory in use changes by \(ResourceSample.bytes(ResourceSample.storeOnSystemChange)), one process by \(ResourceSample.bytes(ResourceSample.storeOnProcessChange)), or the pressure level changes (and at least every \(duration(last.heartbeat!))). Smaller changes, and spikes shorter than one check, aren't stored.",
                            evidence: []))
        return limits
    }

    /// What the network and disk investigators couldn't see: no samples, sampling stops, recording that began late, and recorder gaps inside `spans`.
    static func windowLimits(_ samples: [Timed], spans: [(from: Date, to: Date)], noun: String, events: [Event], from: Date, to: Date, recordingSince: Date?) -> [Limit] {
        guard !samples.isEmpty else {
            return [Limit(statement: recordingSince.map { $0 > to } ?? true
                          ? "GhostTrace wasn't recording yet, so there are no resource samples in this window."
                          : "There are no resource samples in this window. Sampling may have been paused or the recorder stopped.", evidence: [])]
        }
        var limits: [Limit] = []
        let gaps = samplingGaps(samples, from: from, to: to)
        if !gaps.isEmpty {
            limits.append(Limit(statement: "Sampling stopped \(gaps.count) time\(gaps.count == 1 ? "" : "s") in this window, for \(duration(gaps.map(\.duration).reduce(0, +))) in all (the Mac asleep, or GhostTrace paused or stopped). Nothing is known about those stretches.", evidence: []))
        }
        if let recordingSince, recordingSince > from {
            limits.append(Limit(statement: "GhostTrace started recording after this window begins; nothing earlier was measured.", evidence: []))
        }
        for span in spans {
            for gap in events where gap.kind == .eventGap && gap.occurredAt <= span.to && (gap.endedAt ?? gap.occurredAt) >= span.from
                && ![GapReason.powerLogHole.rawValue, GapReason.watchDropped.rawValue, GapReason.systemMonitorOff.rawValue].contains(gap.payload["reason"] ?? "") {
                limits.append(Limit(statement: "GhostTrace wasn't recording for part of a \(noun) (\(gap.payload["reason"] ?? "gap")).", evidence: [gap.id]))
            }
        }
        return limits + systemOffLimits(events, from: from, to: to)
    }

    /// One limit per span in the window with "Record System Activity" off, for the battery, network and disk investigators.
    static func systemOffLimits(_ events: [Event], from: Date, to: Date) -> [Limit] {
        events.filter { $0.kind == .eventGap && $0.payload["reason"] == GapReason.systemMonitorOff.rawValue && $0.occurredAt <= to && ($0.endedAt ?? $0.occurredAt) >= from }
            .map { Limit(statement: "System recording was turned off from \(GhostTraceJSON.string(from: $0.occurredAt)) to \(GhostTraceJSON.string(from: $0.endedAt ?? $0.occurredAt)), so nothing was recorded then.",
                         evidence: [$0.id]) }
    }

    /// `45 s`, `12 min`, `3.5 h`.
    public static func duration(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<90: "\(Int(seconds.rounded())) s"
        case ..<5400: "\(Int((seconds / 60).rounded())) min"
        default: String(format: "%.1f h", seconds / 3600)
        }
    }
}

public struct MemorySpike: Codable, Sendable, Equatable {
    /// The last sample before the rise.
    public var from: Date
    /// The last sample of the rise.
    public var to: Date
    public var memoryBefore: UInt64
    public var memoryAfter: UInt64
    public var pressureBefore: MemoryPressure
    public var pressureAfter: MemoryPressure
    /// The answer in one plain sentence. Findings hold the evidence.
    public var summary: String
    public var findings: [Finding]
    public var limits: [Limit]
}

public struct MemoryInvestigation: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var memoryTotal: UInt64?
    public var sampleCount: Int
    public var spikes: [MemorySpike]
    public var samplingGaps: [DateInterval]
    public var limits: [Limit]
    /// Every cited event, oldest first.
    public var evidence: [Event]
}

public enum MemoryInvestigator {
    public static let maxWindow: TimeInterval = 2 * 86400
    /// A rise in memory used of at least this share of RAM (and at least 1 GB) between two samples is a spike.
    static let systemRiseShare = 0.1
    static let systemRiseFloor: Int64 = 1 << 30
    /// So is one process growing by this much.
    static let processRise: Int64 = 1 << 30
    /// Growth smaller than this isn't listed as a contributor.
    static let contributorFloor: Int64 = 100 << 20
    static let maxSpikes = 20
    static let maxContributors = 5
    static let maxCorrelates = 5

    /// `events` should hold the window's resource samples, app launches and gaps.
    public static func investigate(from: Date, to: Date, events: [Event], recordingSince: Date?) -> MemoryInvestigation {
        let samples = ResourceAnalyzer.decode(events, from: from, to: to)
        let gaps = ResourceAnalyzer.samplingGaps(samples, from: from, to: to)
        let rising = zip(samples.indices, samples.indices.dropFirst()).filter { i, j in
            !ResourceAnalyzer.isGap(samples[i], samples[j]) && isRise(samples[i], samples[j])
        }
        // Consecutive rising pairs form one spike: (first calm sample, last rising sample).
        var runs: [(Int, Int)] = []
        for (i, j) in rising {
            if let last = runs.last, last.1 == i { runs[runs.count - 1].1 = j } else { runs.append((i, j)) }
        }
        let spikes = runs.suffix(maxSpikes).map { spike(samples[$0.0...$0.1], events: events) }
        var limits = ResourceAnalyzer.coverageLimits(samples, gaps: gaps, events: events, from: from, to: to, recordingSince: recordingSince)
        if runs.count > maxSpikes {
            limits.insert(Limit(statement: "\(runs.count - maxSpikes) earlier spikes in this window aren't listed. Use a shorter window.", evidence: []), at: 0)
        }
        let cited = Set(spikes.flatMap { $0.findings.flatMap(\.evidence) + $0.limits.flatMap(\.evidence) })
        return MemoryInvestigation(from: from, to: to, memoryTotal: samples.last?.sample.memoryTotal, sampleCount: samples.count, spikes: spikes,
                                   samplingGaps: gaps, limits: limits,
                                   evidence: events.filter { cited.contains($0.id) }.sorted { $0.occurredAt < $1.occurredAt })
    }

    static func isRise(_ a: ResourceAnalyzer.Timed, _ b: ResourceAnalyzer.Timed) -> Bool {
        let threshold = max(systemRiseFloor, Int64(Double(b.sample.memoryTotal) * systemRiseShare))
        return b.sample.pressure > a.sample.pressure || Int64(b.sample.memoryUsed) - Int64(a.sample.memoryUsed) >= threshold
            || b.sample.processes.contains { growth($0, since: a.at) >= processRise }
    }

    /// Growth since the previous sample. A process started since then grew from nothing.
    static func growth(_ p: ProcessSample, since previous: Date) -> Int64 {
        p.footprintChange ?? (p.startedAt.map { $0 > previous } == true ? Int64(p.footprint) : 0)
    }

    private static func spike(_ run: ArraySlice<ResourceAnalyzer.Timed>, events: [Event]) -> MemorySpike {
        let (first, last) = (run.first!, run.last!)
        let after = run.dropFirst()
        let rise = Int64(last.sample.memoryUsed) - Int64(first.sample.memoryUsed)
        let span = ResourceAnalyzer.duration(last.at.timeIntervalSince(first.at))
        var findings = [Finding(confidence: .observed,
                                statement: "Memory in use went from \(ResourceSample.bytes(first.sample.memoryUsed)) to \(ResourceSample.bytes(last.sample.memoryUsed)) (of \(ResourceSample.bytes(last.sample.memoryTotal))) in \(span).",
                                basis: "Measured by macOS (host_statistics64) in samples taken \(span) apart. What happened between samples wasn't measured.",
                                evidence: [first.event.id, last.event.id])]
        if last.sample.pressure != first.sample.pressure {
            findings.append(Finding(confidence: .observed, statement: "macOS's memory pressure went from \(first.sample.pressure.rawValue) to \(last.sample.pressure.rawValue).",
                                    basis: "macOS's own pressure level (kern.memorystatus_vm_pressure_level), read at each sample.",
                                    evidence: [first.event.id, last.event.id]))
        }

        // Growth from the process's footprint just before the rise (its first appearance minus its change then) to its last appearance.
        var growth: [String: (process: ProcessSample, grew: Int64, isNew: Bool, cited: [UUID])] = [:]
        for (_, event, sample) in after {
            for p in sample.processes {
                if var known = growth[p.key] {
                    known.grew += Int64(p.footprint) - Int64(known.process.footprint)
                    known.process = p
                    known.cited.append(event.id)
                    growth[p.key] = known
                } else {
                    let isNew = p.startedAt.map { $0 > first.at } ?? false
                    growth[p.key] = (p, isNew ? Int64(p.footprint) : p.footprintChange ?? 0, isNew, [event.id])
                    // A process first seen later in the run grew before it was sampled; that earlier growth isn't known.
                }
            }
        }
        let contributors = growth.values.filter { $0.grew >= contributorFloor }.sorted { $0.grew > $1.grew }
        for c in contributors.prefix(maxContributors) {
            let name = "\(c.process.name) (pid \(c.process.pid))"
            findings.append(Finding(confidence: .observed,
                                    statement: c.isNew ? "\(name) started during the rise and reached \(ResourceSample.bytes(c.process.footprint))."
                                        : "\(name) grew by \(ResourceSample.bytes(c.grew)) to \(ResourceSample.bytes(c.process.footprint)).",
                                    basis: "Its own memory footprint as macOS reports it (proc_pid_rusage), compared across the samples.",
                                    evidence: [first.event.id] + c.cited))
        }
        var summary: String
        if let top = contributors.first, rise > 0, top.grew * 2 >= rise {
            let share = Int((Double(top.grew) / Double(rise) * 100).rounded())
            findings.append(Finding(confidence: .likely,
                                    statement: share >= 100
                                        ? "\(top.process.name) accounts for the rise: it grew by more than the system's total, so macOS likely compressed or freed other memory to make room."
                                        : "\(top.process.name) accounts for most of the rise (about \(share)% of it).",
                                    basis: "GhostTrace's comparison of one process's growth with the system's. macOS doesn't attribute shared, cached or kernel memory to processes, so this is an estimate.",
                                    evidence: [first.event.id] + top.cited))
            summary = "Likely cause: \(top.process.name), which grew by \(ResourceSample.bytes(top.grew))."
        } else {
            findings.append(Finding(confidence: .unknown,
                                    statement: "No sampled process accounts for most of this rise.",
                                    basis: "The growth may be in processes GhostTrace can't read (system daemons, other users), in the file cache or compressor, or spread across many processes.",
                                    evidence: [first.event.id, last.event.id]))
            summary = last.sample.pressure > first.sample.pressure ? "Memory pressure rose to \(last.sample.pressure.rawValue); the cause is unknown."
                : "Memory in use rose by \(ResourceSample.bytes(max(rise, 0))); the cause is unknown."
        }

        let named = Set(contributors.prefix(maxContributors).map(\.process.name))
        let launches = events.filter { $0.kind == .appLaunch && $0.occurredAt > first.at && $0.occurredAt <= last.at && !named.contains($0.subject?.name ?? "") }
        for launch in launches.prefix(maxCorrelates) {
            findings.append(Finding(confidence: .correlated,
                                    statement: "\(launch.subject?.name ?? launch.subject?.bundleID ?? "An app") launched during the rise.",
                                    basis: "Close in time only. Its own memory didn't grow enough to be listed, so the timing isn't evidence it caused the rise.",
                                    evidence: [launch.id]))
        }

        var limits: [Limit] = []
        let gaps = events.filter { $0.kind == .eventGap && $0.occurredAt <= last.at && ($0.endedAt ?? $0.occurredAt) >= first.at
            && ![GapReason.powerLogHole.rawValue, GapReason.watchDropped.rawValue, GapReason.systemMonitorOff.rawValue].contains($0.payload["reason"] ?? "") }
        for gap in gaps {
            limits.append(Limit(statement: "GhostTrace wasn't recording for part of this rise (\(gap.payload["reason"] ?? "gap")).", evidence: [gap.id]))
        }
        if launches.count > maxCorrelates {
            limits.append(Limit(statement: "\(launches.count - maxCorrelates) more app launches during the rise aren't listed.", evidence: []))
        }
        return MemorySpike(from: first.at, to: last.at, memoryBefore: first.sample.memoryUsed, memoryAfter: last.sample.memoryUsed,
                           pressureBefore: first.sample.pressure, pressureAfter: last.sample.pressure, summary: summary, findings: findings, limits: limits)
    }
}
