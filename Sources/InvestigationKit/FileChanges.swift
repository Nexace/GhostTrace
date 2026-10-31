// File-change investigations over FSEvents records. FSEvents never names the writer, so no finding ever does.
import Foundation
import RecorderCore

/// A user-selected path the recorder watches, and since when.
public struct WatchedPath: Codable, Sendable, Equatable {
    public var path: String
    public var since: Date

    public init(path: String, since: Date) {
        self.path = path
        self.since = Date(roundingToMilliseconds: since)
    }

    public func covers(_ other: String) -> Bool { other == path || other.hasPrefix(path == "/" ? "/" : path + "/") }
}

public struct FileChange: Codable, Sendable, Equatable {
    public var at: Date
    /// Set for a change read back from FSEvents' history: it happened at some point from `at` to here.
    public var endedAt: Date?
    public var path: String
    /// FSEvents flag names, accumulated over the grouped records.
    public var changes: [String]
    public var summary: String
    public var findings: [Finding]
}

public struct FileChangeInvestigation: Codable, Sendable, Equatable {
    public var path: String
    public var from: Date
    public var to: Date
    /// The watched path that covers `path`, if any.
    public var watchedBy: WatchedPath?
    public var changes: [FileChange]
    public var limits: [Limit]
    /// Every cited event, oldest first.
    public var evidence: [Event]
}

public enum FileChangeInvestigator {
    public static let maxWindow: TimeInterval = 30 * 86400
    static let maxChanges = 50
    /// Records for the same path this close together are one change: an atomic save arrives as several in one FSEvents delivery.
    static let groupWithin: TimeInterval = 0.5
    public static let launchLookback: TimeInterval = 120
    static let maxCorrelates = 3

    /// `path` must be canonical (as the recorder stores it). `events` should hold the window's file changes, app launches and gaps.
    public static func investigate(path: String, from: Date, to: Date, events: [Event], watches: [WatchedPath]) -> FileChangeInvestigation {
        // Replayed changes are intervals, so overlap counts.
        let records = events.filter { $0.kind == .fileChange && $0.occurredAt <= to && ($0.endedAt ?? $0.occurredAt) >= from }
        let matching = records.filter { $0.subject?.path.map(WatchedPath(path: path, since: from).covers) ?? false }
        var groups: [[Event]] = []
        for record in matching {
            if let last = groups.last?.last, last.subject?.path == record.subject?.path, record.occurredAt.timeIntervalSince(last.occurredAt) <= groupWithin {
                groups[groups.count - 1].append(record)
            } else {
                groups.append([record])
            }
        }
        let byID = Dictionary(records.compactMap { r in r.payload["fsevent_id"].flatMap(UInt64.init).map { ($0, r) } }) { first, _ in first }
        let changes = groups.suffix(maxChanges).map { change($0, byID: byID, events: events) }

        let watch = watches.filter { $0.covers(path) }.max { $0.path.count < $1.path.count }
        var limits: [Limit] = []
        if let watch {
            if watch.since > from {
                limits.append(Limit(statement: "\(watch.path) has been watched only since the watch was added, so earlier changes weren't recorded.", evidence: []))
            }
        } else {
            limits.append(Limit(statement: "\(path) isn't in a watched folder, so GhostTrace doesn't record changes to it. Watch it with: ghosttrace watch add FOLDER", evidence: []))
        }
        if groups.count > maxChanges {
            limits.append(Limit(statement: "\(groups.count - maxChanges) earlier changes aren't listed. Use a shorter window.", evidence: []))
        }
        let gaps = events.filter { $0.kind == .eventGap && $0.occurredAt <= to && ($0.endedAt ?? $0.occurredAt) >= from
            && ![GapReason.powerLogHole.rawValue, GapReason.systemMonitorOff.rawValue].contains($0.payload["reason"] ?? "") }
        for gap in gaps.suffix(5) {
            let reason = gap.payload["reason"] ?? "gap"
            let statement = switch reason {
            case GapReason.watchDropped.rawValue: "Some file changes were dropped (by FSEvents, or by GhostTrace's rate limit), so changes then may be missing."
            case GapReason.recorderStopped.rawValue, GapReason.recorderInterrupted.rawValue:
                "GhostTrace wasn't running for part of this window (\(reason)). Changes then are listed only if FSEvents' history still had them when it restarted, and without exact times."
            default: "GhostTrace wasn't recording for part of this window (\(reason)), so changes then are missing."
            }
            limits.append(Limit(statement: statement, evidence: [gap.id]))
        }
        if gaps.count > 5 { limits.append(Limit(statement: "\(gaps.count - 5) more recording gaps in this window aren't listed.", evidence: [])) }
        limits.append(Limit(statement: "FSEvents batches changes: saves within about a second appear as one change, timed when GhostTrace received it.", evidence: []))

        let cited = Set(changes.flatMap { $0.findings.flatMap(\.evidence) } + limits.flatMap(\.evidence))
        return FileChangeInvestigation(path: path, from: from, to: to, watchedBy: watch, changes: changes, limits: limits,
                                       evidence: events.filter { cited.contains($0.id) }.sorted { $0.occurredAt < $1.occurredAt })
    }

