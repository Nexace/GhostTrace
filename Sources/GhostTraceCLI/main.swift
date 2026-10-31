// `ghosttrace`: a client of the running recorder. It never opens the database or starts collectors itself.
import Foundation
import GhostTraceIPC
import InvestigationKit
import MCPBridge
import RecorderCore

let usage = """
    usage: ghosttrace status [--json]
           ghosttrace events [--last DURATION | --from TIME [--to TIME]] [--kind KIND] [--limit N] [--cursor CURSOR] [--json]
           ghosttrace event ID [--json]
           ghosttrace investigate wake [--at TIME [--within DURATION] | --last DURATION | --from TIME [--to TIME]] [--detail] [--json]
           ghosttrace investigate memory [--at TIME [--within DURATION] | --last DURATION | --from TIME [--to TIME]] [--detail] [--json]
           ghosttrace investigate battery|network|disk [--at TIME [--within DURATION] | --last DURATION | --from TIME [--to TIME]] [--detail] [--json]
           ghosttrace investigate file-change --path PATH [--last DURATION | --from TIME [--to TIME]] [--detail] [--json]
           ghosttrace memory [--top N] [--last DURATION | --from TIME [--to TIME]] [--json]
           ghosttrace system [--last DURATION | --from TIME [--to TIME]] [--json]
           ghosttrace watch [list | add PATH | remove PATH] [--json]
           ghosttrace config [--sample-interval DURATION] [--system on|off] [--json]
           ghosttrace export [--last DURATION | --from TIME [--to TIME]] [--kind KIND] [--include-sensitive] [--output FILE]
           ghosttrace pause [--json]
           ghosttrace resume [--json]
           ghosttrace logs [--last DURATION]
           ghosttrace mcp [allow | deny] [--json]

    TIME      ISO 8601 with an explicit zone: 2026-10-27T02:00:00+05:30 or 2026-10-26T20:30:00Z
    DURATION  90s, 30m, 24h, 7d (events, export and investigate default to --last 24h, memory and system to --last 1h; --within defaults to 30m either side)
    KIND      \(EventKind.allCases.map(\.rawValue).joined(separator: ", ")); event_gap rows are always included
    --detail  for investigate: every finding with its reasoning and evidence ids
    PATH      a file or folder; investigate file-change covers everything under a folder
    export    writes the events as one JSON document; file paths from watched folders are replaced by a short hash
              unless --include-sensitive is given. --output creates FILE (owner-only) and won't overwrite one.
    mcp       with no argument, a read-only MCP server on stdin/stdout for AI agents (it answers only after: ghosttrace mcp allow).
              allow / deny turn agent access on or off; it starts off. Listings hide watched paths, as export does.
    --system  off stops CPU, GPU, network, disk and battery readings, alerts and nettop; memory, wakes, launches and file changes go on
    logs      the recorder's own diagnostics (starts, stops, pauses, errors) from the macOS unified log; default --last 1h
    --json    the versioned response envelope, timestamps in UTC

    Exit status: 0 ok, 1 error, 2 usage or bad request, 3 recorder not running, 4 permission denied.
    """

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
let detail = args.contains("--detail")
let includeSensitive = args.contains("--include-sensitive")
args.removeAll { $0 == "--json" || $0 == "--detail" || $0 == "--include-sensitive" }
let command = args.first

let localTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
    return formatter
}()

@MainActor func option(_ name: String) throws -> String? {
    guard let index = args.firstIndex(of: name) else { return nil }
    guard index + 1 < args.count else { throw ServiceError(.badRequest, "\(name) needs a value.") }
    defer { args.removeSubrange(index...index + 1) }
    return args[index + 1]
}

@MainActor func requireNoExtraArguments(_ expected: Int) throws {
    guard args.count == expected else { throw ServiceError(.badRequest, "Unexpected arguments: \(args.dropFirst(expected).joined(separator: " "))\n\n\(usage)") }
}

@MainActor func output(_ response: Response, text: () -> String) {
    print(json ? String(decoding: try! GhostTraceJSON.encoder().encode(response), as: UTF8.self) : text())
}

