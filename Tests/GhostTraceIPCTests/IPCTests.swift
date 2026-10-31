import Foundation
@testable import GhostTraceIPC
@testable import InvestigationKit
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_050_200_123) })

/// A fresh private directory; returns the socket path inside it (well under the 103-byte sun_path limit).
private func socketPath() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("gt-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return dir + "/r.sock"
}

@Test func requestsRoundTripOverARealSocket() throws {
    let path = try socketPath()
    let server = RecorderServer(path: path) { request in
        guard request.method == .event, let id = request.eventID else { return .failure(.notFound, "nothing here") }
        return Response(event: Event(id: id, kind: .wake, source: "test", clock: clock))
    }
    try server.start()
    defer { server.stop() }
    let id = UUID()
    let event = try RecorderClient(socketPath: path).event(id: id)
    #expect(event.id == id)
    #expect(event.kind == .wake)
    #expect(throws: ServiceError(.notFound, "nothing here")) { try RecorderClient(socketPath: path).status() }
}

@Test func wakeInvestigationRoundTripsWithItsWindow() throws {
    let path = try socketPath()
    let server = RecorderServer(path: path) { request in
        guard request.method == .investigateWake, let window = request.window else { return .failure(.badRequest, "no window") }
        let finding = Finding(confidence: .correlated, statement: "s", basis: "b", evidence: [UUID()])
        return Response(investigation: WakeInvestigation(from: window.start, to: window.end, wakes: [WakeIncident(at: window.start, type: .dark, summary: "s", findings: [finding], limits: [])],
                                                         limits: [], recordingSince: nil, powerLogSince: nil, powerLogThrough: nil, evidence: []))
    }
    try server.start()
    defer { server.stop() }
    let window = DateInterval(start: Date(milliseconds: 1_793_050_200_123), duration: 3600)
    let result = try RecorderClient(socketPath: path).investigateWake(window)
    #expect(result.from == window.start && result.to == window.end)
    #expect(result.wakes.first?.findings.first?.confidence == .correlated)
}

@Test func liveRoundTripsOverARealSocket() throws {
    let path = try socketPath()
    let reading = SystemReading(at: Date(milliseconds: 1_793_050_200_123), cpu: CPUTicks(busy: 40, total: 100), memoryUsed: 8 << 30, memoryTotal: 16 << 30,
                                battery: BatteryReading(onBattery: true, charging: false, charge: 71, minutesToEmpty: 190), idleSeconds: 12.5)
    let server = RecorderServer(path: path) { request in request.method == .live ? Response(live: reading) : .failure(.badRequest, "not live") }
    try server.start()
    defer { server.stop() }
    #expect(try RecorderClient(socketPath: path).live() == reading)
}

@Test func socketIsOwnerOnly() throws {
    let path = try socketPath()
    let server = RecorderServer(path: path) { _ in .failure(.notFound, "") }
    try server.start()
    defer { server.stop() }
    let mode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    #expect(mode & 0o777 == 0o600)
}

@Test func missingRecorderIsReportedAsNotRunning() throws {
    let error = #expect(throws: ServiceError.self) { try RecorderClient(socketPath: socketPath()).status() }
    #expect(error?.code == .recorderNotRunning)
}

