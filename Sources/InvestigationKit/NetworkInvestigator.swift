// Network spikes from resource samples, and the process behind each one from the recorder's `nettop` snapshots.
import Foundation
import RecorderCore

public struct NetworkSpike: Codable, Sendable, Equatable {
    /// The last sample before the spike (its bytes begin there), and the last busy sample.
    public var from: Date
    public var to: Date
    public var received: UInt64
    public var sent: UInt64
    /// The fastest single check, bytes/s.
    public var peakRate: UInt64
    /// The answer in one plain sentence. Findings hold the evidence.
    public var summary: String
    public var findings: [Finding]
}

public struct NetworkInvestigation: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var spikes: [NetworkSpike]
    public var limits: [Limit]
    /// Every cited event, oldest first.
    public var evidence: [Event]
}

public enum NetworkInvestigator {
    public static let maxWindow: TimeInterval = 48 * 3600
    /// Same value as `ActivityTracker.busyRate`, which this module can't import.
    static let busyRate: UInt64 = 10 << 20
    /// Samples further apart than this much traffic are a spike even if no single check was fast.
    static let spikeBytes: UInt64 = 100 << 20
    /// A snapshot is taken just after the check that saw the edge, so it can fall slightly outside the spike's samples.
    static let snapshotSlack: TimeInterval = 60
    /// Dark wakes last seconds to minutes; with no later sleep or wake logged, one is assumed over after this.
    public static let maxDarkWake: TimeInterval = 3600
    static let maxSpikes = 20
    static let maxContributors = 5
    static let nettopSource = "nettop"
    private static let powerEntries: Set<String> = ["sleep", "wake", "dark_wake", "dark_to_full_wake"]

    /// `events` should hold the window's resource samples, `nettop` snapshots and power log entries.
    public static func investigate(from: Date, to: Date, events: [Event], recordingSince: Date?) -> NetworkInvestigation {
        let samples = ResourceAnalyzer.decode(events, from: from, to: to)
        var runs: [Range<Int>] = []
        for i in samples.indices where isSpike(samples[i].sample) {
            if let last = runs.last, last.upperBound == i, !ResourceAnalyzer.isGap(samples[i - 1], samples[i]) {
                runs[runs.count - 1] = last.lowerBound..<i + 1
            } else {
                runs.append(i..<i + 1)
            }
        }
        let snapshots = events.filter { $0.kind == .diagnostic && $0.source == nettopSource }.sorted { $0.occurredAt < $1.occurredAt }
        let spikes = runs.suffix(maxSpikes).map { run in
            let previous = run.lowerBound > 0 && !ResourceAnalyzer.isGap(samples[run.lowerBound - 1], samples[run.lowerBound]) ? samples[run.lowerBound - 1] : nil
            return spike(samples[run], previous: previous, snapshots: snapshots, events: events)
        }

        var limits = ResourceAnalyzer.windowLimits(samples, spans: spikes.map { ($0.from, $0.to) }, noun: "spike", events: events, from: from, to: to, recordingSince: recordingSince)
        if runs.count > maxSpikes {
            limits.insert(Limit(statement: "\(runs.count - maxSpikes) earlier spikes in this window aren't listed. Use a shorter window.", evidence: []), at: 0)
        }
        if !spikes.isEmpty {
            limits.append(Limit(statement: "Per-process figures come from nettop, which counts only processes with recent connections, and what its counts include isn't documented. Snapshots are taken only when traffic crosses 10 MB/s and at most every 5 min.", evidence: []))
            var seen = Set<UUID>()
            for run in runs.suffix(maxSpikes) {
                let window = samples[run.lowerBound].at.addingTimeInterval(-snapshotSlack)...samples[run.upperBound - 1].at.addingTimeInterval(snapshotSlack)
                for failed in snapshots where window.contains(failed.occurredAt) && failed.payload["error"] != nil && seen.insert(failed.id).inserted {
                    limits.append(Limit(statement: "A nettop snapshot failed (\(failed.payload["error"] ?? "")), so the process behind this traffic may not be identifiable.", evidence: [failed.id]))
                }
            }
        }
        let cited = Set(spikes.flatMap { $0.findings.flatMap(\.evidence) } + limits.flatMap(\.evidence))
        return NetworkInvestigation(from: from, to: to, spikes: spikes, limits: limits,
                                    evidence: events.filter { cited.contains($0.id) }.sorted { $0.occurredAt < $1.occurredAt })
    }

    static func isSpike(_ sample: ResourceSample) -> Bool {
        guard let system = sample.system else { return false }
        return (system.networkPeakRate ?? 0) >= busyRate || (system.networkIn ?? 0) + (system.networkOut ?? 0) > spikeBytes
    }

    private struct Row: Decodable {
        var name: String
        var pid: Int32
        var received: UInt64
        var sent: UInt64
        var total: UInt64 { received + sent }
    }

