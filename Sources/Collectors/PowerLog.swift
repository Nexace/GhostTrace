import CryptoKit
import Foundation
import RecorderCore

/// Imports selected lines of `pmset -g log` (powerd's own record) as `diagnostic` events with quality `imported`:
/// sleep, wake, dark wake and the wake requests logged at each sleep. Nothing else from the log is kept.
/// The log is plain text with no documented format; the line shape below was read from macOS 27.0.1.
public enum PowerLog {
    public static let source = "power-log/pmset -g log"

    public struct Snapshot: Sendable {
        public var events: [Event]
        /// Timestamp of the log's first line, of any type: nothing earlier can be checked.
        public var coversFrom: Date?
    }

    /// Runs `/usr/bin/pmset -g log` (no privileges needed; takes about 3 s for a week of log). The output (about 5 MB)
    /// is read in chunks and only the first line and the kept lines are returned, so the recorder's memory stays small.
    public static func read() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var kept: [String] = []
        var partial = Data()
        let handle = pipe.fileHandleForReading
        while let chunk = try handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            partial.append(chunk)
            guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            for line in partial[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
                let text = String(decoding: line, as: UTF8.self)
                if kept.isEmpty || type(of: Substring(text)).map(self.kept.contains) == true { kept.append(text) }
            }
            partial = Data(partial[partial.index(after: lastNewline)...])
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CollectorError.commandFailed("pmset -g log exited with status \(process.terminationStatus)") }
        return kept.joined(separator: "\n")
    }

    /// The type column: `Wake`, `Sleep`, `Wake Requests`, … Nil for lines without one.
    static func type(of line: Substring) -> String? {
        guard let tab = line.firstIndex(of: "\t"), let typeStart = line.index(line.startIndex, offsetBy: 26, limitedBy: tab) else { return nil }
        return line[typeStart..<tab].trimmingCharacters(in: .whitespaces)
    }

    /// Lines look like `2026-10-27 19:14:24 +0530 Wake                \tWake from Deep Idle [CDNVA] : due to … Using BATT (Charge:83%)`.
    /// Kept lines before `since` are skipped (an earlier import stored them); the first line still sets `coversFrom`.
    public static func parse(_ text: String, since: Date? = nil, clock: RecorderClock) -> Snapshot {
        var events: [Event] = []
        var coversFrom: Date?
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let type = type(of: line) else { continue }
            // Dates are parsed only for kept lines (and the first line), since the log runs to tens of thousands of lines.
            guard coversFrom == nil || kept.contains(type), let at = timestamp.date(from: String(line.prefix(25))) else { continue }
            if coversFrom == nil { coversFrom = at }
            if let since, at < since { continue }
            let message = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            let raw = line.trimmingCharacters(in: .whitespaces)
            switch type {
            case "Sleep":
                events.append(event(raw, at, ["entry": "sleep", "reason": reason(message)], clock))
            case "Wake", "DarkWake":
                let entry = type == "Wake" ? "wake" : message.hasPrefix("DarkWake to FullWake") ? "dark_to_full_wake" : "dark_wake"
                events.append(event(raw, at, ["entry": entry, "reason": reason(message)], clock))
            case "Wake Requests":
                for (index, item) in message.split(separator: "[").enumerated() {
                    guard let match = item.firstMatch(of: /process=(\S+) request=(\S+) deltaSecs=(\d+)/), let delta = Double(match.3) else { continue }
                    var payload = ["entry": "wake_request", "process": String(match.1), "request": String(match.2),
                                   // deltaSecs, not wakeAt: wakeAt is printed without a zone.
                                   "wake_at": GhostTraceJSON.string(from: at.addingTimeInterval(delta))]
                    if let info = item.firstMatch(of: /info="([^"]*)"/) { payload["info"] = String(info.1) }
                    if item.hasPrefix("*") { payload["marked"] = "true" }
                    let excerpt = "\(line.prefix(25)) Wake Requests [\(item.trimmingCharacters(in: .whitespaces))"
                    events.append(event(excerpt, at, payload, clock, idSalt: "\(raw)#\(index)"))
                }
            default:
                continue
            }
        }
        return Snapshot(events: events, coversFrom: coversFrom)
    }

    /// `… due to <reason> Using …`; a sleep reason is quoted: `due to 'Software Sleep pid=418':TCPKeepAlive=active`.
    static func reason(_ message: String) -> String {
        guard let due = message.range(of: "due to ") else { return "" }
        var rest = message[due.upperBound...]
        if let using = rest.range(of: " Using ") { rest = rest[..<using.lowerBound] }
        if rest.hasPrefix("'"), let close = rest.dropFirst().firstIndex(of: "'") { return String(rest[rest.index(after: rest.startIndex)..<close]) }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The id is derived from the line, so importing the same log again stores nothing new.
    private static func event(_ excerpt: String, _ at: Date, _ payload: [String: String], _ clock: RecorderClock, idSalt: String? = nil) -> Event {
        let hash = Array(SHA256.hash(data: Data((idSalt ?? excerpt).utf8)))
        let id = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                             hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
        var event = Event(id: id, kind: .diagnostic, source: source, occurredAt: at, payload: payload, quality: .imported,
                          provenance: excerpt, clock: clock)
        // Recording-time clock values say nothing about when, or in which boot, powerd wrote the line.
        event.monotonicNanos = nil
        event.bootSessionID = nil
        return event
    }

    private static let kept: Set<String> = ["Sleep", "Wake", "DarkWake", "Wake Requests"]

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()
}