@Test(arguments: ["not json\n", ""])
func unreadableOrMissingReplyIsAProtocolError(reply: String) throws {
    let path = try socketPath()
    let fd = try makeSocket()
    try withAddress(path) { address, length in #expect(bind(fd, address, length) == 0) }
    #expect(listen(fd, 1) == 0)
    let peer = Thread {
        let client = accept(fd, nil, nil)
        _ = try? readMessage(client)
        _ = Array(reply.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        close(client)
        close(fd)
    }
    peer.start()
    let error = #expect(throws: ServiceError.self) { try RecorderClient(socketPath: path, timeout: 2).status() }
    #expect(error?.code == .protocolError)
}

@Test func requestFromANewerClientIsRejected() throws {
    let path = try socketPath()
    let server = RecorderServer(path: path) { _ in Issue.record("handler must not run"); return Response() }
    try server.start()
    defer { server.stop() }
    var request = Request(method: .status)
    request.apiVersion = IPC.apiVersion + 1
    let error = #expect(throws: ServiceError.self) { try RecorderClient(socketPath: path).send(request) }
    #expect(error?.code == .unsupportedVersion)
}

@Test func explicitOffsetsNameTheSameInstant() throws {
    let utc = try TimeArgument.instant("2026-10-26T20:30:00Z")
    #expect(try TimeArgument.instant("2026-10-27T02:00:00+05:30") == utc)
    #expect(try TimeArgument.instant("2026-10-26T13:30:00.000-07:00") == utc)
    // 01:30 happens twice when US Pacific falls back; the offset says which one.
    #expect(try TimeArgument.instant("2026-11-01T01:30:00-08:00").timeIntervalSince(TimeArgument.instant("2026-11-01T01:30:00-07:00")) == 3600)
}

@Test(arguments: ["2026-10-27T02:00:00", "2026-10-27", "yesterday"])
func timesWithoutAZoneAreRejected(text: String) {
    #expect(throws: ServiceError.self) { try TimeArgument.instant(text) }
}

@Test func durationsParse() throws {
    #expect(try TimeArgument.duration("90s") == 90)
    #expect(try TimeArgument.duration("24h") == 86400)
    #expect(try TimeArgument.duration("7d") == 604_800)
    for bad in ["0h", "h", "5w", "-1d"] {
        #expect(throws: ServiceError.self) { try TimeArgument.duration(bad) }
    }
}

@Test func memoryInvestigationRoundTripsOverARealSocket() throws {
    let path = try socketPath()
    let server = RecorderServer(path: path) { request in
        guard request.method == .investigateMemory, let window = request.window else { return .failure(.badRequest, "no window") }
        return Response(memoryInvestigation: MemoryInvestigation(from: window.start, to: window.end, memoryTotal: 1 << 34, sampleCount: 0, spikes: [],
                                                                 samplingGaps: [], limits: [], evidence: []))
    }
    try server.start()
    defer { server.stop() }
    let window = DateInterval(start: Date(milliseconds: 1_793_000_000_000), duration: 3600)
    let investigation = try RecorderClient(socketPath: path).investigateMemory(window)
    #expect(investigation.from == window.start && investigation.memoryTotal == 1 << 34)
}

@Test func configureCarriesTheSystemMonitorSwitch() throws {
    let path = try socketPath()
    let server = RecorderServer(path: path) { request in
        guard request.method == .configure, let on = request.systemMonitor else { return .failure(.badRequest, "no switch") }
        return Response(status: RecorderStatus(state: .running, pid: 1, startedAt: clock.now(), pausedAt: nil, databasePath: "/x", eventCount: 0,
                                               retainedSince: nil, retentionDays: 30, droppedEvents: 0, capabilities: [], systemMonitor: on))
    }
    try server.start()
    defer { server.stop() }
    #expect(try RecorderClient(socketPath: path).configure(systemMonitor: false).systemMonitor == false)
    #expect(try RecorderClient(socketPath: path).configure(systemMonitor: true).systemMonitor == true)
}

@Test func aPhase2StatusWithoutSamplingOrWatchesStillDecodes() throws {
    let json = #"{"capabilities":[],"databasePath":"/x","droppedEvents":0,"eventCount":1,"pid":1,"retentionDays":30,"startedAt":"2026-10-27T10:00:00.000Z","state":"running"}"#
    let status = try GhostTraceJSON.decoder().decode(RecorderStatus.self, from: Data(json.utf8))
    #expect(status.sampleInterval == nil && status.watchedPaths == nil)
}

@Test func newRequestFieldsRoundTrip() throws {
    let request = Request(method: .watchAdd, path: "/Users/me/Documents", top: 5, points: 100, sampleInterval: 30)
    let decoded = try GhostTraceJSON.decoder().decode(Request.self, from: GhostTraceJSON.encoder().encode(request))
    #expect(decoded == request)
    #expect(String(decoding: try GhostTraceJSON.encoder().encode(Request(method: .investigateFileChange)), as: UTF8.self).contains("investigate_file_change"))
}

@Test func xpcEnvelopeCarriesTheSocketsJSONUnchanged() throws {
    let window = DateInterval(start: Date(milliseconds: 1_793_000_000_123), duration: 3600)
    let request = Request(method: .investigateWake, window: window)
    // What the client sends: the request's JSON in an envelope; the Codable round trip stands in for XPC's own encoding.
    let sent = Envelope(json: try GhostTraceJSON.encoder().encode(request))
    let received = try JSONDecoder().decode(Envelope.self, from: JSONEncoder().encode(sent))
    #expect(try decodeRequest(received.json).get() == request)

    let reply = Envelope(.failure(.notFound, "gone"))
    #expect(try GhostTraceJSON.decoder().decode(Response.self, from: reply.json).error == ServiceError(.notFound, "gone"))
}

@Test func theXPCServerAppliesTheSocketsRequestChecks() throws {
    var newer = Request(method: .status)
    newer.apiVersion = IPC.apiVersion + 1
    #expect(decodeRequest(try GhostTraceJSON.encoder().encode(newer)).failureCode == .unsupportedVersion)
    #expect(decodeRequest(Data("not json".utf8)).failureCode == .badRequest)
    #expect(decodeRequest(Data(count: IPC.maxMessageBytes + 1)).failureCode == .protocolError)
}

@Test func transportIsChosenFromTheEnvironment() {
    #expect(IPC.Transport.client([:]) == .xpc)
    #expect(IPC.Transport.client(["GHOSTTRACE_HOME": ""]) == .xpc)
    #expect(IPC.Transport.client(["GHOSTTRACE_HOME": "/tmp/gt"]) == .socket)
    #expect(RecorderClient(socketPath: "/tmp/gt/r.sock").transport == .socket)
    // launchd sets XPC_SERVICE_NAME to the job label; a terminal has another value or none.
    #expect(IPC.Transport.recorder(["XPC_SERVICE_NAME": IPC.machServiceName]) == .xpc)
    #expect(IPC.Transport.recorder(["XPC_SERVICE_NAME": "0"]) == .socket)
    #expect(IPC.Transport.recorder([:]) == .socket)
}

private extension Result where Failure == ServiceError {
    var failureCode: ServiceError.Code? { if case .failure(let error) = self { error.code } else { nil } }
}
