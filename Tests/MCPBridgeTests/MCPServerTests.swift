import Foundation
import GhostTraceIPC
@testable import InvestigationKit
@testable import MCPBridge
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_050_200_123) })

/// Sends one JSON-RPC message and decodes the reply.
private func exchange(_ server: MCPServer, _ message: [String: Any]) throws -> [String: Any]? {
    try server.handle(JSONSerialization.data(withJSONObject: message)).map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
}

private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
    let reply = try exchange(server, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
    return try #require(reply?["result"] as? [String: Any])
}

/// Records what the recorder was asked, and answers like the recorder's MCP gate with access off when `allowed` is false.
private final class FakeRecorder: @unchecked Sendable {
    var requests: [Request] = []
    var allowed = true
    var response = Response()

    lazy var server = MCPServer { [unowned self] request in
        var request = request
        request.client = .mcp
        requests.append(request)
        if let refusal = request.mcpRefusal(accessAllowed: allowed) { throw refusal }
        return response
    }
}

@Test func bothHandshakesAreAnswered() throws {
    let server = FakeRecorder().server
    let legacy = try #require(try exchange(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]]))
    let result = try #require(legacy["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-06-18")
    #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)

    let unknown = try #require(try exchange(server, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]]))
    #expect((unknown["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.legacyVersions[0])

    let modern = try #require(try exchange(server, ["jsonrpc": "2.0", "id": "d", "method": "server/discover",
                                                    "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]]))
    #expect((modern["result"] as? [String: Any])?["supportedVersions"] as? [String] == ["2026-07-28"])
    #expect(modern["id"] as? String == "d")

    let wrong = try #require(try exchange(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/list",
                                                   "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01"]]]))
    #expect((wrong["error"] as? [String: Any])?["code"] as? Int == -32022)

    #expect(try exchange(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    #expect((try exchange(server, ["jsonrpc": "2.0", "id": 4, "method": "resources/list"])?["error"] as? [String: Any])?["code"] as? Int == -32601)
    let garbage = try #require(server.handle(Data("{not json".utf8)))
    #expect(String(decoding: garbage, as: UTF8.self).contains("-32700"))
}

@Test func everyToolIsReadOnlyAndMapsToAReadOnlyMethod() throws {
    let fake = FakeRecorder()
    let list = try #require(try exchange(fake.server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
    let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.count == MCPServer.tools.count && tools.count == 10)
    for tool in tools { #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true) }

    let arguments: [String: [String: Any]] = ["get_event": ["id": UUID().uuidString], "investigate_file_change": ["path": "/tmp/x"]]
    for tool in MCPServer.tools { _ = try call(fake.server, tool.name, arguments[tool.name] ?? [:]) }
    #expect(fake.requests.count == MCPServer.tools.count)
    #expect(fake.requests.allSatisfy { $0.method.isReadOnly })
    for (name, method) in [("investigate_battery", Request.Method.investigateBattery), ("investigate_network", .investigateNetwork), ("investigate_disk", .investigateDisk)] {
        let at = "2026-10-27T02:00:00Z"
        _ = try call(fake.server, name, ["at": at, "within": "10m"])
        #expect(fake.requests.last?.method == method && fake.requests.last?.window?.duration == 1200)
    }

    let unknown = try #require(try exchange(fake.server, ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "pause_recording"]]))
    #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
}

@Test func argumentsAreValidatedAndBounded() throws {
    let fake = FakeRecorder()
    _ = try call(fake.server, "list_events", ["last": "2h", "kind": "wake"])
    let query = try #require(fake.requests.last?.query)
    #expect(query.kind == .wake)
    #expect(query.limit == 50)
    #expect(abs(query.to.timeIntervalSince(query.from) - 7200) < 1)

    _ = try call(fake.server, "investigate_wake", ["at": "2026-10-27T03:00:00+05:30", "within": "1h"])
    #expect(fake.requests.last?.window == DateInterval(start: try TimeArgument.instant("2026-10-27T02:00:00+05:30"), duration: 7200))

    let before = fake.requests.count
    for (tool, arguments) in [("list_events", ["limit": 5000]), ("list_events", ["limit": true]), ("list_events", ["from": "2026-10-27 02:00"]),
                              ("list_events", ["kind": "keystroke"]), ("get_event", ["id": "nope"]), ("investigate_file_change", ["path": "relative/x"]),
                              ("list_events", ["at": "2026-10-27T03:00:00Z"])] as [(String, [String: Any])] {
        let result = try call(fake.server, tool, arguments)
        #expect(result["isError"] as? Bool == true, "\(tool) \(arguments)")
        #expect(((result["content"] as? [[String: Any]])?.first?["text"] as? String)?.hasPrefix("bad_request") == true)
    }
    #expect(fake.requests.count == before, "invalid arguments never reach the recorder")
}