@MainActor func describe(_ status: RecorderStatus) -> String {
    var lines = ["Recorder: \(status.state.rawValue.replacingOccurrences(of: "_", with: " ")) (pid \(status.pid), started \(localTime.string(from: status.startedAt)))"]
    if let pausedAt = status.pausedAt { lines.append("Paused since \(localTime.string(from: pausedAt)); nothing is being recorded.") }
    lines.append("Database: \(status.databasePath)" + (status.databaseBytes.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) on disk, schema \(status.schemaVersion ?? 1))" } ?? ""))
    lines.append("  \(status.eventCount) events, oldest \(status.retainedSince.map(localTime.string) ?? "none"), retention \(status.retentionDays) days, \(status.droppedEvents) dropped by the queue")
    if let on = status.systemMonitor { lines.append("Record System Activity: " + (on ? "on (turn off: ghosttrace config --system off)" : "off; CPU, GPU, network, disk and battery aren't recorded (turn on: ghosttrace config --system on)")) }
    if let mcp = status.mcpAccess { lines.append("AI agents (MCP): " + (mcp ? "allowed, read-only (turn off: ghosttrace mcp deny)" : "not allowed (allow: ghosttrace mcp allow)")) }
    lines.append("Capabilities:")
    lines += status.capabilities.map { "  \($0.state.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \($0.name): \($0.detail)" }
    return lines.joined(separator: "\n")
}

/// `--last`, `--from [--to]`, and for investigations `--at [--within]`. Defaults to the last 24 hours.
@MainActor func timeWindow(allowAt: Bool = false, defaultSpan: TimeInterval = 86400) throws -> (from: Date, to: Date) {
    let (at, within) = allowAt ? (try option("--at"), try option("--within")) : (nil, nil)
    let window = try TimeArgument.window(at: at, within: within, last: try option("--last"), from: try option("--from"), to: try option("--to"),
                                         allowAt: allowAt, defaultSpan: defaultSpan)
    return (window.start, window.end)
}

/// One short answer per wake. Evidence and reasoning are in `--detail` and `--json`.
@MainActor func summarize(_ investigation: WakeInvestigation) -> String {
    let time = { (date: Date?) in date.map(localTime.string) ?? "never" }
    let count = investigation.wakes.count
    var lines = ["\(count == 0 ? "No" : String(count)) wake\(count == 1 ? "" : "s") between \(time(investigation.from)) and \(time(investigation.to))."]
    for wake in investigation.wakes {
        lines += ["", "\(localTime.string(from: wake.at))  \(wake.type.title)", "  \(wake.summary)"]
        lines += wake.findings.filter { $0.confidence == .correlated }.map { "  Afterwards: \($0.statement) Timing only, not a cause." }
    }
    if !investigation.keyLimits.isEmpty { lines += ["", "What GhostTrace couldn't see:"] + investigation.keyLimits.map { "  - \($0)" } }
    lines += ["", "\"Likely\" is GhostTrace's reading of macOS's power log, not a certainty. Add --detail for evidence."]
    return lines.joined(separator: "\n")
}

@MainActor func describe(_ investigation: WakeInvestigation) -> String {
    let time = { (date: Date?) in date.map(localTime.string) ?? "never" }
    var lines = ["Wakes between \(time(investigation.from)) and \(time(investigation.to)): \(investigation.wakes.count)",
                 "Power log imported: \(time(investigation.powerLogSince)) to \(time(investigation.powerLogThrough)). GhostTrace recording since \(time(investigation.recordingSince))."]
    for wake in investigation.wakes {
        lines += ["", "\(localTime.string(from: wake.at))  \(wake.type.rawValue.replacingOccurrences(of: "_", with: " ")) wake"]
        for finding in wake.findings {
            lines.append("  \(finding.confidence.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(finding.statement)")
            lines.append("              \(finding.basis)")
            lines.append("              evidence: \(finding.evidence.map(\.uuidString).joined(separator: " "))")
        }
        for limit in wake.limits {
            lines.append("  limit       \(limit.statement)" + (limit.evidence.isEmpty ? "" : " (evidence: \(limit.evidence.map(\.uuidString).joined(separator: " ")))"))
        }
    }
    if !investigation.limits.isEmpty { lines += ["", "Limits:"] + investigation.limits.map { "  \($0.statement)" } }
    lines += ["",
              "observed: recorded by macOS. likely: GhostTrace's interpretation of the cited evidence. correlated: close in time only, not a cause.",
              "unknown: the recorded evidence can't answer it. See any evidence with: ghosttrace event ID"]
    return lines.joined(separator: "\n")
}

