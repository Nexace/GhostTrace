import Foundation
import InvestigationKit
import RecorderCore

/// Versioned contract between the recorder and its clients (CLI, app): one JSON request line, one JSON response line.
/// Transports and access model: docs/adr/0002-recorder-ipc-and-storage.md (socket) and 0005 (XPC under launchd).
public enum IPC {
    public static let apiVersion = 1
    /// Bounds memory per connection. A full 1000-event page is well under this.
    public static let maxMessageBytes = 8 << 20
}

public struct Request: Codable, Sendable, Equatable {
    public enum Method: String, Codable, Sendable {
        case status, events, event, pause, resume
        case investigateWake = "investigate_wake"
        case resources
        /// One reading of the system now, stored nowhere. Clients compute rates from two answers.
        case live
        case investigateMemory = "investigate_memory"
        case investigateFileChange = "investigate_file_change"
        case investigateBattery = "investigate_battery"
        case investigateNetwork = "investigate_network"
        case investigateDisk = "investigate_disk"
        case watchAdd = "watch_add"
        case watchRemove = "watch_remove"
        case configure

        /// Changes nothing. MCP clients may call only these.
        public var isReadOnly: Bool {
            switch self {
            case .pause, .resume, .watchAdd, .watchRemove, .configure: false
            default: true
            }
        }
    }

    /// Who is asking, when it matters to the recorder. Unset for the CLI and the app.
    public enum Client: String, Codable, Sendable {
        /// The `ghosttrace mcp` adapter, answering an AI agent.
        case mcp
    }

    public var apiVersion = IPC.apiVersion
    public var method: Method
    public var query: EventQuery?
    public var eventID: UUID?
    /// For investigations and `resources`: at most the investigator's `maxWindow` long.
    public var window: DateInterval?
    /// For `investigate_file_change` and the watch methods: an absolute path.
    public var path: String?
    /// For `resources`: how many processes and chart points to return.
    public var top: Int?
    public var points: Int?
    /// For `configure`: seconds between resource samples.
    public var sampleInterval: Double?
    /// For `configure`: whether MCP clients may read the recording.
    public var mcpAccess: Bool?
    /// For `configure`: whether the system monitor (CPU, GPU, network, disk, battery, alerts) records.
    public var systemMonitor: Bool?
    public var client: Client?

    public init(method: Method, query: EventQuery? = nil, eventID: UUID? = nil, window: DateInterval? = nil, path: String? = nil,
                top: Int? = nil, points: Int? = nil, sampleInterval: Double? = nil, mcpAccess: Bool? = nil, systemMonitor: Bool? = nil,
                client: Client? = nil) {
        self.mcpAccess = mcpAccess
        self.systemMonitor = systemMonitor
        self.client = client
        self.method = method
        self.query = query
        self.eventID = eventID
        self.window = window
        self.path = path
        self.top = top
        self.points = points
        self.sampleInterval = sampleInterval
    }
}

extension Request {
    /// Why the recorder refuses this request, when it comes from an MCP client. The switch records the user's consent;
    /// the access boundary itself is same-team signing (ADR 0005, 0006).
    public func mcpRefusal(accessAllowed: Bool) -> ServiceError? {
        guard client == .mcp else { return nil }
        guard method.isReadOnly else { return ServiceError(.permissionDenied, "MCP clients can only read; '\(method.rawValue)' changes the recorder.") }
        guard accessAllowed else {
            return ServiceError(.permissionDenied, "AI agent access to GhostTrace is off. The user can allow it with: ghosttrace mcp allow (and revoke it with: ghosttrace mcp deny).")
        }
        return nil
    }
}

public struct Response: Codable, Sendable {
    public var apiVersion = IPC.apiVersion
    public var status: RecorderStatus?
    public var page: EventPage?
    public var event: Event?
    public var investigation: WakeInvestigation?
    public var resources: ResourceSummary?
    public var live: SystemReading?
    public var memoryInvestigation: MemoryInvestigation?
    public var fileChangeInvestigation: FileChangeInvestigation?
    public var batteryInvestigation: BatteryInvestigation?
    public var networkInvestigation: NetworkInvestigation?
    public var diskInvestigation: DiskInvestigation?
    public var error: ServiceError?

    public init(status: RecorderStatus? = nil, page: EventPage? = nil, event: Event? = nil, investigation: WakeInvestigation? = nil,
                resources: ResourceSummary? = nil, live: SystemReading? = nil, memoryInvestigation: MemoryInvestigation? = nil,
                fileChangeInvestigation: FileChangeInvestigation? = nil, batteryInvestigation: BatteryInvestigation? = nil,
                networkInvestigation: NetworkInvestigation? = nil, diskInvestigation: DiskInvestigation? = nil, error: ServiceError? = nil) {
        self.status = status
        self.page = page
        self.event = event
        self.investigation = investigation
        self.resources = resources
        self.live = live
        self.memoryInvestigation = memoryInvestigation
        self.fileChangeInvestigation = fileChangeInvestigation
        self.batteryInvestigation = batteryInvestigation
        self.networkInvestigation = networkInvestigation
        self.diskInvestigation = diskInvestigation
        self.error = error
    }

    public static func failure(_ code: ServiceError.Code, _ message: String) -> Response {
        Response(error: ServiceError(code, message))
    }
}

/// A stopped recorder cannot report itself: clients see `ServiceError.Code.recorderNotRunning` instead.
public enum RecorderState: String, Codable, Sendable {
    case running, paused
    /// Running, but at least one collector failed to start (for example, a missing permission).
    case permissionLimited = "permission_limited"
}