    private static func spike(_ run: ArraySlice<ResourceAnalyzer.Timed>, previous: ResourceAnalyzer.Timed?, snapshots: [Event], events: [Event]) -> NetworkSpike {
        let (first, last) = (previous ?? run.first!, run.last!)
        let received = run.reduce(0) { $0 + ($1.sample.system?.networkIn ?? 0) }
        let sent = run.reduce(0) { $0 + ($1.sample.system?.networkOut ?? 0) }
        let peak = run.compactMap { $0.sample.system?.networkPeakRate }.max() ?? 0
        // Without the sample before, the spike's first bytes began at a sample outside the window (or across a gap): no starting point is known.
        let span = previous == nil ? "since the sample before" : "in " + ResourceAnalyzer.duration(last.at.timeIntervalSince(first.at))
        let ends = first.event.id == last.event.id ? [last.event.id] : [first.event.id, last.event.id]
        let moved = ResourceSample.fileBytes(received + sent)
        var findings = [Finding(confidence: .observed,
                                statement: "\(ResourceSample.fileBytes(received)) received and \(ResourceSample.fileBytes(sent)) sent \(span), at up to \(ResourceSample.fileBytes(peak))/s.",
                                basis: "Interface byte counters from macOS (sysctl NET_RT_IFLIST2), summed over the stored samples. What happened between checks 30 s apart isn't known." + (run.contains { $0.sample.system?.countersReset == true } ? " A counter reset during this spike, so the totals may be too low." : ""),
                                evidence: run.map(\.event.id))]

        let window = first.at.addingTimeInterval(-snapshotSlack)...last.at.addingTimeInterval(snapshotSlack)
        let inside = snapshots.filter { window.contains($0.occurredAt) }
        // The end must follow the start: an "ended" snapshot of the previous spike can fall in the window too.
        let begin = inside.first { $0.payload["edge"] == "started" }
        let end = inside.last { snapshot in snapshot.payload["edge"] == "ended" && begin.map { snapshot.occurredAt > $0.occurredAt } == true }
        let rows = { (event: Event?) -> [Row]? in event?.payload["entries"].flatMap { try? GhostTraceJSON.decoder().decode([Row].self, from: Data($0.utf8)) } }
        var summary = "\(moved) moved at up to \(ResourceSample.fileBytes(peak))/s; the process is unknown."
        if let begin, let end, let before = rows(begin), let after = rows(end) {
            let earlier = Dictionary(before.map { ("\($0.name)\u{0}\($0.pid)", $0.total) }, uniquingKeysWith: max)
            let growth = after.compactMap { row -> (row: Row, grew: UInt64)? in
                let was = earlier["\(row.name)\u{0}\(row.pid)"] ?? 0
                return row.total > was ? (row, row.total - was) : nil
            }.sorted { $0.grew > $1.grew }
            let total = growth.reduce(0) { $0 + $1.grew }
            let cited = [begin.id, end.id]
            for g in growth.prefix(maxContributors) {
                findings.append(Finding(confidence: .observed, statement: "\(g.row.name) (pid \(g.row.pid)) counted \(ResourceSample.fileBytes(g.grew)) more traffic between the two nettop snapshots.",
                                        basis: "nettop's per-process byte counts, compared between the snapshots taken when traffic rose and when it fell.", evidence: cited))
            }
            // The leader must account for over half the growth nettop saw (a tie names no one), and for a tenth of what the system counted.
            if let top = growth.first, top.grew * 2 > total, top.grew * 10 >= received + sent {
                findings.append(Finding(confidence: .likely, statement: "\(top.row.name) likely moved most of this traffic: its counters grew by \(ResourceSample.fileBytes(top.grew)) between the snapshots.",
                                        basis: "GhostTrace's comparison of one process's growth between two nettop snapshots. nettop counts only processes with recent connections and its counts are undocumented, so this is an estimate.",
                                        evidence: cited))
                summary = "Likely cause: \(top.row.name), whose network counters grew by \(ResourceSample.fileBytes(top.grew))."
            } else {
                findings.append(Finding(confidence: .unknown, statement: "No process accounts for most of this traffic.",
                                        basis: "The processes nettop counted grew by \(ResourceSample.fileBytes(total)) in all, against \(moved) at the interface: the traffic may be spread across processes or from ones nettop doesn't list.",
                                        evidence: cited))
            }
        } else {
            findings.append(Finding(confidence: .unknown, statement: "Which process caused this traffic is unknown.",
                                    basis: begin == nil || end == nil ? "GhostTrace needs a nettop snapshot from the start and from the end of the spike, and \(inside.isEmpty ? "none was" : "only one was") stored (snapshots run at most every 5 min)."
                                        : "A nettop snapshot from the start or the end of the spike failed.",
                                    evidence: inside.isEmpty ? ends : inside.map(\.id)))
        }

        let dark = events.filter { $0.kind == .diagnostic && $0.payload["entry"] == "dark_wake" }.filter { wake in
            let over = events.filter { $0.kind == .diagnostic && $0.occurredAt > wake.occurredAt && powerEntries.contains($0.payload["entry"] ?? "") }.map(\.occurredAt).min()
            return wake.occurredAt <= last.at && min(over ?? .distantFuture, wake.occurredAt.addingTimeInterval(maxDarkWake)) >= first.at
        }
        for wake in dark {
            findings.append(Finding(confidence: .correlated, statement: "This traffic happened during a dark wake (\(wake.payload["reason"] ?? "reason unknown")).",
                                    basis: "Close in time only. The Mac was awake with the screen off, which doesn't show that the wake and the traffic are related.", evidence: [wake.id]))
        }
        return NetworkSpike(from: first.at, to: last.at, received: received, sent: sent, peakRate: peak, summary: summary, findings: findings)
    }
}
