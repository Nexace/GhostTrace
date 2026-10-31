import Foundation
import GhostTraceIPC
import RecorderCore

/// A read-only MCP server: newline-delimited JSON-RPC on stdio, answered through the recorder's IPC contract (`send`).
/// It has no database access and no tool that changes the recorder; the recorder also refuses MCP writes itself.
/// Speaks MCP 2026-07-28 (`server/discover`, per-request `_meta`) and the older `initialize` handshake. ADR 0006.
public struct MCPServer: Sendable {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    public static let maxListLimit = 200
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfo = ["name": "ghosttrace", "title": "GhostTrace", "version": "0.6.0"]
    static let instructions = """
        GhostTrace is a local flight recorder for this Mac. These tools only read what it recorded; none can pause it or change what it watches. \
        Cite event ids for every claim. Findings carry a confidence (observed, correlated, likely, unknown): keep it in your answer, and never present \
        correlation as a cause. event_gap events and limits mean missing data, not that nothing happened, and nothing before recordingSince was recorded. \
        Times are UTC. In event listings, paths from watched folders are replaced by a hash.
        """

    let send: @Sendable (Request) throws -> Response

    public init(send: @escaping @Sendable (Request) throws -> Response) {
        self.send = send
    }

    /// One message in, at most one out: notifications and stray responses get no reply.
    public func handle(_ line: Data) -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return reply(id: NSNull(), error: (-32700, "Parse error", nil))
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        guard let method = message["method"] as? String else { return message["result"] != nil || message["error"] != nil ? nil : reply(id: id, error: (-32600, "Invalid Request", nil)) }
        let params = message["params"] as? [String: Any] ?? [:]
        if let requested = (params["_meta"] as? [String: Any])?[Self.versionKey] as? String, !Self.modernVersions.contains(requested) {
            return reply(id: id, error: (-32022, "Unsupported protocol version", ["supported": Self.modernVersions, "requested": requested]))
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return reply(id: id, result: ["protocolVersion": Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0],
                                          "capabilities": ["tools": [:]], "serverInfo": Self.serverInfo, "instructions": Self.instructions])
        case "server/discover":
            return reply(id: id, result: ["supportedVersions": Self.modernVersions, "capabilities": ["tools": [:]], "instructions": Self.instructions,
                                          "_meta": ["io.modelcontextprotocol/serverInfo": Self.serverInfo]])
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools.map(\.definition)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = Self.tools.first(where: { $0.name == name }) else {
                return reply(id: id, error: (-32602, "Unknown tool: \(params["name"] ?? "none")", nil))
            }
            return reply(id: id, result: call(tool, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return reply(id: id, error: (-32601, "Method not found: \(method)", nil))
        }
    }

    /// Failures are tool results with `isError`, so the agent can read and act on them.
    func call(_ tool: Tool, _ arguments: [String: Any]) -> [String: Any] {
        do {
            if let extra = arguments.keys.first(where: { tool.properties[$0] == nil }) {
                throw ServiceError(.badRequest, "\(tool.name) doesn't take '\(extra)'.")
            }
            var response = try send(try tool.request(Arguments(values: arguments)))
            // Same rule as `ghosttrace export`: watched paths in listings aren't handed to an agent.
            if let events = response.page?.events { response.page?.events = events.map { $0.redacted() } }
            response.event = response.event?.redacted()
            if let events = response.diskInvestigation?.evidence { response.diskInvestigation?.evidence = events.map { $0.redacted() } }
            var data = try GhostTraceJSON.encoder().encode(response)
            if tool.name.hasPrefix("investigate_") { data = try Self.slimEvidence(data) }
            // Text only: `structuredContent` too would send every result twice, and a day of wakes is already about 150 KB.
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
        } catch {
            let message = (error as? ServiceError).map { "\($0.code.rawValue): \($0.message)" } ?? "\(error)"
            return ["content": [["type": "text", "text": message]], "isError": true]
        }
    }

