// Free-space drops and write bursts from resource samples, which of your processes wrote, and file changes in watched folders at the time.
import Foundation
import RecorderCore

/// A run of samples where free space fell 1 GB or the disk was busy.
public struct DiskIncident: Codable, Sendable, Equatable {
    /// The last sample before the incident (its bytes begin there), and the last sample in it.
    public var from: Date
    public var to: Date
    public var freeSpaceBefore: UInt64?
    public var freeSpaceAfter: UInt64?
    /// Bytes the whole system wrote.
    public var written: UInt64
    /// The answer in one plain sentence. Findings hold the evidence.
    public var summary: String
    public var findings: [Finding]
}

public struct DiskInvestigation: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var incidents: [DiskIncident]
    public var limits: [Limit]
    /// Every cited event, oldest first.
    public var evidence: [Event]
}

public enum DiskInvestigator {
    public static let maxWindow: TimeInterval = 48 * 3600
    /// Same values as `ActivityTracker.busyRate` and `freeSpaceDrop`, which this module can't import.
    static let busyRate: UInt64 = 10 << 20
    static let freeSpaceDrop: UInt64 = 1 << 30
    static let maxIncidents = 20
    static let maxWriters = 3
    static let maxCited = 10

    /// `events` should hold the window's resource samples, file changes and gaps. `watches` are the watched folders.
    public static func investigate(from: Date, to: Date, events: [Event], watches: [WatchedPath], recordingSince: Date?) -> DiskInvestigation {
        let samples = ResourceAnalyzer.decode(events, from: from, to: to)
        let previous = { (i: Int) in i > 0 && !ResourceAnalyzer.isGap(samples[i - 1], samples[i]) ? samples[i - 1] : nil }
        var runs: [Range<Int>] = []
        for i in samples.indices where isIncident(samples[i].sample, after: previous(i)?.sample) {
            if let last = runs.last, last.upperBound == i, previous(i) != nil {
                runs[runs.count - 1] = last.lowerBound..<i + 1
            } else {
                runs.append(i..<i + 1)
            }
        }
        let changes = events.filter { $0.kind == .fileChange }.sorted { $0.occurredAt < $1.occurredAt }
        var coverage = (system: UInt64(0), processes: UInt64(0))
        var readHeavy = 0
        // Read-heavy bursts go before the cap so they never take a slot from a real incident.
        let all = runs.compactMap { run -> (incident: DiskIncident, processWrites: UInt64)? in
            let result = incident(samples[run], previous: previous(run.lowerBound), changes: changes, watches: watches)
            if result == nil { readHeavy += 1 }
            return result
        }
        let incidents = all.suffix(maxIncidents).map { result in
            coverage.system += result.incident.written
            coverage.processes += result.processWrites
            return result.incident
        }

        var limits = ResourceAnalyzer.windowLimits(samples, spans: incidents.map { ($0.from, $0.to) }, noun: "disk incident", events: events, from: from, to: to, recordingSince: recordingSince)
        if all.count > maxIncidents {
            limits.insert(Limit(statement: "\(all.count - maxIncidents) earlier disk incidents in this window aren't listed. Use a shorter window.", evidence: []), at: 0)
        }
        if coverage.system > 0 {
            limits.insert(Limit(statement: "Your measured processes account for at least \(Int(min(Double(coverage.processes) / Double(coverage.system), 1) * 100 + 1e-9))% of what the system wrote.", evidence: []), at: 0)
        }
        if readHeavy > 0 {
            limits.append(Limit(statement: "\(readHeavy) read-heavy burst\(readHeavy == 1 ? " was" : "s were") left out: GhostTrace can't separate read and write rates.", evidence: []))
        }
        if !incidents.isEmpty {
            limits.append(Limit(statement: "Only your own processes' writes are measured, and only while they run: system daemons (Spotlight, Time Machine, kernel_task) and processes that exited between checks aren't.", evidence: []))
        }
        if incidents.contains(where: { drop($0) != nil }) {
            limits.append(Limit(statement: "APFS snapshots, purgeable space and cache eviction change free space without writes, and GhostTrace can't see them. A drop with few bytes written may come from these.", evidence: []))
        }
        let cited = Set(incidents.flatMap { $0.findings.flatMap(\.evidence) } + limits.flatMap(\.evidence))
        return DiskInvestigation(from: from, to: to, incidents: incidents, limits: limits,
                                 evidence: events.filter { cited.contains($0.id) }.sorted { $0.occurredAt < $1.occurredAt })
    }

