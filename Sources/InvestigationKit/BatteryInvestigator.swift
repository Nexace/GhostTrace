// Explains battery drain from `resource_sample` events: time on battery, sleep drain, and which of your processes used the energy.
import Foundation
import RecorderCore

/// A stretch on battery, from its first sample to its last.
public struct BatterySession: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var startCharge: Int
    public var endCharge: Int
    /// Charge points per hour of wall time, asleep included.
    public var drainPerHour: Double
    /// Time-weighted battery power over the stretches that were sampled awake.
    public var averageWatts: Double?
    public var asleepSeconds: TimeInterval
    /// Charge points lost between each sleep and its wake. Nil if nothing slept or the charge wasn't read around it.
    public var asleepDrop: Int?
    /// The answer in one plain sentence. Findings hold the evidence.
    public var summary: String
    public var findings: [Finding]
}

public struct BatteryInvestigation: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var sessions: [BatterySession]
    public var limits: [Limit]
    /// Every cited event, oldest first.
    public var evidence: [Event]
    /// False when no sample in the window carries battery state.
    public var hasBattery: Bool
}

public enum BatteryInvestigator {
    public static let maxWindow: TimeInterval = 48 * 3600
    /// A process is the likely cause only above this share of battery energy.
    static let likelyShare = 0.5
    static let maxUsers = 3
    static let maxCorrelates = 5

    /// `events` should hold the window's resource samples, sleeps, wakes, dark-wake log entries, app launches and gaps.
    public static func investigate(from: Date, to: Date, events: [Event], recordingSince: Date?) -> BatteryInvestigation {
        let samples = ResourceAnalyzer.decode(events, from: from, to: to)
        guard samples.contains(where: { $0.sample.system?.onBattery != nil }) else {
            return BatteryInvestigation(from: from, to: to, sessions: [],
                                        limits: (samples.isEmpty ? ResourceAnalyzer.coverageLimits(samples, gaps: [], events: events, from: from, to: to, recordingSince: recordingSince)
                                            : [Limit(statement: "This Mac has no battery, or GhostTrace couldn't read it.", evidence: [])])
                                            + ResourceAnalyzer.systemOffLimits(events, from: from, to: to),
                                        evidence: [], hasBattery: false)
        }
        var naps: [Nap] = []
        var asleepSince: Event?
        for event in events.filter({ $0.kind == .sleep || $0.kind == .wake }).sorted(by: { $0.occurredAt < $1.occurredAt }) {
            // A dark wake can post a second sleep without a wake in between: the nap began at the first.
            if event.kind == .sleep { asleepSince = asleepSince ?? event } else if let sleep = asleepSince { naps.append(Nap(sleep: sleep, wake: event)); asleepSince = nil }
        }
        // A session is a run of samples on battery. The first sample of a run says nothing about the run: its averages cover the time before.
        // A hole in recording that no sleep explains ends the run: the Mac may have been plugged in meanwhile. A nap excuses only the time it covers.
        var runs: [[ResourceAnalyzer.Timed]] = [[]]
        var limits: [Limit] = []
        var reported = Set<UUID>()
        for s in samples {
            guard s.sample.system?.onBattery == true, s.sample.system?.charge != nil else {
                if !runs[runs.count - 1].isEmpty { runs.append([]) }
                continue
            }
            if let prev = runs[runs.count - 1].last {
                // Sampling stopped if the awake time between the samples, not counting naps, is a gap.
                let unsampled = ResourceAnalyzer.isGap(prev, (s.at.addingTimeInterval(-asleep(naps, from: prev.at, to: s.at)), s.event, s.sample))
                let holes = recordingHoles(events, naps: naps, from: prev.at, to: s.at)
                if unsampled {
                    limits.append(Limit(statement: "Sampling stopped for \(ResourceAnalyzer.duration(s.at.timeIntervalSince(prev.at))) while on battery, so the time before and after is reported separately and the charge lost in between isn't attributed.",
                                        evidence: [prev.event.id, s.event.id]))
                }
                // An off span splits the run like any hole; its own limit is added once for the window.
                for hole in holes where reported.insert(hole.id).inserted && hole.payload["reason"] != GapReason.systemMonitorOff.rawValue {
                    limits.append(Limit(statement: "GhostTrace wasn't recording for part of the time on battery (\(hole.payload["reason"] ?? "gap")), so the time before and after is reported separately and the drain in between wasn't measured.",
                                        evidence: [hole.id]))
                }
                if unsampled || !holes.isEmpty { runs.append([]) }
            }
            runs[runs.count - 1].append(s)
        }
        var sessions: [BatterySession] = []
        var energy = (battery: 0.0, processes: 0.0)
        for run in runs where run.count >= 2 {
            let result = session(run, naps: naps, events: events, reported: reported)
            sessions.append(result.session)
            limits += result.limits
            energy.battery += result.energy.battery
            energy.processes += result.energy.processes
        }
        if sessions.isEmpty {
            limits.append(Limit(statement: "The Mac wasn't on battery in this window, or only one sample was stored while it was.", evidence: []))
        }
        limits += ResourceAnalyzer.systemOffLimits(events, from: from, to: to)
        if energy.battery > 0 {
            let statement = energy.processes > 0 ? "Your measured processes account for at least \(Int(min(energy.processes / energy.battery, 1) * 100 + 1e-9))% of battery power."
                : "None of your processes' energy was measured, so the main cause is unknown."
            limits.insert(Limit(statement: statement, evidence: []), at: 0)
        }
        let cited = Set(sessions.flatMap { $0.findings.flatMap(\.evidence) } + limits.flatMap(\.evidence))
        return BatteryInvestigation(from: from, to: to, sessions: sessions, limits: limits,
                                    evidence: events.filter { cited.contains($0.id) }.sorted { $0.occurredAt < $1.occurredAt }, hasBattery: true)
    }

