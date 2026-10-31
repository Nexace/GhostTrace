import Foundation

/// A time-window listing. Gap events overlapping the window are always included, whatever `kind` is.
public struct EventQuery: Codable, Sendable, Equatable {
    public static let maxLimit = 1000

    public var from: Date
    public var to: Date
    public var kind: EventKind?
    public var limit: Int
    /// `nextCursor` from the previous page.
    public var cursor: String?
    /// Pages newest first, so a capped listing keeps the most recent events. Optional so older clients' queries still decode.
    public var newestFirst: Bool?

    public init(from: Date, to: Date, kind: EventKind? = nil, limit: Int = 200, cursor: String? = nil, newestFirst: Bool? = nil) {
        self.from = from
        self.to = to
        self.kind = kind
        self.limit = limit
        self.cursor = cursor
        self.newestFirst = newestFirst
    }

    /// Position after which the page starts: (occurredAt milliseconds, insertion sequence).
    public var parsedCursor: (occurredAt: Int64, seq: Int64)? {
        guard let parts = cursor?.split(separator: "."), parts.count == 2,
              let occurredAt = Int64(parts[0]), let seq = Int64(parts[1]) else { return nil }
        return (occurredAt, seq)
    }

    public static func cursor(occurredAt: Int64, seq: Int64) -> String { "\(occurredAt).\(seq)" }
}

public struct EventPage: Codable, Sendable, Equatable {
    /// Ordered by `occurredAt`, then by insertion order (reversed for `newestFirst`).
    public var events: [Event]
    /// Present when more events match; pass it back as `EventQuery.cursor`.
    public var nextCursor: String?
    /// Earliest event still stored. Nothing before it can be reported.
    public var retainedSince: Date?

    public init(events: [Event], nextCursor: String?, retainedSince: Date?) {
        self.events = events
        self.nextCursor = nextCursor
        self.retainedSince = retainedSince
    }
}
