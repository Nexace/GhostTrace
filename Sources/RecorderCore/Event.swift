import CryptoKit
import Foundation

public enum EventKind: String, Codable, Sendable, CaseIterable {
    case appLaunch = "app_launch"
    case appExit = "app_exit"
    case sleep
    case wake
    case resourceSample = "resource_sample"
    case fileChange = "file_change"
    case diagnostic
    case collectorStatus = "collector_status"
    case eventGap = "event_gap"
    case alert
}

public enum PrivacyClass: String, Codable, Sendable {
    case normal, sensitive
}

public enum EventQuality: String, Codable, Sendable {
    case directlyObserved = "directly_observed"
    case sampled, inferred, imported
}

/// What an event is about. PIDs are reused, so `startedAt` (when known) is part of a process's identity.
public struct Subject: Codable, Sendable, Equatable {
    public var pid: Int32?
    public var bundleID: String?
    public var name: String?
    public var path: String?
    public var startedAt: Date?

    public init(pid: Int32? = nil, bundleID: String? = nil, name: String? = nil, path: String? = nil, startedAt: Date? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.startedAt = startedAt.map(Date.init(roundingToMilliseconds:))
    }
}

public struct Event: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var occurredAt: Date
    /// End of an interval event such as `event_gap`; nil for point events.
    public var endedAt: Date?
    public var recordedAt: Date
    /// Taken when recorded, not when the event occurred. Counts through sleep; comparable only within one boot session.
    public var monotonicNanos: UInt64?
    public var bootSessionID: String?
    public var kind: EventKind
    /// Collector and API, e.g. `app-lifecycle/NSWorkspaceDidLaunchApplicationNotification`.
    public var source: String
    public var subject: Subject?
    /// String values only. Structured data rides as JSON under one key, as `ResourceSample` does.
    public var payload: [String: String]
    public var privacyClass: PrivacyClass
    public var quality: EventQuality
    public var provenance: String?

    /// `occurredAt` defaults to the recording time.
    public init(id: UUID = UUID(), kind: EventKind, source: String, occurredAt: Date? = nil, endedAt: Date? = nil,
                subject: Subject? = nil, payload: [String: String] = [:], quality: EventQuality = .directlyObserved,
                privacyClass: PrivacyClass = .normal, provenance: String? = nil, clock: RecorderClock) {
        let now = Date(roundingToMilliseconds: clock.now())
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.occurredAt = occurredAt.map(Date.init(roundingToMilliseconds:)) ?? now
        self.endedAt = endedAt.map(Date.init(roundingToMilliseconds:))
        self.recordedAt = now
        self.monotonicNanos = clock.monotonicNanos()
        self.bootSessionID = clock.bootSessionID
        self.kind = kind
        self.source = source
        self.subject = subject
        self.payload = payload
        self.privacyClass = privacyClass
        self.quality = quality
        self.provenance = provenance
    }
}

/// Injectable time source so tests can fix the clock and simulate reboots.
public struct RecorderClock: Sendable {
    public var now: @Sendable () -> Date
    public var monotonicNanos: @Sendable () -> UInt64?
    public var bootSessionID: String?

    public init(now: @escaping @Sendable () -> Date, monotonicNanos: @escaping @Sendable () -> UInt64? = { nil }, bootSessionID: String? = nil) {
        self.now = now
        self.monotonicNanos = monotonicNanos
        self.bootSessionID = bootSessionID
    }

    // time.h: CLOCK_MONOTONIC_RAW keeps counting while asleep and ignores clock adjustments.
    public static let live = RecorderClock(now: { Date() }, monotonicNanos: { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) },
                                           bootSessionID: liveBootSessionID())
}

// `sysctl kern.bootsessionuuid`: changes on every boot.
private func liveBootSessionID() -> String? {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
}

extension Date {
    /// Events keep millisecond precision so SQLite columns and JSON agree exactly.
    public init(milliseconds: Int64) { self.init(timeIntervalSince1970: Double(milliseconds) / 1000) }
    public init(roundingToMilliseconds date: Date) { self.init(milliseconds: date.milliseconds) }
    public var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

/// The one JSON format for storage, IPC and `--json` output: camelCase keys, UTC ISO 8601 timestamps with milliseconds.
public enum GhostTraceJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = try? fractional.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a UTC ISO 8601 timestamp with milliseconds, got \(text)")
            }
            return Date(roundingToMilliseconds: date)
        }
        return decoder
    }

    /// e.g. `2026-10-26T21:30:00.123Z`. Built by hand because the format style truncates (not rounds) fractions.
    public static func string(from date: Date) -> String {
        let (seconds, millis) = date.milliseconds.quotientAndRemainder(dividingBy: 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601)
        return whole.dropLast() + String(format: ".%03ldZ", Int(millis))
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

extension Event {
    /// For export: paths become `redacted-` plus a short hash, so the same path still links across events without naming it.
    /// Covers a sensitive event's subject path and any `path` payload value.
    public func redacted() -> Event {
        var copy = self
        if privacyClass == .sensitive, let path = subject?.path { copy.subject?.path = Self.redact(path) }
        if let path = payload["path"] { copy.payload["path"] = Self.redact(path) }
        return copy
    }

    static func redact(_ text: String) -> String {
        "redacted-" + SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