    static let evidenceKeys: Set = ["id", "kind", "occurredAt", "endedAt", "source", "subject", "payload", "quality"]

    /// Investigation evidence keeps what an agent needs to cite and weigh an event; get_event returns the rest, such as a sample's process list.
    /// Full events made a day's battery investigation about 500 KB, past what agents read in one tool result.
    static func slimEvidence(_ data: Data) throws -> Data {
        func slim(_ value: Any) -> Any {
            guard var object = value as? [String: Any] else { return (value as? [Any])?.map(slim) ?? value }
            for (key, child) in object {
                if key == "evidence", let events = child as? [[String: Any]] {
                    object[key] = events.map { event in
                        var kept = event.filter { evidenceKeys.contains($0.key) }
                        if var payload = kept["payload"] as? [String: Any] { payload["sample"] = nil; kept["payload"] = payload }
                        return kept
                    }
                } else {
                    object[key] = slim(child)
                }
            }
            return object
        }
        return try JSONSerialization.data(withJSONObject: slim(JSONSerialization.jsonObject(with: data)), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func reply(id: Any, result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "result": result.merging(["resultType": "complete"]) { old, _ in old }])
    }

    private func reply(id: Any, error: (code: Int, message: String, data: [String: Any]?)) -> Data {
        var body: [String: Any] = ["code": error.code, "message": error.message]
        body["data"] = error.data
        return encode(["jsonrpc": "2.0", "id": id, "error": body])
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}

/// Tool arguments, checked against what each tool accepts.
struct Arguments {
    var values: [String: Any]

    func string(_ name: String) throws -> String? {
        guard let value = values[name] else { return nil }
        guard let text = value as? String else { throw ServiceError(.badRequest, "'\(name)' must be a string.") }
        return text
    }

