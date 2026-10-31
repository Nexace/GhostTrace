// Deterministic investigations over recorded events. No statement is made without citing the events it rests on.
import Foundation
import RecorderCore

/// How strongly the cited evidence supports a statement.
public enum Confidence: String, Codable, Sendable, CaseIterable {
    /// macOS recorded it directly, such as powerd's own wake reason.
    case observed
    /// GhostTrace's interpretation of the cited evidence. macOS does not state it.
    case likely
    /// Close in time only. Not evidence of cause.
    case correlated
    /// The recorded evidence can't answer it.
    case unknown
}

public struct Finding: Codable, Sendable, Equatable {
    public var confidence: Confidence
    public var statement: String
    /// Why this confidence and not a higher one.
    public var basis: String
    public var evidence: [UUID]
}

/// Something GhostTrace could not see that bears on the answer.
public struct Limit: Codable, Sendable, Equatable {
    public var statement: String
    public var evidence: [UUID]

    public init(statement: String, evidence: [UUID]) {
        self.statement = statement
        self.evidence = evidence
    }
}

public enum WakeType: String, Codable, Sendable {
    /// Display on.
    case full
    /// Display off, typically for maintenance.
    case dark
    case darkToFull = "dark_to_full"
    /// Only a wake notification was recorded, with no power log entry.
    case unknown
}

extension WakeType {
    /// Plain wording for people, shared by the CLI and the app.
    public var title: String {
        switch self {
        case .full, .unknown: "Woke up"
        case .dark: "Dark wake (screen stayed off)"
        case .darkToFull: "Screen came on during a dark wake"
        }
    }
}

public struct WakeIncident: Codable, Sendable, Equatable {
    public var at: Date
    public var type: WakeType
    /// The answer in one plain sentence, e.g. "Likely cause: the lid was opened." Findings hold the evidence.
    public var summary: String
    /// Ranked: what macOS recorded, then interpretations, then open questions, then mere correlates.
    public var findings: [Finding]
    public var limits: [Limit]
}

public struct WakeInvestigation: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var wakes: [WakeIncident]
    public var limits: [Limit]
    public var recordingSince: Date?
    public var powerLogSince: Date?
    public var powerLogThrough: Date?
    /// Every cited event, oldest first, so each claim can be checked without another query.
    public var evidence: [Event]

    /// The limits that bear on the short answers, once each: recorder gaps (they cite a gap event) and coverage.
    /// The other per-wake limits are context, shown with the full findings.
    public var keyLimits: [String] {
        var seen = Set<String>()
        return (wakes.flatMap { $0.limits.filter { !$0.evidence.isEmpty } } + limits).map(\.statement).filter { seen.insert($0).inserted }
    }
}

/// What the event sources could have seen.
public struct Coverage: Sendable {
    /// Earliest recorder lifecycle marker. NSWorkspace events can't exist before it.
    public var recordingSince: Date?
    /// First power log line seen by any import.
    public var powerLogSince: Date?
    /// Last successful power log import. Later lines aren't stored yet.
    public var powerLogThrough: Date?
    /// Why the power log wasn't read for this investigation, if it wasn't.
    public var powerLogError: String?

    public init(recordingSince: Date?, powerLogSince: Date?, powerLogThrough: Date?, powerLogError: String?) {
        self.recordingSince = recordingSince
        self.powerLogSince = powerLogSince
        self.powerLogThrough = powerLogThrough
        self.powerLogError = powerLogError
    }
}

public enum WakeInvestigator {
    public static let maxWindow: TimeInterval = 2 * 86400
    /// Fetch events from this long before the window, to find the wake requests logged at the previous sleep.
    public static let lookback: TimeInterval = 86400
    /// Fetch events this long after the window, for activity right after a wake.
    public static let followUp: TimeInterval = 120
    /// NSWorkspace's notification minus powerd's line time. Lines have whole seconds; a live wake measured +0.27 s.
    static let notificationDelay: ClosedRange<TimeInterval> = -2...10
    static let requestTolerance: TimeInterval = 5
    static let maxCorrelates = 5