@MainActor func line(_ event: Event) -> String {
    var parts = [localTime.string(from: event.occurredAt), event.kind.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)]
    if let subject = event.subject {
        parts += [subject.name, subject.bundleID, subject.pid.map { "pid \($0)" }].compactMap { $0 }
    }
    if let end = event.endedAt { parts.append("until \(localTime.string(from: end))") }
    parts += event.payload.filter { $0.key != "sample" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    if let sample = ResourceSample(event) {
        parts.append("top=" + sample.processes.prefix(3).map { "\($0.name) \(ResourceSample.bytes($0.footprint))" }.joined(separator: ", "))
    }
    parts.append(event.id.uuidString)
    return parts.joined(separator: "  ")
}

/// Relative paths are taken from the current directory; the recorder resolves symlinks.
func absolute(_ path: String) -> String {
    ((path.hasPrefix("/") ? path : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)) as NSString).standardizingPath
}

struct Export: Encodable {
    var apiVersion = IPC.apiVersion
    var exportedAt: Date
    var from: Date
    var to: Date
    var kind: EventKind?
    /// True when watched file paths were replaced by a hash.
    var redacted: Bool
    var retainedSince: Date?
    var events: [Event]
}

let shortTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

/// Every finding with its basis and evidence ids, as `--detail` shows them.
func detailLines(_ findings: [Finding], _ limits: [Limit]) -> [String] {
    var lines: [String] = []
    for finding in findings {
        lines.append("  \(finding.confidence.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(finding.statement)")
        lines.append("              \(finding.basis)")
        lines.append("              evidence: \(finding.evidence.map(\.uuidString).joined(separator: " "))")
    }
    for limit in limits {
        lines.append("  limit       \(limit.statement)" + (limit.evidence.isEmpty ? "" : " (evidence: \(limit.evidence.map(\.uuidString).joined(separator: " ")))"))
    }
    return lines
}

@MainActor func limitLines(_ limits: [Limit], gaps: [DateInterval] = []) -> [String] {
    guard !limits.isEmpty || !gaps.isEmpty else { return [] }
    var lines = ["", "What GhostTrace couldn't see:"] + limits.map { "  - \($0.statement)" }
    lines += gaps.suffix(5).map { "  - No samples from \(localTime.string(from: $0.start)) to \(localTime.string(from: $0.end))." }
    if gaps.count > 5 { lines.append("  - (\(gaps.count - 5) earlier stretches without samples not shown)") }
    return lines
}

@MainActor func describe(_ summary: ResourceSummary) -> String {
    let total = summary.memoryTotal.map { " of \(ResourceSample.bytes($0))" } ?? ""
    var lines = ["Memory between \(localTime.string(from: summary.from)) and \(localTime.string(from: summary.to)): \(summary.sampleCount) sample\(summary.sampleCount == 1 ? "" : "s")."]
    if let peak = summary.points.max(by: { $0.memoryUsedPeak < $1.memoryUsedPeak }) {
        let average = summary.points.map { $0.memoryUsedAverage * UInt64($0.samples) }.reduce(0, +) / UInt64(max(summary.sampleCount, 1))
        lines.append("  Used: average \(ResourceSample.bytes(average)), peak \(ResourceSample.bytes(peak.memoryUsedPeak))\(total) around \(shortTime.string(from: peak.start)).")
        let worst = summary.points.map(\.pressure).max()!
        if worst == .normal {
            lines.append("  Pressure: normal throughout.")
        } else {
            lines.append("  Pressure: reached \(worst.rawValue), first around \(shortTime.string(from: summary.points.first { $0.pressure == worst }!.start)).")
        }
        if let memoryTotal = summary.memoryTotal, memoryTotal > 0 {
            let bars = Array("▁▂▃▄▅▆▇█")
            lines.append("  " + summary.points.map { bars[min(bars.count - 1, Int(Double($0.memoryUsedAverage) / Double(memoryTotal) * Double(bars.count)))] }.map(String.init).joined()
                         + "  (memory used; each mark is \(ResourceAnalyzer.duration(summary.to.timeIntervalSince(summary.from) / 60)); stretches without samples are left out)")
        }
    }
    if !summary.top.isEmpty {
        lines += ["", "Top \(summary.top.count) by peak memory:", "  " + ["PEAK", "AT", "LATEST", "CPU MAX", "PID", "NAME"].enumerated().map { i, h in i == 5 ? h : h.padding(toLength: [9, 9, 9, 8, 7][i], withPad: " ", startingAt: 0) }.joined(separator: " ")]
        for p in summary.top {
            let cols = [ResourceSample.bytes(p.peakFootprint), shortTime.string(from: p.peakAt), ResourceSample.bytes(p.latestFootprint),
                        p.peakCPU.map { String(format: "%.0f%%", $0) } ?? "-", String(p.pid)]
            lines.append("  " + cols.enumerated().map { $1.padding(toLength: [9, 9, 9, 8, 7][$0], withPad: " ", startingAt: 0) }.joined(separator: " ") + " " + p.name)
        }
    }
    lines += limitLines(summary.limits, gaps: summary.samplingGaps)
    return lines.joined(separator: "\n")
}