@Test func accessOffIsAReadableToolError() throws {
    let fake = FakeRecorder()
    fake.allowed = false
    let result = try call(fake.server, "get_recording_status")
    #expect(result["isError"] as? Bool == true)
    #expect(((result["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("ghosttrace mcp allow") == true)
}

@Test func watchedPathsAreRedactedInListings() throws {
    let fake = FakeRecorder()
    let change = Event(kind: .fileChange, source: "fsevents", subject: Subject(path: "/Users/me/Secret/plan.txt"), payload: ["path": "/Users/me/Secret/plan.txt"],
                       privacyClass: .sensitive, clock: clock)
    fake.response = Response(page: EventPage(events: [change], nextCursor: nil, retainedSince: nil))
    let result = try call(fake.server, "list_events")
    let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(!text.contains("Secret"))
    #expect(text.contains("redacted-"))
    let response = try GhostTraceJSON.decoder().decode(Response.self, from: Data(text.utf8))
    #expect(response.page?.events.count == 1)
}

@Test func watchedPathsAreRedactedInDiskEvidence() throws {
    let fake = FakeRecorder()
    let change = Event(kind: .fileChange, source: "fsevents", subject: Subject(path: "/Users/me/Secret/plan.txt"), payload: ["path": "/Users/me/Secret/plan.txt"],
                       privacyClass: .sensitive, clock: clock)
    fake.response = Response(diskInvestigation: DiskInvestigation(from: clock.now(), to: clock.now(), incidents: [], limits: [], evidence: [change]))
    let text = try #require((try call(fake.server, "investigate_disk")["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(!text.contains("Secret") && text.contains("redacted-"))
}

@Test func investigationEvidenceIsSlimmedButStillCitable() throws {
    // A day of battery evidence was 500 KB of full samples; the agent keeps ids, kinds and short payloads, and get_event has the rest.
    let fake = FakeRecorder()
    let sample = Event(kind: .resourceSample, source: "resources", payload: ["memory_used": "12.0 GB", "sample": String(repeating: "x", count: 5000)], clock: clock)
    let finding = Finding(confidence: .observed, statement: "s", basis: "b", evidence: [sample.id])
    fake.response = Response(diskInvestigation: DiskInvestigation(from: clock.now(), to: clock.now(),
                                                                  incidents: [DiskIncident(from: clock.now(), to: clock.now(), written: 1, summary: "s", findings: [finding])],
                                                                  limits: [], evidence: [sample]))
    let text = try #require((try call(fake.server, "investigate_disk")["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(text.count < 1500 && !text.contains("xxxx") && !text.contains("provenance"))
    #expect(text.contains(sample.id.uuidString) && text.contains("12.0 GB") && text.contains("resource_sample"))
}

@Test func theRecorderGateRefusesWritesAndUnconsentedReads() {
    let read = Request(method: .events, client: .mcp)
    #expect(read.mcpRefusal(accessAllowed: true) == nil)
    #expect(read.mcpRefusal(accessAllowed: false)?.code == .permissionDenied)
    #expect(Request(method: .live, client: .mcp).mcpRefusal(accessAllowed: true) == nil)
    for method in [Request.Method.pause, .resume, .watchAdd, .watchRemove, .configure] {
        #expect(Request(method: method, client: .mcp).mcpRefusal(accessAllowed: true)?.code == .permissionDenied)
    }
    #expect(Request(method: .configure, systemMonitor: false, client: .mcp).mcpRefusal(accessAllowed: true)?.code == .permissionDenied)
    #expect(Request(method: .pause).mcpRefusal(accessAllowed: false) == nil, "the CLI and the app aren't gated")
}