    static let wakeTypes: [String: WakeType] = ["wake": .full, "dark_wake": .dark, "dark_to_full_wake": .darkToFull]

    /// `events` should span `from - lookback` to `to + followUp`.
    public static func investigate(from: Date, to: Date, events: [Event], coverage: Coverage) -> WakeInvestigation {
        let logged = events.filter { $0.kind == .diagnostic && wakeTypes[$0.payload["entry"] ?? ""] != nil }
        var notificationFor: [UUID: Event] = [:]
        var unmatched: [Event] = []
        // Each notification goes to the nearest power log wake, so a dark wake followed by a full wake seconds later pairs correctly.
        for note in events where note.kind == .wake {
            let delay = { (log: Event) in note.occurredAt.timeIntervalSince(log.occurredAt) }
            let nearest = logged.filter { notificationDelay.contains(delay($0)) }.min { abs(delay($0)) < abs(delay($1)) }
            if let nearest, notificationFor[nearest.id] == nil { notificationFor[nearest.id] = note } else { unmatched.append(note) }
        }
        let inWindow = { (event: Event) in event.occurredAt >= from && event.occurredAt <= to }
        let incidents = (logged.filter(inWindow).map { ($0.occurredAt, Optional($0), notificationFor[$0.id]) }
            + unmatched.filter(inWindow).map { ($0.occurredAt, nil, Optional($0)) }).sorted { $0.0 < $1.0 }
        let wakes = incidents.map { incident(at: $0.0, log: $0.1, note: $0.2, events: events, coverage: coverage) }

        var limits: [Limit] = []
        if let error = coverage.powerLogError {
            limits.append(Limit(statement: "The power log wasn't read for this investigation (\(error)). Only entries imported earlier are used.", evidence: []))
        }
        switch (coverage.powerLogSince, coverage.powerLogThrough) {
        case let (since?, through?):
            if since > from { limits.append(Limit(statement: "The power log starts after this window begins, so earlier wakes and their reasons can't be seen.", evidence: [])) }
            if through < to { limits.append(Limit(statement: "The power log was last imported before this window ends, so later wakes and their reasons can't be seen.", evidence: [])) }
        default:
            limits.append(Limit(statement: "No power log entries have been imported, so no wake reason can be checked.", evidence: []))
        }
        if coverage.recordingSince.map({ $0 > from }) ?? true {
            limits.append(Limit(statement: "GhostTrace started recording after this window begins. Wake notifications and app launches before that weren't recorded.", evidence: []))
        }

        let cited = Set(wakes.flatMap { $0.findings.flatMap(\.evidence) + $0.limits.flatMap(\.evidence) })
        return WakeInvestigation(from: from, to: to, wakes: wakes, limits: limits, recordingSince: coverage.recordingSince,
                                 powerLogSince: coverage.powerLogSince, powerLogThrough: coverage.powerLogThrough,
                                 evidence: events.filter { cited.contains($0.id) }.sorted { $0.occurredAt < $1.occurredAt })
    }