    private static func change(_ group: [Event], byID: [UInt64: Event], events: [Event]) -> FileChange {
        let first = group[0]
        let path = first.subject?.path ?? "?"
        var names: [String] = []
        for record in group {
            for name in (record.payload["changes"] ?? "").split(separator: ",").map(String.init) where !names.contains(name) { names.append(name) }
        }
        let flagList = names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
        if first.payload["replayed"] == "true", let end = first.endedAt {
            // Read back from FSEvents' history: no time, no rename pairing, no nearby launches.
            let span = "between \(GhostTraceJSON.string(from: first.occurredAt)) and \(GhostTraceJSON.string(from: end))"
            return FileChange(at: first.occurredAt, endedAt: end, path: path, changes: names,
                              summary: "Changed while GhostTrace wasn't running, \(span). Which process changed it is unknown.",
                              findings: [Finding(confidence: .observed, statement: "FSEvents' history shows a change to \(path)\(flagList) \(span), while GhostTrace wasn't running.",
                                                 basis: "Read back from FSEvents' history when the recorder started again. The history keeps which items changed, not when or how often.",
                                                 evidence: group.map(\.id)),
                                         Finding(confidence: .unknown, statement: "Which process made this change is unknown.",
                                                 basis: "FSEvents doesn't record the writer. Only Endpoint Security could, and GhostTrace doesn't use it.",
                                                 evidence: [first.id])])
        }
        var findings = [Finding(confidence: .observed,
                                statement: "FSEvents reported a change to \(path)\(flagList).",
                                basis: "Recorded by macOS's file system events. Its flags can include earlier changes to the same item, so they don't say exactly what this change was.",
                                evidence: group.map(\.id))]
        var summary = "Changed. Which process changed it is unknown."
        // A rename arrives as two records with consecutive ids, old path first (seen on macOS 27).
        for record in group where (record.payload["changes"] ?? "").contains("renamed") {
            guard let id = record.payload["fsevent_id"].flatMap(UInt64.init) else { continue }
            let partners = [(id &- 1, true), (id &+ 1, false)].compactMap { candidate, isOld in
                byID[candidate].flatMap { other in
                    other.subject?.path != path && (other.payload["changes"] ?? "").contains("renamed") ? (other, isOld) : nil
                }
            }
            guard let (partner, isOld) = partners.first, let other = partner.subject?.path else { continue }
            findings.append(Finding(confidence: .likely, statement: isOld ? "It was renamed (or moved) from \(other)." : "It was renamed (or moved) to \(other).",
                                    basis: "FSEvents reports a rename as two records with consecutive ids, the old path first. Pairing them is GhostTrace's reading.",
                                    evidence: [record.id, partner.id]))
            summary = isOld ? "Renamed from \(other). Which process did it is unknown." : "Renamed to \(other). Which process did it is unknown."
            break
        }
        findings.append(Finding(confidence: .unknown, statement: "Which process made this change is unknown.",
                                basis: "FSEvents doesn't record the writer. Only Endpoint Security could, and GhostTrace doesn't use it.",
                                evidence: [first.id]))
        let launches = events.filter { $0.kind == .appLaunch && $0.occurredAt <= first.occurredAt && $0.occurredAt >= first.occurredAt.addingTimeInterval(-launchLookback) }
        for launch in launches.suffix(maxCorrelates) {
            findings.append(Finding(confidence: .correlated,
                                    statement: "\(launch.subject?.name ?? launch.subject?.bundleID ?? "An app") launched \(WakeInvestigator.seconds(first.occurredAt.timeIntervalSince(launch.occurredAt))) before the change.",
                                    basis: "Close in time only. It doesn't show that this app changed the file.",
                                    evidence: [launch.id]))
        }
        return FileChange(at: first.occurredAt, path: path, changes: names, summary: summary, findings: findings)
    }
}