/// One line per metric: the duration-weighted average and the peak across the window's chart points, or "not recorded".
@MainActor func describeSystem(_ summary: ResourceSummary) -> String {
    let points = summary.points
    let rate = { (value: Double) in value < 1e6 ? String(format: "%.0f KB/s", value / 1e3) : String(format: "%.1f MB/s", value / 1e6) }
    let metric = { (name: String, text: String?) in "  " + (name + ":").padding(toLength: 12, withPad: " ", startingAt: 0) + (text ?? "not recorded") }
    let battery = points.last { $0.charge != nil }
    var lines = ["System activity between \(localTime.string(from: summary.from)) and \(localTime.string(from: summary.to)): \(summary.sampleCount) sample\(summary.sampleCount == 1 ? "" : "s").",
                 metric("CPU", summary.average { $0.cpuBusyAverage }.map { String(format: "average %.0f%%, peak %.0f%%", $0 * 100, (points.compactMap(\.cpuPeak).max() ?? 0) * 100) }),
                 metric("GPU", summary.average(\.gpuAverage).map { String(format: "average %.0f%%, peak %d%%", $0, points.compactMap(\.gpuPeak).max() ?? 0) }),
                 metric("Network", summary.average(\.networkRate).map { "average \(rate($0)), peak \(rate(Double(points.compactMap(\.networkPeakRate).max() ?? 0)))" }),
                 metric("Disk", summary.average(\.diskRate).map { "average \(rate($0)), peak \(rate(Double(points.compactMap(\.diskPeakRate).max() ?? 0)))" }),
                 metric("Battery", battery.map { "\($0.charge!)% (latest" + ($0.onBattery.map { $0 ? ", on battery)" : ", on power)" } ?? ")") }),
                 metric("Free space", points.last { $0.freeSpace != nil }.map { "\(ResourceSample.fileBytes($0.freeSpace!)) (latest)" })]
    lines += limitLines(summary.limits, gaps: summary.samplingGaps)
    return lines.joined(separator: "\n")
}

@MainActor func summarize(_ investigation: MemoryInvestigation) -> String {
    let count = investigation.spikes.count
    var lines = ["\(count == 0 ? "No" : String(count)) memory spike\(count == 1 ? "" : "s") between \(localTime.string(from: investigation.from)) and \(localTime.string(from: investigation.to)) (\(investigation.sampleCount) samples)."]
    for spike in investigation.spikes {
        lines += ["", "\(localTime.string(from: spike.from)) to \(shortTime.string(from: spike.to))  memory \(ResourceSample.bytes(spike.memoryBefore)) to \(ResourceSample.bytes(spike.memoryAfter))"
                  + (spike.pressureAfter != spike.pressureBefore ? ", pressure \(spike.pressureBefore.rawValue) to \(spike.pressureAfter.rawValue)" : "")]
        if detail {
            lines += detailLines(spike.findings, spike.limits)
        } else {
            lines.append("  \(spike.summary)")
            lines += spike.findings.filter { $0.confidence == .correlated }.map { "  Also: \($0.statement) Timing only, not a cause." }
        }
    }
    lines += limitLines(investigation.limits, gaps: investigation.samplingGaps)
    lines += ["", detail ? "observed: measured by macOS. likely: GhostTrace's comparison of the measurements. correlated: close in time only. See any evidence with: ghosttrace event ID"
                         : "\"Likely\" is GhostTrace's comparison of sampled memory, not a certainty. Add --detail for evidence."]
    return lines.joined(separator: "\n")
}