    /// Recorder gaps that leave a hole in the record between `from` and `to`. A missed power log import or a dropped watch doesn't.
    /// Each gap is first cut down to its pieces outside `naps` (a nap covers sleep through wake, ends included), so a gap fully inside a nap
    /// leaves nothing. A piece [start, end] belongs to the interval when start < to and either end > from, or the piece is a single point at
    /// or after from. So a piece starting at a sample time is after that sample, one ending at a sample time is before it, and a point gap at
    /// a sample time belongs to the interval starting there. A gap spanning samples overlaps several intervals, so callers report it once by id.
    private static func recordingHoles(_ events: [Event], naps: [Nap], from: Date, to: Date) -> [Event] {
        events.filter { gap in
            guard gap.kind == .eventGap, ![GapReason.powerLogHole.rawValue, GapReason.watchDropped.rawValue].contains(gap.payload["reason"] ?? "") else { return false }
            var pieces = [(start: gap.occurredAt, end: gap.endedAt ?? gap.occurredAt)]
            for nap in naps {
                let (sleep, wake) = (nap.sleep.occurredAt, nap.wake.occurredAt)
                pieces = pieces.flatMap { p in
                    p.end < sleep || p.start > wake ? [p] : [(start: p.start, end: sleep), (start: wake, end: p.end)].filter { $0.start < $0.end }
                }
            }
            return pieces.contains { $0.start < to && ($0.end > from || ($0.start == $0.end && $0.start >= from)) }
        }
    }

    /// Seconds of `naps` between `from` and `to`.
    private static func asleep(_ naps: [Nap], from: Date, to: Date) -> TimeInterval {
        naps.map { max(0, min($0.wake.occurredAt, to).timeIntervalSince(max($0.sleep.occurredAt, from))) }.reduce(0, +)
    }

    private struct Nap {
        var sleep: Event
        var wake: Event
        var length: TimeInterval { wake.occurredAt.timeIntervalSince(sleep.occurredAt) }
    }