    private static func incident(at: Date, log: Event?, note: Event?, events: [Event], coverage: Coverage) -> WakeIncident {
        var findings: [Finding] = []
        var limits: [Limit] = []
        var summary = "Cause unknown: the power log has no entry for this wake."
        let type = log.flatMap { wakeTypes[$0.payload["entry"] ?? ""] } ?? .unknown

        if let log {
            let reason = log.payload["reason"] ?? ""
            let name = switch type { case .dark: "dark wake"; case .darkToFull: "switch from dark wake to full wake"; default: "wake" }
            findings.append(Finding(confidence: .observed,
                                    statement: "powerd logged a \(name) \"due to \(reason)\"." + (note.map { " macOS posted a wake notification \(seconds($0.occurredAt.timeIntervalSince(at))) later." } ?? ""),
                                    basis: "Written by macOS's power manager when the Mac woke (pmset -g log). This is the system's own wake reason.",
                                    evidence: [log.id] + (note.map { [$0.id] } ?? [])))
            findings += readings(of: reason, log: log)
            var causes = codes.filter { $0.matches(reason) }.map(\.short)
            if let timer = reason.firstMatch(of: /rtc\/(\S*)/) {
                let (requests, setBy) = scheduledRequests(at: at, timer: String(timer.1), log: log, events: events)
                findings += requests
                causes = causes.map { $0 == timerCause ? setBy : $0 }
            }
            summary = causes.isEmpty ? "Cause unknown: GhostTrace can't read powerd's reason code." : "Likely cause: \(causes.joined(separator: " and "))."
        } else if let note {
            findings.append(Finding(confidence: .observed, statement: "macOS posted a wake notification.",
                                    basis: "NSWorkspaceDidWakeNotification, recorded by GhostTrace when it arrived. It carries no wake reason.",
                                    evidence: [note.id]))
            let covered = coverage.powerLogSince.map { $0 <= at } == true && coverage.powerLogThrough.map { $0 >= at } == true
            findings.append(Finding(confidence: .unknown, statement: "The wake reason is unknown.",
                                    basis: covered ? "powerd logged no wake within seconds of this notification." : "The imported power log doesn't cover this time.",
                                    evidence: [note.id]))
        }

        let around = at.addingTimeInterval(-60)...at.addingTimeInterval(followUp)
        // Notifications and launches keep recording with the system monitor off.
        let gaps = events.filter { $0.kind == .eventGap && $0.occurredAt <= around.upperBound && ($0.endedAt ?? $0.occurredAt) >= around.lowerBound
            && $0.payload["reason"] != GapReason.systemMonitorOff.rawValue }
        for gap in gaps {
            limits.append(Limit(statement: "GhostTrace wasn't recording for part of the two minutes around this wake (\(gap.payload["reason"] ?? "gap")), so notifications and app launches then are missing.",
                                evidence: [gap.id]))
        }
        if log != nil, note == nil {
            if coverage.recordingSince.map({ $0 > at }) ?? true {
                limits.append(Limit(statement: "GhostTrace wasn't recording yet, so only the power log covers this wake.", evidence: []))
            } else if gaps.isEmpty {
                limits.append(Limit(statement: type == .dark
                    ? "macOS posted no wake notification. Dark wakes keep the display off, and macOS may not post one for them."
                    : "macOS posted no wake notification within 10 s, although GhostTrace was recording.", evidence: []))
            }
        }

        let launches = events.filter { $0.kind == .appLaunch && $0.occurredAt >= at && $0.occurredAt <= at.addingTimeInterval(followUp) }
        for launch in launches.prefix(maxCorrelates) {
            let name = launch.subject?.name ?? launch.subject?.bundleID ?? "An app"
            findings.append(Finding(confidence: .correlated,
                                    statement: "\(name) launched \(seconds(launch.occurredAt.timeIntervalSince(at))) after the wake.",
                                    basis: "It started after the wake, so the timing can't show that it caused the wake. It may be a result of the wake or a coincidence.",
                                    evidence: [launch.id]))
        }
        if launches.count > maxCorrelates {
            limits.append(Limit(statement: "\(launches.count - maxCorrelates) more app launches in the two minutes after this wake are not listed.", evidence: []))
        }
        return WakeIncident(at: at, type: type, summary: summary, findings: findings, limits: limits)
    }