    static func isIncident(_ sample: ResourceSample, after previous: ResourceSample?) -> Bool {
        guard let system = sample.system else { return false }
        if (system.diskPeakRate ?? 0) >= busyRate { return true }
        guard let before = previous?.system?.freeSpace, let after = system.freeSpace else { return false }
        return before > after && before - after >= freeSpaceDrop
    }

    private static func drop(_ incident: DiskIncident) -> UInt64? {
        guard let before = incident.freeSpaceBefore, let after = incident.freeSpaceAfter, before > after, before - after >= freeSpaceDrop else { return nil }
        return before - after
    }

    private static func incident(_ run: ArraySlice<ResourceAnalyzer.Timed>, previous: ResourceAnalyzer.Timed?, changes: [Event], watches: [WatchedPath])
        -> (incident: DiskIncident, processWrites: UInt64)? {
        let (first, last) = (previous ?? run.first!, run.last!)
        let written = run.reduce(0) { $0 + ($1.sample.system?.diskWritten ?? 0) }
        let read = run.reduce(0) { $0 + ($1.sample.system?.diskRead ?? 0) }
        let peak = run.compactMap { $0.sample.system?.diskPeakRate }.max() ?? 0
        // Without the sample before, the run's first bytes began at a sample outside the window (or across a gap): no starting point is known.
        let span = previous == nil ? "since the sample before" : "in " + ResourceAnalyzer.duration(last.at.timeIntervalSince(first.at))
        let ends = first.event.id == last.event.id ? [last.event.id] : [first.event.id, last.event.id]
        var result = DiskIncident(from: first.at, to: last.at, freeSpaceBefore: previous?.sample.system?.freeSpace, freeSpaceAfter: last.sample.system?.freeSpace,
                                  written: written, summary: "", findings: [])
        let fell = drop(result)
        // The busy rate counts reads and writes, so a burst of mostly reads says nothing about writing. A free-space drop is kept.
        if fell == nil, read > written { return nil }
        if let fell {
            result.findings.append(Finding(confidence: .observed,
                                           statement: "Free space fell \(ResourceSample.fileBytes(fell)) (from \(ResourceSample.fileBytes(result.freeSpaceBefore!)) to \(ResourceSample.fileBytes(result.freeSpaceAfter!))) \(span).",
                                           basis: "The startup volume's available capacity as macOS reported it in the samples before and after.",
                                           evidence: ends))
        }
        result.findings.append(Finding(confidence: .observed,
                                       statement: "The system wrote \(ResourceSample.fileBytes(written)) to disk \(span), with checks at up to \(ResourceSample.fileBytes(peak))/s of reads and writes.",
                                       basis: "Disk byte counters from macOS (IOBlockStorageDriver statistics), summed over the stored samples. What happened between checks isn't known."
                                           + (run.contains { $0.sample.system?.countersReset == true } ? " A counter reset during this incident, so the total may be too low." : ""),
                                       evidence: run.map(\.event.id)))

        var writers: [String: (name: String, pid: Int32, bytes: UInt64, cited: [UUID])] = [:]
        for s in run {
            for p in s.sample.processes {
                guard let bytes = p.diskWritten, bytes > 0 else { continue }
                var writer = writers[p.key] ?? (p.name, p.pid, 0, [])
                writer.bytes += bytes
                writer.cited.append(s.event.id)
                writers[p.key] = writer
            }
        }
        let ranked = writers.values.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
        let share = { (bytes: UInt64) in written > 0 ? min(Int((Double(bytes) / Double(written) * 100).rounded()), 100) : 0 }
        for (index, writer) in ranked.prefix(maxWriters).enumerated() {
            result.findings.append(Finding(confidence: .observed,
                                           statement: (index == 0 ? "\(writer.name) (pid \(writer.pid)) wrote the most among your processes: " : "\(writer.name) (pid \(writer.pid)) wrote ")
                                               + "\(ResourceSample.fileBytes(writer.bytes)) (\(share(writer.bytes))% of system writes).",
                                           basis: "Its own disk writes as macOS reports them (proc_pid_rusage), compared with the system's counters over the same samples.",
                                           evidence: writer.cited))
        }
        // Writes that can't cover half the drop don't explain it, whoever made them.
        let fewWrites = fell.map { written * 2 < $0 } ?? false
        var summary = fell.map { "Free space fell \(ResourceSample.fileBytes($0)); \(ResourceSample.fileBytes(written)) written" } ?? "\(ResourceSample.fileBytes(written)) written at up to \(ResourceSample.fileBytes(peak))/s"
        if fewWrites {
            result.findings.append(Finding(confidence: .unknown,
                                           statement: "Only \(ResourceSample.fileBytes(written)) was written while free space fell \(ResourceSample.fileBytes(fell!)), so writes don't explain the drop.",
                                           basis: "APFS snapshots, purgeable space and cache eviction change free space without writes, and macOS doesn't report which one did.",
                                           evidence: ends))
            summary += "; where the space went is unknown."
        } else if let top = ranked.first, written > 0, top.bytes * 2 > written {
            result.findings.append(Finding(confidence: .likely,
                                           statement: "\(top.name) likely caused most of this: it wrote \(share(top.bytes))% of what the system wrote.",
                                           basis: "GhostTrace's comparison of one process's writes with the system's. The system's counters include other volumes' traffic and the process's include writes later deleted, so this is an estimate.",
                                           evidence: top.cited))
            summary += ". Likely cause: \(top.name)."
        } else {
            result.findings.append(Finding(confidence: .unknown,
                                           statement: "Which process wrote most of this is unknown.",
                                           basis: ranked.isEmpty ? "None of your measured processes wrote in these samples." : "No single measured process wrote more than half of it.",
                                           evidence: ends))
            summary += "; the process is unknown."
        }

        // Replayed changes are intervals, so overlap counts.
        let during = changes.filter { $0.occurredAt <= last.at && ($0.endedAt ?? $0.occurredAt) >= first.at }
        let byWatch = Dictionary(grouping: during) { change in
            watches.filter { watch in change.subject?.path.map(watch.covers) ?? false }.max { $0.path.count < $1.path.count }?.path
        }
        for (folder, records) in byWatch.compactMap({ key, value in key.map { ($0, value) } }).sorted(by: { $0.0 < $1.0 }) {
            result.findings.append(Finding(confidence: .correlated,
                                           statement: "\(records.count) file change\(records.count == 1 ? " was" : "s were") recorded in the watched folder \(folder) during this.",
                                           basis: "Close in time only. FSEvents says which files changed, not how much they wrote or which process wrote them."
                                               + (records.count > maxCited ? " The first \(maxCited) are cited." : ""),
                                           evidence: records.prefix(maxCited).map(\.id)))
        }
        if fell != nil, byWatch.keys.allSatisfy({ $0 == nil }) {
            result.findings.append(Finding(confidence: .unknown,
                                           statement: "Where the space went is unknown.",
                                           basis: "No watched folder recorded a change during the drop, and GhostTrace records file changes only in watched folders.",
                                           evidence: ends))
        }
        result.summary = summary
        return (result, ranked.reduce(0) { $0 + $1.bytes })
    }
}