    private static func session(_ run: [ResourceAnalyzer.Timed], naps allNaps: [Nap], events: [Event], reported: Set<UUID>)
        -> (session: BatterySession, limits: [Limit], energy: (battery: Double, processes: Double)) {
        let (first, last) = (run.first!, run.last!)
        let (startCharge, endCharge) = (first.sample.system!.charge!, last.sample.system!.charge!)
        let hours = last.at.timeIntervalSince(first.at) / 3600
        let drain = max(0, Double(startCharge - endCharge)) / hours
        let span = ResourceAnalyzer.duration(last.at.timeIntervalSince(first.at))
        let naps = allNaps.filter { $0.sleep.occurredAt > first.at && $0.wake.occurredAt < last.at }
        var limits: [Limit] = []

        // Energy over the spans between consecutive samples that were awake and uninterrupted.
        var batteryJoules = 0.0, seconds = 0.0
        var users: [String: (name: String, joules: Double, cited: [UUID])] = [:]
        for (before, after) in zip(run, run.dropFirst()) {
            let length = after.at.timeIntervalSince(before.at)
            // A run has no unexplained holes, so this skips every span with a nap in it: what used power while asleep isn't measured.
            if asleep(allNaps, from: before.at, to: after.at) > 0 { continue }
            guard let watts = after.sample.system?.watts else { continue }
            batteryJoules += watts * length
            seconds += length
            for p in after.sample.processes {
                guard let power = p.energy else { continue }
                var user = users[p.key] ?? (p.name, 0, [])
                user.joules += power * length
                user.cited.append(after.event.id)
                users[p.key] = user
            }
        }
        // Holes that split sessions are reported by the caller; one inside a sleep is still a limit here.
        for gap in recordingHoles(events, naps: [], from: first.at, to: last.at) where !reported.contains(gap.id) && gap.payload["reason"] != GapReason.systemMonitorOff.rawValue {
            limits.append(Limit(statement: "GhostTrace wasn't recording for part of this battery session (\(gap.payload["reason"] ?? "gap")), so the drain there wasn't measured.", evidence: [gap.id]))
        }
        let ranked = users.values.filter { $0.joules > 0 }.sorted { ($0.joules, $1.name) > ($1.joules, $0.name) }
        let share = { (joules: Double) in Int((joules / batteryJoules * 100).rounded()) }

        var findings = [Finding(confidence: .observed,
                                statement: "Battery drained \(number(drain))% per hour (from \(startCharge)% to \(endCharge)% over \(span)).",
                                basis: "The charge macOS reported at the first and last sample of this stretch on battery. What happened between samples wasn't measured.",
                                evidence: [first.event.id, last.event.id])]
        if batteryJoules > 0 {
            for (index, user) in ranked.prefix(maxUsers).enumerated() {
                findings.append(Finding(confidence: .observed,
                                        statement: index == 0 ? "\(user.name) used the most energy among your processes (\(share(user.joules))% of battery power)."
                                            : "\(user.name) used \(share(user.joules))% of battery power.",
                                        basis: "Its own energy use as macOS reports it (proc_pid_rusage), compared with the battery's measured power over the same samples. Battery power is sampled at each check and a process's energy is an average, so the comparison is approximate.",
                                        evidence: [first.event.id] + user.cited))
            }
        }
        var summary = "Drained \(number(drain))% per hour"
        // A 0 W reading leaves no battery power to share (and dividing by it would trap).
        if batteryJoules > 0, let top = ranked.first, top.joules > likelyShare * batteryJoules {
            findings.append(Finding(confidence: .likely,
                                    statement: "\(top.name) likely caused most of the drain: it accounted for \(share(top.joules))% of battery power.",
                                    basis: "GhostTrace's comparison of one process's measured energy with the battery's. macOS doesn't attribute the display, storage or radios to processes, so this is an estimate. Battery power is sampled at each check and a process's energy is an average, so the comparison is approximate.",
                                    evidence: [first.event.id] + top.cited))
            summary += ". Likely cause: \(top.name)."
        } else {
            findings.append(Finding(confidence: .unknown,
                                    statement: "The main cause of the drain is unknown.",
                                    basis: batteryJoules == 0 ? "Battery power wasn't measured in this stretch."
                                        : ranked.isEmpty ? "No measured process used energy." : "No single process accounts for more than half of battery power.",
                                    evidence: [first.event.id, last.event.id]))
            summary += "; the main cause is unknown."
        }

        var asleepDrop: Int?
        var darkWakes: [(event: Event, into: TimeInterval)] = []
        for nap in naps {
            guard let before = run.last(where: { $0.at <= nap.sleep.occurredAt }), let after = run.first(where: { $0.at >= nap.wake.occurredAt }) else { continue }
            let drop = max(0, before.sample.system!.charge! - after.sample.system!.charge!)
            asleepDrop = (asleepDrop ?? 0) + drop
            findings.append(Finding(confidence: .observed,
                                    statement: "While asleep for \(ResourceAnalyzer.duration(nap.length)) the charge dropped \(drop) points (from \(before.sample.system!.charge!)% to \(after.sample.system!.charge!)%).",
                                    basis: "The charge in the samples just before the sleep and just after the wake, with macOS's sleep and wake notifications between them.",
                                    evidence: [before.event.id, nap.sleep.id, nap.wake.id, after.event.id]))
            findings.append(Finding(confidence: .unknown,
                                    statement: "What drained the battery while asleep is unknown.",
                                    basis: "macOS doesn't report what used power while the Mac slept.",
                                    evidence: [nap.sleep.id, nap.wake.id]))
            darkWakes += events.filter { $0.kind == .diagnostic && $0.payload["entry"] == "dark_wake" && $0.occurredAt >= nap.sleep.occurredAt && $0.occurredAt <= nap.wake.occurredAt }
                .map { ($0, $0.occurredAt.timeIntervalSince(nap.sleep.occurredAt)) }
        }
        for dark in darkWakes.prefix(maxCorrelates) {
            findings.append(Finding(confidence: .correlated,
                                    statement: "A dark wake happened \(ResourceAnalyzer.duration(dark.into)) into a sleep.",
                                    basis: "Close in time only. Dark wakes are short background wakes with the screen off; the drop can't be tied to them.",
                                    evidence: [dark.event.id]))
        }
        if darkWakes.count > maxCorrelates {
            limits.append(Limit(statement: "\(darkWakes.count - maxCorrelates) more dark wakes during sleep aren't listed.", evidence: []))
        }

        let named = Set(ranked.prefix(maxUsers).map(\.name))
        let launches = events.filter { $0.kind == .appLaunch && $0.occurredAt > first.at && $0.occurredAt <= last.at && !named.contains($0.subject?.name ?? "") }
        for launch in launches.prefix(maxCorrelates) {
            findings.append(Finding(confidence: .correlated,
                                    statement: "\(launch.subject?.name ?? launch.subject?.bundleID ?? "An app") launched during this stretch on battery.",
                                    basis: "Close in time only. It isn't among the biggest measured energy users, so the timing isn't evidence it drained the battery.",
                                    evidence: [launch.id]))
        }
        if launches.count > maxCorrelates {
            limits.append(Limit(statement: "\(launches.count - maxCorrelates) more app launches during this battery session aren't listed.", evidence: []))
        }
        let result = BatterySession(from: first.at, to: last.at, startCharge: startCharge, endCharge: endCharge, drainPerHour: drain,
                                    averageWatts: seconds > 0 ? batteryJoules / seconds : nil, asleepSeconds: naps.map(\.length).reduce(0, +), asleepDrop: asleepDrop,
                                    summary: summary, findings: findings)
        return (result, limits, (batteryJoules, ranked.map(\.joules).reduce(0, +)))
    }

    /// `15`, `7.5`.
    private static func number(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? "\(Int(tenths))" : String(format: "%.1f", tenths)
    }
}
