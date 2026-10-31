import Collectors
import Foundation
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_100_000_000) })

/// Real `nettop -P -L 1 -x -J bytes_in,bytes_out` output on macOS 27.0.1 (shortened).
private let sample = """
,bytes_in,bytes_out,
syslogd.572,0,236,
mDNSResponder.704,1208410,899181,
Brave Browser H.1383,1370862,2039417,
Code Helper (Pl.3480,0,0,

"""

@Test func parseReadsNettopCSV() {
    #expect(NetTop.parse(sample) == [
        .init(name: "syslogd", pid: 572, received: 0, sent: 236),
        .init(name: "mDNSResponder", pid: 704, received: 1_208_410, sent: 899_181),
        .init(name: "Brave Browser H", pid: 1383, received: 1_370_862, sent: 2_039_417),
        .init(name: "Code Helper (Pl", pid: 3480, received: 0, sent: 0),
    ])
}

@Test func parseSkipsGarbage() {
    #expect(NetTop.parse("") == [])
    #expect(NetTop.parse("oops\n,,\n") == [])
    // No pid, a bad count and a short row are dropped; the good row beside them is kept.
    #expect(NetTop.parse("noPid,1,2,\nx.1,abc,2,\nx.2,3\nok.7,4,5,\n") == [.init(name: "ok", pid: 7, received: 4, sent: 5)])
}

private func script(_ body: String) throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("nettop-\(UUID().uuidString).sh").path
    try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

private func failure(_ result: Result<[NetTop.Entry], CollectorError>) -> Bool {
    if case .failure = result { return true }
    return false
}

@Test func aMissingBinaryIsAFailureNotACrash() {
    #expect(failure(NetTop.snapshot(edge: .started, executable: "/nonexistent")))
}

@Test func aHangingNettopIsKilledAndFails() throws {
    let path = try script("exec sleep 30")
    defer { try? FileManager.default.removeItem(atPath: path) }
    let began = Date()
    #expect(failure(NetTop.snapshot(edge: .ended, timeout: 0.5, executable: path)))
    #expect(Date().timeIntervalSince(began) < 5)
}

@Test func garbageOutputAndFailureExitsAreFailures() throws {
    for body in ["echo oops", "echo ',bytes_in,bytes_out,'; exit 3", "exit 0"] {
        let path = try script(body)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(failure(NetTop.snapshot(edge: .started, timeout: 5, executable: path)), "\(body)")
    }
}

@Test func aWellFormedRunReturnsEntries() throws {
    let path = try script("printf ',bytes_in,bytes_out,\\nsyslogd.5,1,2,\\n'")
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try NetTop.snapshot(edge: .started, timeout: 5, executable: path).get() == [.init(name: "syslogd", pid: 5, received: 1, sent: 2)])
}

@Test func eventsCarryTheEdgeAndOnlyActiveProcessesOrTheError() throws {
    let ok = NetTop.event(.success(NetTop.parse(sample)), edge: .started, clock: clock)
    #expect(ok.kind == .diagnostic && ok.source == "nettop" && ok.payload["edge"] == "started" && ok.payload["error"] == nil)
    let entries = try GhostTraceJSON.decoder().decode([NetTop.Entry].self, from: Data(#require(ok.payload["entries"]).utf8))
    #expect(entries.map(\.name) == ["Brave Browser H", "mDNSResponder", "syslogd"])

    let bad = NetTop.event(.failure(.commandFailed("nettop exited with status 3")), edge: .ended, clock: clock)
    #expect(bad.payload["edge"] == "ended" && bad.payload["entries"] == nil && bad.payload["error"] == "nettop exited with status 3")
}

@Test func outputOverThePipeBufferDoesNotBlockNettop() throws {
    // About 200 KB: more than the 64 KB a pipe holds, so a reader that waits for exit would hang until the timeout.
    let path = try script(#"awk 'BEGIN{print ",bytes_in,bytes_out,"; for(i=1;i<=20000;i++) print "p." i ",1,1,"}'"#)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let began = Date()
    #expect(try NetTop.snapshot(edge: .started, timeout: 10, executable: path).get().count == 20000)
    #expect(Date().timeIntervalSince(began) < 5)
}

@Test func theGateLimitsStartsButAlwaysEndsAStartThatRan() {
    let t0 = Date(milliseconds: 1_793_100_000_000)
    var gate = NetTop.Gate()
    var ran: [Bool] = []
    // (edge, seconds): the expected answers are in `expected`.
    for (edge, seconds) in [(ActivityTracker.Edge.ended, 0.0), (.started, 0), (.ended, 40), (.ended, 41), (.started, 120), (.ended, 150), (.started, 300), (.ended, 320)] {
        ran.append(gate.allow(edge, at: t0.addingTimeInterval(seconds)))
    }
    // no start yet: no; start: yes; short spike's end: yes, once; start under 300 s later: no, and so no end; start at 300 s: yes, with its end.
    #expect(ran == [false, true, true, false, false, false, true, true])
}

@Test func aNettopThatIgnoresSigtermIsKilled() throws {
    // `trap '' TERM` makes the shell ignore SIGTERM; only the SIGKILL after the grace period ends it.
    let path = try script("trap '' TERM\nwhile true; do sleep 1; done")
    defer { try? FileManager.default.removeItem(atPath: path) }
    let began = Date()
    #expect(failure(NetTop.snapshot(edge: .ended, timeout: 0.5, executable: path)))
    #expect(Date().timeIntervalSince(began) < 5)
}