    /// GhostTrace's readings of powerd's reason codes. Apple doesn't document them, so each reading is only `likely`.
    static let timerCause = "a scheduled timer"
    static let codes: [(meaning: String, short: String, matches: @Sendable (String) -> Bool)] = [
        ("The lid was opened.", "the lid opening", { $0.split(whereSeparator: { $0 == " " || $0 == "/" }).contains("lid") }),
        ("Keyboard, trackpad or other input from the user.", "keyboard or trackpad input",
         { r in ["RTP.keyboard", "RTP.multi-touch", "HID Activity", "UserActivity"].contains { r.contains($0) } }),
        ("Something was plugged into a USB-C port, such as a charger.", "something plugged into USB-C (such as a charger)",
         { $0.contains("USB-C_plug") || $0.contains("USBPlugEvent") }),
        ("The power adapter was disconnected.", "the charger being unplugged", { $0.contains("acdetach") }),
        ("A USB device signalled a wake.", "a USB device", { $0.contains("USB2_wake") || $0.contains("USBWakeup") }),
        ("Network activity (Wi-Fi or a kept-alive TCP connection).", "network activity", { r in ["ARPT", "wifibt", "E_TKO"].contains { r.contains($0) } }),
        ("A notification needed the display.", "a notification", { $0.split(separator: " ").contains("Notification") }),
        ("A scheduled wake timer fired.", timerCause, { $0.contains("rtc/") }),
    ]

    private static func readings(of reason: String, log: Event) -> [Finding] {
        let basis = "GhostTrace's reading of powerd's reason code. Apple doesn't document these codes, so this is an interpretation."
        let matched = codes.filter { $0.matches(reason) }
        guard !matched.isEmpty else {
            return [Finding(confidence: .unknown, statement: "GhostTrace can't interpret this wake reason.", basis: "It contains no code GhostTrace knows.", evidence: [log.id])]
        }
        return matched.map { Finding(confidence: .likely, statement: $0.meaning, basis: basis, evidence: [log.id]) }
    }

    /// A timer wake is matched to the requests powerd logged at the previous sleep that were due at the wake time.
    /// Also returns the cause for the summary, naming who set the timer when that is known.
    private static func scheduledRequests(at: Date, timer: String, log: Event, events: [Event]) -> ([Finding], String) {
        let unknownSetter = "\(timerCause) (what set it is unknown)"
        let requests = events.filter { $0.kind == .diagnostic && $0.payload["entry"] == "wake_request" && $0.occurredAt < at }
        guard let lastSleep = requests.map(\.occurredAt).max() else {
            return ([Finding(confidence: .unknown, statement: "No wake requests were logged in the day before this timer wake, so what scheduled it is unknown.",
                            basis: "powerd lists pending wake requests each time the Mac sleeps; none were imported for this period.", evidence: [log.id])], unknownSetter)
        }
        let due = { (request: Event) in request.payload["wake_at"].flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) } }
        let pending = requests.filter { $0.occurredAt == lastSleep }
        let matches = pending.compactMap { request in due(request).map { (request, abs($0.timeIntervalSince(at))) } }
            .filter { $0.1 <= requestTolerance }.sorted { $0.1 < $1.1 }
        guard !matches.isEmpty else {
            return ([Finding(confidence: .unknown, statement: "A timer (\(timer)) woke the Mac, but none of the \(pending.count) wake requests logged at the previous sleep was due at this time.",
                            basis: "Requests made after that sleep, or by the hardware, aren't in the power log.", evidence: [log.id] + pending.map(\.id))], unknownSetter)
        }
        let alternatives = matches.count > 1 ? " Another request was due at the same time, so either could be the one." : ""
        let setBy = "a timer set by " + matches.map { "\($0.0.payload["process"] ?? "a process") (\($0.0.payload["request"] ?? "request"))" }.joined(separator: " or ")
        return (matches.map { request, offset in
            let p = request.payload
            return Finding(confidence: .likely,
                           statement: "\(p["process"] ?? "A process") had requested a wake for this time (\(p["request"] ?? "request")\(p["info"].map { ", \"\($0)\"" } ?? "")).",
                           basis: "The reason names a timer, and this request, logged when the Mac went to sleep, was due \(seconds(offset)) from the wake. powerd doesn't log which request fired." + alternatives,
                           evidence: [log.id, request.id])
        }, setBy)
    }

    /// Power log lines have whole seconds, so offsets from a logged wake are good to about a second.
    static func seconds(_ interval: TimeInterval) -> String {
        abs(interval) < 1 ? "less than a second" : "about \(Int(interval.rounded())) s"
    }
}