@MainActor func summarize(_ investigation: FileChangeInvestigation) -> String {
    let count = investigation.changes.count
    var lines = ["\(count == 0 ? "No" : String(count)) change\(count == 1 ? "" : "s") to \(investigation.path) recorded between \(localTime.string(from: investigation.from)) and \(localTime.string(from: investigation.to))."]
    if let watch = investigation.watchedBy {
        lines.append("Watched since \(localTime.string(from: watch.since))" + (watch.path == investigation.path ? "." : " (as part of \(watch.path))."))
    }
    for change in investigation.changes {
        let when = change.endedAt.map { "\(localTime.string(from: change.at)) to \(localTime.string(from: $0))" } ?? localTime.string(from: change.at)
        lines += ["", "\(when)  \(change.path)" + (change.changes.isEmpty ? "" : "  (\(change.changes.joined(separator: ", ")))")]
        if detail {
            lines += detailLines(change.findings, [])
        } else {
            lines.append("  \(change.summary)")
            lines += change.findings.filter { $0.confidence == .correlated }.map { "  Before it: \($0.statement) Timing only, not a cause." }
        }
    }
    lines += limitLines(investigation.limits)
    lines += ["", "FSEvents records that a path changed, never which process changed it." + (detail ? " See any evidence with: ghosttrace event ID" : " Add --detail for evidence.")]
    return lines.joined(separator: "\n")
}

/// One incident: a heading, then the short answer and what was close in time, or every finding with `--detail`.
@MainActor func incidentLines(_ heading: String, _ summary: String, _ findings: [Finding]) -> [String] {
    ["", heading] + (detail ? detailLines(findings, [])
                     : ["  \(summary)"] + findings.filter { $0.confidence == .correlated }.map { "  Also: \($0.statement) Timing only, not a cause." })
}

@MainActor func legend(_ compared: String) -> String {
    detail ? "observed: measured by macOS. likely: GhostTrace's comparison of the measurements. correlated: close in time only. See any evidence with: ghosttrace event ID"
        : "\"Likely\" is GhostTrace's comparison of \(compared), not a certainty. Add --detail for evidence."
}

@MainActor func summarize(_ investigation: BatteryInvestigation) -> String {
    let count = investigation.sessions.count
    // Without a battery, or without samples, the limits say which.
    var lines = ["\(count == 0 ? "No" : String(count)) stretch\(count == 1 ? "" : "es") on battery between \(localTime.string(from: investigation.from)) and \(localTime.string(from: investigation.to))."]
    for session in investigation.sessions {
        let watts = session.averageWatts.map { String(format: ", %.1f W average", $0) } ?? ""
        lines += incidentLines("\(localTime.string(from: session.from)) to \(shortTime.string(from: session.to))  \(session.startCharge)% to \(session.endCharge)%\(watts)",
                               session.summary, session.findings)
    }
    lines += limitLines(investigation.limits)
    lines += ["", legend("measured energy")]
    return lines.joined(separator: "\n")
}

@MainActor func summarize(_ investigation: NetworkInvestigation) -> String {
    let count = investigation.spikes.count
    var lines = ["\(count == 0 ? "No" : String(count)) network spike\(count == 1 ? "" : "s") between \(localTime.string(from: investigation.from)) and \(localTime.string(from: investigation.to))."]
    for spike in investigation.spikes {
        lines += incidentLines("\(localTime.string(from: spike.from)) to \(shortTime.string(from: spike.to))  \(ResourceSample.fileBytes(spike.received)) in, \(ResourceSample.fileBytes(spike.sent)) out",
                               spike.summary, spike.findings)
    }
    lines += limitLines(investigation.limits)
    lines += ["", legend("nettop's per-process counts")]
    return lines.joined(separator: "\n")
}