public struct RecorderStatus: Codable, Sendable, Equatable {
    public var state: RecorderState
    public var pid: Int32
    public var startedAt: Date
    public var pausedAt: Date?
    public var databasePath: String
    public var eventCount: Int
    public var retainedSince: Date?
    public var retentionDays: Int
    /// Events dropped by the bounded queue since the recorder started. Each drop span is also stored as an `event_gap`.
    public var droppedEvents: Int
    public var capabilities: [CapabilityStatus]
    /// Optional so clients still read a Phase 2 recorder's status.
    public var sampleInterval: Double?
    public var watchedPaths: [WatchedPath]?
    /// The database and its write-ahead log on disk. Optional, like the fields above, for older recorders.
    public var databaseBytes: Int64?
    public var schemaVersion: Int?
    /// Whether MCP clients may read the recording. Off until the user allows it; nil from older recorders.
    public var mcpAccess: Bool?
    /// Whether the system monitor records. On by default; nil from older recorders.
    public var systemMonitor: Bool?

    public init(state: RecorderState, pid: Int32, startedAt: Date, pausedAt: Date?, databasePath: String, eventCount: Int,
                retainedSince: Date?, retentionDays: Int, droppedEvents: Int, capabilities: [CapabilityStatus],
                sampleInterval: Double? = nil, watchedPaths: [WatchedPath]? = nil, databaseBytes: Int64? = nil, schemaVersion: Int? = nil, mcpAccess: Bool? = nil,
                systemMonitor: Bool? = nil) {
        self.mcpAccess = mcpAccess
        self.systemMonitor = systemMonitor
        self.sampleInterval = sampleInterval
        self.watchedPaths = watchedPaths
        self.databaseBytes = databaseBytes
        self.schemaVersion = schemaVersion
        self.state = state
        self.pid = pid
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.databasePath = databasePath
        self.eventCount = eventCount
        self.retainedSince = retainedSince
        self.retentionDays = retentionDays
        self.droppedEvents = droppedEvents
        self.capabilities = capabilities
    }
}

public struct ServiceError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case recorderNotRunning = "recorder_not_running"
        case permissionDenied = "permission_denied"
        case unsupportedVersion = "unsupported_version"
        case badRequest = "bad_request"
        case notFound = "not_found"
        case protocolError = "protocol_error"
        case internalError = "internal_error"
    }

    public var code: Code
    public var message: String
    public var description: String { message }

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum GhostTracePaths {
    /// `GHOSTTRACE_HOME` overrides the default `~/Library/Application Support/GhostTrace` (tests, side-by-side runs).
    public static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["GHOSTTRACE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GhostTrace", isDirectory: true)
    }

    public static var socket: String { home.appendingPathComponent("recorder.sock").path }
    public static var database: String { home.appendingPathComponent("events.sqlite").path }
    public static var lock: String { home.appendingPathComponent("recorder.lock").path }
    /// The recorder's unified-log subsystem.
    public static let logSubsystem = "com.amoghkhairate.GhostTrace"
    /// Posted with `notify_post` by the recorder after it stores an alert; the menu bar app listens for it.
    public static let alertNotification = "com.amoghkhairate.GhostTrace.alert"
}

/// Command-line time arguments. Absolute times must carry a zone; nothing is guessed from the local zone.
public enum TimeArgument {
    public static func instant(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        throw ServiceError(.badRequest, "'\(text)' is not an ISO 8601 time with a zone. Use e.g. 2026-10-27T02:00:00+05:30 or 2026-10-26T20:30:00Z.")
    }

    /// `90s`, `30m`, `24h`, `7d`.
    public static func duration(_ text: String) throws -> TimeInterval {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        guard let unit = text.last.flatMap({ units[$0] }), let count = Int(text.dropLast()), count > 0 else {
            throw ServiceError(.badRequest, "'\(text)' is not a duration. Use a positive number followed by s, m, h or d, e.g. 24h.")
        }
        return TimeInterval(count) * unit
    }

    /// `last`, `from` with an optional `to`, or (when `allowAt`) `at` with an optional `within` either side. Nothing given: the last `defaultSpan`.
    /// Error messages name the options as `--name`; the MCP tools use the same names without the dashes.
    public static func window(at: String? = nil, within: String? = nil, last: String?, from: String?, to: String?, allowAt: Bool = false,
                              defaultSpan: TimeInterval = 86400, now: Date = Date()) throws -> DateInterval {
        let (at, within) = (try at.map(instant), try within.map(duration))
        let half = within ?? 1800
        let window: (from: Date, to: Date) = switch (at, last, from, to) {
        case (let at?, nil, nil, nil) where allowAt: (at.addingTimeInterval(-half), at.addingTimeInterval(half))
        case (nil, nil, nil, nil): (now.addingTimeInterval(-defaultSpan), now)
        case (nil, let last?, nil, nil): (now.addingTimeInterval(-(try duration(last))), now)
        case (nil, nil, let from?, let to): (try instant(from), try to.map(instant) ?? now)
        default: throw ServiceError(.badRequest, allowAt ? "Use one of --at, --last, or --from with an optional --to." : "Use either --last, or --from with an optional --to.")
        }
        guard within == nil || at != nil else { throw ServiceError(.badRequest, "--within needs --at.") }
        guard window.from < window.to else { throw ServiceError(.badRequest, "--from must be earlier than --to.") }
        return DateInterval(start: window.from, end: window.to)
    }
}
