import Foundation
import os
import RecorderCore

/// Per-process network counters from `nettop`, taken only when traffic crosses the busy line (see `Recorder`). nettop's
/// counts cover only processes with recent connections and what they include is undocumented; the format below was read on macOS 27.0.1.
public enum NetTop {
    public static let source = "nettop"
    /// The recorder starts a snapshot pair at most this often.
    public static let minInterval: TimeInterval = 300

    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var pid: Int32
        public var received: UInt64
        public var sent: UInt64

        public init(name: String, pid: Int32, received: UInt64, sent: UInt64) {
            self.name = name
            self.pid = pid
            self.received = received
            self.sent = sent
        }
    }

    /// Rows are `name.pid,bytes_in,bytes_out,`; the header and anything else that doesn't fit are skipped.
    /// The name and pid split on the last `.`, since names contain dots and spaces.
    public static func parse(_ output: String) -> [Entry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."), let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let received = UInt64(fields[1]), let sent = UInt64(fields[2]) else { return nil }
            return Entry(name: String(fields[0][..<dot]), pid: pid, received: received, sent: sent)
        }
    }

    /// Decides whether the recorder runs a snapshot for an edge. Starts are limited to one per `minInterval`; an end runs
    /// only after a start that ran, so even a short spike gets a start/end pair.
    public struct Gate: Sendable {
        private var lastStart: Date?
        private var startRan = false

        public init() {}

        public mutating func allow(_ edge: ActivityTracker.Edge, at now: Date) -> Bool {
            switch edge {
            case .started:
                guard lastStart.map({ now.timeIntervalSince($0) >= minInterval }) ?? true else { return false }
                (lastStart, startRan) = (now, true)
                return true
            case .ended:
                defer { startRan = false }
                return startRan
            }
        }
    }

    /// Takes about 5 s on a Mac with many connections. Blocks, so call it off the sampler and writer queues.
    /// A missing binary, a nonzero exit, no header (garbage) or no exit within `timeout` is a failure, never a crash.
    public static func snapshot(edge: ActivityTracker.Edge, timeout: TimeInterval = 15,
                                executable: String = "/usr/bin/nettop") -> Result<[Entry], CollectorError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failure(.commandFailed("nettop (\(edge)) couldn't start: \(error.localizedDescription)")) }
        // Read while it runs, so output over the 64 KB pipe buffer can't block nettop until the timeout.
        let output = OSAllocatedUnfairLock(initialState: Data())
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            reading.leave()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            // A nettop that ignores SIGTERM is killed by its pid, so it never lingers.
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return .failure(.commandFailed("nettop (\(edge)) didn't finish in \(Int(timeout)) s and was stopped"))
        }
        guard process.terminationStatus == 0 else { return .failure(.commandFailed("nettop (\(edge)) exited with status \(process.terminationStatus)")) }
        _ = reading.wait(timeout: .now() + 2)
        let text = String(decoding: output.withLock { $0 }, as: UTF8.self)
        guard text.contains("bytes_in") else { return .failure(.commandFailed("nettop (\(edge)) printed output GhostTrace can't read")) }
        return .success(parse(text))
    }

    /// Processes that moved no bytes are left out, so a stored snapshot is a few KB. Entries are largest first.
    public static func event(_ result: Result<[Entry], CollectorError>, edge: ActivityTracker.Edge, clock: RecorderClock) -> Event {
        var payload = ["edge": edge == .started ? "started" : "ended"]
        switch result {
        case let .success(entries):
            let active = entries.filter { $0.received + $0.sent > 0 }.sorted { $0.received + $0.sent > $1.received + $1.sent }
            payload["entries"] = String(decoding: try! GhostTraceJSON.encoder().encode(active), as: UTF8.self)
        case let .failure(error):
            switch error {
            case let .commandFailed(message), let .permissionMissing(message): payload["error"] = message
            }
        }
        return Event(kind: .diagnostic, source: source, payload: payload, quality: .sampled,
                     provenance: "nettop -P -L 1 -x -J bytes_in,bytes_out, taken when network traffic crossed 10 MB/s. Counts only processes with recent connections.", clock: clock)
    }
}