@MainActor func summarize(_ investigation: DiskInvestigation) -> String {
    let count = investigation.incidents.count
    var lines = ["\(count == 0 ? "No" : String(count)) free-space drop\(count == 1 ? "" : "s") or write burst\(count == 1 ? "" : "s") between \(localTime.string(from: investigation.from)) and \(localTime.string(from: investigation.to))."]
    for incident in investigation.incidents {
        let free = incident.freeSpaceBefore.flatMap { before in incident.freeSpaceAfter.map { "free \(ResourceSample.fileBytes(before)) to \(ResourceSample.fileBytes($0)), " } } ?? ""
        lines += incidentLines("\(localTime.string(from: incident.from)) to \(shortTime.string(from: incident.to))  \(free)\(ResourceSample.fileBytes(incident.written)) written",
                               incident.summary, incident.findings)
    }
    lines += limitLines(investigation.limits)
    lines += ["", legend("measured writes")]
    return lines.joined(separator: "\n")
}

@MainActor func describeWatches(_ status: RecorderStatus) -> String {
    guard let watches = status.watchedPaths else { return "This recorder predates file watching. Restart RecorderAgent with the current build." }
    guard !watches.isEmpty else { return "Not watching anything. Add a file or folder with: ghosttrace watch add PATH" }
    var lines = ["Watching \(watches.count) path\(watches.count == 1 ? "" : "s") (changes are recorded, not file contents):"]
    lines += watches.map { "  \($0.path)  since \(localTime.string(from: $0.since))" }
    if let capability = status.capabilities.first(where: { $0.id == "file-watch" }) { lines.append("FSEvents: \(capability.state.rawValue). \(capability.detail)") }
    return lines.joined(separator: "\n")
}