    func int(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = values[name] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let int = Int(exactly: number.doubleValue), range.contains(int) else {
            throw ServiceError(.badRequest, "'\(name)' must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return int
    }

    func window(allowAt: Bool, defaultSpan: TimeInterval = 86400) throws -> DateInterval {
        try TimeArgument.window(at: allowAt ? string("at") : nil, within: allowAt ? string("within") : nil,
                                last: string("last"), from: string("from"), to: string("to"), allowAt: allowAt, defaultSpan: defaultSpan)
    }
}

struct Tool: Sendable {
    var name: String
    var title: String
    var description: String
    var properties: [String: [String: String]]
    var required: [String] = []
    var request: @Sendable (Arguments) throws -> Request

    var definition: [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
    }
}

extension MCPServer {
    private static let time = ["type": "string", "description": "ISO 8601 with an explicit zone, e.g. 2026-10-27T02:00:00+05:30"]
    private static let duration = ["type": "string", "description": "90s, 30m, 24h or 7d"]
    private static let range: [String: [String: String]] = [
        "last": duration.merging(["description": "Window ending now: 90s, 30m, 24h or 7d. Default 24h."]) { $1 },
        "from": time, "to": time.merging(["description": "Window end, ISO 8601 with a zone. Default now; needs from."]) { $1 },
    ]
    private static let around = range.merging([
        "at": time.merging(["description": "Centre of the window, ISO 8601 with a zone. Not with last or from."]) { $1 },
        "within": duration.merging(["description": "Either side of at. Default 30m."]) { $1 },
    ]) { $1 }

    static let tools: [Tool] = [
        Tool(name: "get_recording_status", title: "Recording status",
             description: "Whether GhostTrace is recording, since when, which collectors work and which lack a permission, and the watched paths.",
             properties: [:]) { _ in Request(method: .status) },
        Tool(name: "list_events", title: "List events",
             description: "Recorded events in a time window, oldest first: app launches and exits, sleep, wake, resource samples, file changes, diagnostics and gaps. Gaps overlapping the window are always included.",
             properties: range.merging([
                 "kind": ["type": "string", "description": "Only this kind: " + EventKind.allCases.map(\.rawValue).joined(separator: ", ")],
                 "limit": ["type": "integer", "description": "1 to \(maxListLimit). Default 50."],
                 "cursor": ["type": "string", "description": "nextCursor from the previous page"],
             ]) { $1 }) { arguments in
                 let window = try arguments.window(allowAt: false)
                 let kind = try arguments.string("kind").map { text in
                     guard let kind = EventKind(rawValue: text) else { throw ServiceError(.badRequest, "Unknown kind '\(text)'.") }
                     return kind
                 }
                 return Request(method: .events, query: EventQuery(from: window.start, to: window.end, kind: kind,
                                                                    limit: try arguments.int("limit", in: 1...maxListLimit) ?? 50, cursor: try arguments.string("cursor")))
             },
        Tool(name: "get_event", title: "Get event", description: "One event by id, with its payload and provenance.",
             properties: ["id": ["type": "string", "description": "Event UUID"]], required: ["id"]) { arguments in
                 guard let id = try arguments.string("id").flatMap(UUID.init(uuidString:)) else { throw ServiceError(.badRequest, "'id' must be an event UUID.") }
                 return Request(method: .event, eventID: id)
             },
        Tool(name: "get_resource_usage", title: "Resource usage",
             description: "Sampled CPU and memory in a window: the top processes and a downsampled system series. Samples are snapshots, not continuous measurements.",
             properties: range.merging(["top": ["type": "integer", "description": "Processes to list, 1 to 50. Default 10."]]) { $1 }) { arguments in
                 Request(method: .resources, window: try arguments.window(allowAt: false, defaultSpan: 3600), top: try arguments.int("top", in: 1...50) ?? 10, points: 60)
             },
        Tool(name: "investigate_wake", title: "Investigate wakes",
             description: "Why the Mac woke in a window: each wake with its power-log reason when one was logged, findings with confidence and evidence ids, alternatives, and coverage limits.",
             properties: around) { arguments in
                 Request(method: .investigateWake, window: try arguments.window(allowAt: true))
             },
        Tool(name: "investigate_memory", title: "Investigate memory",
             description: "Memory pressure and the largest sampled processes in a window, with findings, confidence and evidence ids.",
             properties: around) { arguments in
                 Request(method: .investigateMemory, window: try arguments.window(allowAt: true))
             },
        Tool(name: "investigate_file_change", title: "Investigate file changes",
             description: "Recorded changes to a file, or to anything under a folder, in a window. Only watched paths are recorded, and the process that wrote a file is never known for certain.",
             properties: range.merging(["path": ["type": "string", "description": "Absolute path of a file or folder"]]) { $1 }, required: ["path"]) { arguments in
                 guard let path = try arguments.string("path"), path.hasPrefix("/") else { throw ServiceError(.badRequest, "'path' must be an absolute path.") }
                 return Request(method: .investigateFileChange, window: try arguments.window(allowAt: false), path: path)
             },
        Tool(name: "investigate_battery", title: "Investigate battery drain",
             description: "Battery drain in a window (at most 48 h): each stretch on battery with its drain rate, drain while asleep, and the top energy users among the user's processes, with findings, confidence and evidence ids.",
             properties: around) { arguments in
                 Request(method: .investigateBattery, window: try arguments.window(allowAt: true))
             },
        Tool(name: "investigate_network", title: "Investigate network spikes",
             description: "Network traffic spikes in a window (at most 48 h), and the process behind each when nettop snapshots were taken, with findings, confidence and evidence ids.",
             properties: around) { arguments in
                 Request(method: .investigateNetwork, window: try arguments.window(allowAt: true))
             },
        Tool(name: "investigate_disk", title: "Investigate disk space and writes",
             description: "Free-space drops and write bursts in a window (at most 48 h), the user's processes that wrote, and file changes in watched folders at the time, with findings, confidence and evidence ids.",
             properties: around) { arguments in
                 Request(method: .investigateDisk, window: try arguments.window(allowAt: true))
             },
    ]
}