do {
    let client = RecorderClient()
    switch command {
    case "status":
        try requireNoExtraArguments(1)
        let status = try client.status()
        output(Response(status: status)) { describe(status) }

    case "events":
        let kind = try option("--kind").map { text in
            guard let kind = EventKind(rawValue: text) else { throw ServiceError(.badRequest, "Unknown kind '\(text)'.") }
            return kind
        }
        let limit = try option("--limit").map { text in
            guard let limit = Int(text), (1...EventQuery.maxLimit).contains(limit) else {
                throw ServiceError(.badRequest, "--limit must be 1...\(EventQuery.maxLimit).")
            }
            return limit
        } ?? 200
        let cursor = try option("--cursor")
        let window = try timeWindow()
        try requireNoExtraArguments(1)
        let page = try client.events(EventQuery(from: window.from, to: window.to, kind: kind, limit: limit, cursor: cursor))
        output(Response(page: page)) {
            var lines = page.events.isEmpty ? ["No events recorded between \(localTime.string(from: window.from)) and \(localTime.string(from: window.to))."] : page.events.map(line)
            if let oldest = page.retainedSince, oldest > window.from {
                lines.append("Note: nothing is stored before \(localTime.string(from: oldest)); earlier activity was not recorded or is past retention.")
            }
            if let next = page.nextCursor { lines.append("More events: add --cursor \(next)") }
            return lines.joined(separator: "\n")
        }

    case "event":
        guard args.count == 2, let id = UUID(uuidString: args[1]) else { throw ServiceError(.badRequest, "usage: ghosttrace event ID [--json]") }
        let event = try client.event(id: id)
        output(Response(event: event)) { String(decoding: try! GhostTraceJSON.encoder(pretty: true).encode(event), as: UTF8.self) }

    case "investigate":
        let subject = args.count >= 2 ? args[1] : ""
        switch subject {
        case "wake":
            let window = try timeWindow(allowAt: true)
            try requireNoExtraArguments(2)
            // The recorder reads the power log before answering, which takes a few seconds.
            let investigation = try RecorderClient(timeout: 30).investigateWake(DateInterval(start: window.from, end: window.to))
            output(Response(investigation: investigation)) { detail ? describe(investigation) : summarize(investigation) }
        case "memory":
            let window = try timeWindow(allowAt: true)
            try requireNoExtraArguments(2)
            let investigation = try RecorderClient(timeout: 30).investigateMemory(DateInterval(start: window.from, end: window.to))
            output(Response(memoryInvestigation: investigation)) { summarize(investigation) }
        case "file-change":
            guard let path = try option("--path") else { throw ServiceError(.badRequest, "investigate file-change needs --path PATH.") }
            let window = try timeWindow()
            try requireNoExtraArguments(2)
            let investigation = try RecorderClient(timeout: 30).investigateFileChange(path: absolute(path), DateInterval(start: window.from, end: window.to))
            output(Response(fileChangeInvestigation: investigation)) { summarize(investigation) }
        case "battery":
            let window = try timeWindow(allowAt: true)
            try requireNoExtraArguments(2)
            // Battery and network read the power log first, as wake does.
            let investigation = try RecorderClient(timeout: 30).investigateBattery(DateInterval(start: window.from, end: window.to))
            output(Response(batteryInvestigation: investigation)) { summarize(investigation) }
        case "network":
            let window = try timeWindow(allowAt: true)
            try requireNoExtraArguments(2)
            let investigation = try RecorderClient(timeout: 30).investigateNetwork(DateInterval(start: window.from, end: window.to))
            output(Response(networkInvestigation: investigation)) { summarize(investigation) }
        case "disk":
            let window = try timeWindow(allowAt: true)
            try requireNoExtraArguments(2)
            let investigation = try RecorderClient(timeout: 30).investigateDisk(DateInterval(start: window.from, end: window.to))
            output(Response(diskInvestigation: investigation)) { summarize(investigation) }
        default:
            throw ServiceError(.badRequest, "usage: ghosttrace investigate wake | memory | battery | network | disk | file-change --path PATH (see ghosttrace help)")
        }

    case "memory":
        let top = try option("--top").map { text in
            guard let top = Int(text), (1...ResourceAnalyzer.maxTop).contains(top) else { throw ServiceError(.badRequest, "--top must be 1...\(ResourceAnalyzer.maxTop).") }
            return top
        } ?? 10
        let window = try timeWindow(defaultSpan: 3600)
        try requireNoExtraArguments(1)
        let summary = try client.resources(DateInterval(start: window.from, end: window.to), top: top, points: 60)
        output(Response(resources: summary)) { describe(summary) }

    case "system":
        let window = try timeWindow(defaultSpan: 3600)
        try requireNoExtraArguments(1)
        let summary = try client.resources(DateInterval(start: window.from, end: window.to), top: 1, points: 60)
        output(Response(resources: summary)) { describeSystem(summary) }

    case "watch":
        let action = args.count >= 2 ? args[1] : "list"
        let status: RecorderStatus
        switch (action, args.count) {
        case ("list", ...2): status = try client.status()
        case ("add", 3): status = try client.watch(add: absolute(args[2]))
        case ("remove", 3): status = try client.watch(remove: absolute(args[2]))
        default: throw ServiceError(.badRequest, "usage: ghosttrace watch [list | add PATH | remove PATH] [--json]")
        }
        output(Response(status: status)) { describeWatches(status) }

    case "config":
        let interval = try option("--sample-interval").map(TimeArgument.duration)
        let system = try option("--system").map { text in
            guard ["on", "off"].contains(text) else { throw ServiceError(.badRequest, "--system takes on or off.") }
            return text == "on"
        }
        guard interval != nil || system != nil else { throw ServiceError(.badRequest, "usage: ghosttrace config [--sample-interval DURATION] [--system on|off] [--json]") }
        try requireNoExtraArguments(1)
        var status = try interval.map { try client.configure(sampleInterval: $0) }
        if let system {
            status = try client.configure(systemMonitor: system)
            guard status?.systemMonitor != nil else { throw ServiceError(.unsupportedVersion, "This recorder predates the system monitor switch. Reinstall GhostTrace.") }
        }
        output(Response(status: status!)) {
            [interval.map { _ in "Resource sampling every \(Int(status!.sampleInterval ?? 0)) s." },
             system.map { "Record System Activity: \($0 ? "on" : "off")." }].compactMap { $0 }.joined(separator: "\n")
        }

    case "export":
        let kind = try option("--kind").map { text in
            guard let kind = EventKind(rawValue: text) else { throw ServiceError(.badRequest, "Unknown kind '\(text)'.") }
            return kind
        }
        let file = try option("--output")
        let window = try timeWindow()
        try requireNoExtraArguments(1)
        guard !json else { throw ServiceError(.badRequest, "export always writes JSON; drop --json.") }
        var query = EventQuery(from: window.from, to: window.to, kind: kind, limit: EventQuery.maxLimit)
        var events: [Event] = []
        var retainedSince: Date?
        repeat {
            let page = try client.events(query)
            events += page.events
            retainedSince = page.retainedSince
            query.cursor = page.nextCursor
            guard events.count <= 500_000 else { throw ServiceError(.badRequest, "More than 500,000 events in this window. Export a shorter window.") }
        } while query.cursor != nil
        let document = Export(exportedAt: Date(), from: window.from, to: window.to, kind: kind, redacted: !includeSensitive,
                              retainedSince: retainedSince, events: includeSensitive ? events : events.map { $0.redacted() })
        let data = try GhostTraceJSON.encoder(pretty: true).encode(document)
        if let file {
            let path = absolute(file)
            guard !FileManager.default.fileExists(atPath: path) else { throw ServiceError(.badRequest, "\(path) already exists; choose another file.") }
            guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw ServiceError(.internalError, "Couldn't write \(path).")
            }
            print("Exported \(events.count) events to \(path)" + (includeSensitive ? "." : ", with watched file paths replaced by a hash."))
        } else {
            print(String(decoding: data, as: UTF8.self))
        }

    case "pause", "resume":
        try requireNoExtraArguments(1)
        let status = try command == "pause" ? client.pause() : client.resume()
        output(Response(status: status)) { describe(status) }

    case "mcp":
        switch (args.count, args.dropFirst().first) {
        case (1, _):
            guard !json else { throw ServiceError(.badRequest, "The MCP server always speaks JSON-RPC; drop --json.") }
            let server = MCPServer { request in
                let client = RecorderClient(timeout: 30, client: .mcp)
                // A recorder older than the access switch ignores `client` and would answer without the user's consent.
                guard try client.status().mcpAccess != nil else {
                    throw ServiceError(.unsupportedVersion, "This recorder predates AI agent access control, so the MCP server won't use it. Reinstall GhostTrace.")
                }
                return try client.send(request)
            }
            // Unbuffered writes: the agent waits on each reply.
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty, let reply = server.handle(Data(line.utf8)) else { continue }
                FileHandle.standardOutput.write(reply + Data("\n".utf8))
            }
        case (2, "allow"?), (2, "deny"?):
            let status = try client.configure(mcpAccess: args[1] == "allow")
            guard status.mcpAccess != nil else { throw ServiceError(.unsupportedVersion, "This recorder predates MCP access control. Reinstall GhostTrace.") }
            output(Response(status: status)) {
                args[1] == "allow" ? "AI agents connected through `ghosttrace mcp` can now read the recording (read-only). Revoke with: ghosttrace mcp deny"
                    : "AI agents can no longer read the recording through `ghosttrace mcp`."
            }
        default:
            throw ServiceError(.badRequest, "usage: ghosttrace mcp [allow | deny] [--json]")
        }

    case "logs":
        let last = try TimeArgument.duration(try option("--last") ?? "1h")
        try requireNoExtraArguments(1)
        // `log show --last` takes minutes, hours or days.
        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        log.arguments = ["show", "--predicate", "subsystem == \"\(GhostTracePaths.logSubsystem)\"", "--last", "\(Int((last / 60).rounded(.up)))m", "--info", "--style", "compact"]
        try log.run()
        log.waitUntilExit()
        exit(log.terminationStatus)

    case "help", "--help", "-h":
        print(usage)

    default:
        throw ServiceError(.badRequest, (command.map { "Unknown command '\($0)'.\n\n" } ?? "") + usage)
    }
} catch let error as ServiceError {
    if json {
        output(Response(error: error)) { "" }
    } else if command == "status", error.code == .recorderNotRunning {
        print("Recorder: stopped\n\(error.message)")
    } else {
        FileHandle.standardError.write(Data("ghosttrace: \(error.message)\n".utf8))
    }
    let status: Int32 = switch error.code {
    case .badRequest, .unsupportedVersion: 2
    case .recorderNotRunning: 3
    case .permissionDenied: 4
    case .notFound, .protocolError, .internalError: 1
    }
    exit(status)
} catch {
    FileHandle.standardError.write(Data("ghosttrace: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
