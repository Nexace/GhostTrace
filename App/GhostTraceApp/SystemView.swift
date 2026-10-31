import AppKit
import Charts
import GhostTraceIPC
import InvestigationKit
import RecorderCore
import SwiftUI

/// What the Mac is doing now (six tiles, polled every 2 s while this pane is on screen) and the stored history below.
struct SystemView: View {
    @Environment(RecorderModel.self) private var model
    @State private var live = Live()
    @State private var problem: ServiceError?
    /// False from the moment the Mac or its display goes to sleep until it wakes.
    @State private var awake = true
    private let client = RecorderClient(timeout: 2)
    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)]
    private let workspace = NSWorkspace.shared.notificationCenter

    var body: some View {
        Group {
            if let problem, live.latest == nil, !systemOff {
                RecorderProblemView(problem: problem)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let on = model.status?.systemMonitor {
                            Toggle("Record System Activity", isOn: Binding(get: { on }, set: { value in Task { await model.setSystemMonitor(value) } }))
                                .toggleStyle(.switch)
                                .help("CPU, GPU, network, disk and battery readings, and alerts. Memory, wakes, launches and file changes are recorded either way.")
                        }
                        // A failed poll after a good one: the tiles still show the last reading, so say they are stale.
                        if problem != nil, !systemOff {
                            Label("Recorder not responding. Showing the last reading.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        if systemOff {
                            Text("System monitoring is off").font(.title3).foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(live.tiles(capabilities: model.status?.capabilities ?? [])) { SystemTile(tile: $0) }
                            }
                            .opacity(problem == nil ? 1 : 0.5)
                        }
                        HistorySection()
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("System")
        // Ends with the pane or the window, so nothing polls in the background.
        .task { await poll() }
        .onReceive(workspace.publisher(for: NSWorkspace.willSleepNotification)) { _ in awake = false }
        .onReceive(workspace.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in awake = false }
        .onReceive(workspace.publisher(for: NSWorkspace.didWakeNotification)) { _ in awake = true }
        .onReceive(workspace.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in awake = true }
    }

    private var systemOff: Bool { model.status?.systemMonitor == false }

    /// The client blocks on IPC, so it runs off the main actor.
    private func poll() async {
        let client = client
        while !Task.isCancelled {
            // Asleep, minimised, hidden or on another Space: nothing is looking, so don't ask the recorder. Off: nothing to show.
            if awake, !systemOff, NSApp.occlusionState.contains(.visible) {
                switch await Task.detached(operation: { Result { try client.live() } }).value {
                case .success(let reading): live.add(reading); problem = nil
                case .failure(let error): problem = error as? ServiceError ?? ServiceError(.internalError, "\(error)")
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// The stored history from `resources`. It has its own state, so the live polling doesn't rebuild its charts.
private struct HistorySection: View {
    enum Span: String, CaseIterable, Identifiable {
        case hour = "1 h", day = "24 h", week = "7 d"
        var id: Self { self }
        var seconds: TimeInterval { switch self { case .hour: 3600; case .day: 86400; case .week: 7 * 86400 } }
    }

    @State private var span = Span.hour
    @State private var history: ResourceSummary?
    @State private var failure: String?
    /// Battery, network and disk, run only on "Explain this range" and cleared when the span changes.
    @State private var explained: [Explained]?
    @State private var explaining = false
    private let client = RecorderClient(timeout: 30)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "History") {
                Picker("Window", selection: $span) { ForEach(Span.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let history {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 16) {
                    let points = history.points
                    // cpuBusyAverage is a fraction of 1.
                    HistoryChart(title: "CPU (%)", domain: 0...100, points: points.map { ($0.start, $0.cpuBusyAverage.map { $0 * 100 }) })
                    HistoryChart(title: "GPU (%)", domain: 0...100, points: points.map { ($0.start, $0.gpuAverage.map(Double.init)) })
                    HistoryChart(title: "Memory (GB)", domain: nil, points: points.map { ($0.start, Double($0.memoryUsedAverage) / Double(1 << 30)) })
                    HistoryChart(title: "Network (MB/s)", domain: nil, points: points.map { ($0.start, $0.networkRate.map { Double($0) / Double(1 << 20) }) })
                    HistoryChart(title: "Disk (MB/s)", domain: nil, points: points.map { ($0.start, $0.diskRate.map { Double($0) / Double(1 << 20) }) })
                    HistoryChart(title: "Battery (%)", domain: 0...100, points: points.map { ($0.start, $0.charge.map(Double.init)) })
                }
            } else if let failure {
                Text("History unavailable: \(failure)").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 10) {
                Button("Explain this range") { Task { await explain() } }.disabled(explaining)
                if explaining { ProgressView().controlSize(.small) }
                if span.seconds > BatteryInvestigator.maxWindow {
                    Text("Explains the last 48 h only: investigations cover at most 48 hours.").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(explained ?? [], id: \.title) { ExplainedSection(explained: $0) }
        }
        .task(id: span) { explained = nil; await load() }
    }

    /// The three investigations over the selected span, capped at 48 h. The client blocks on IPC, so they run off the main actor.
    private func explain() async {
        explaining = true
        defer { explaining = false }
        let (client, now, seconds) = (client, Date(), min(span.seconds, BatteryInvestigator.maxWindow))
        let selected = span
        let result = await Task.detached {
            let window = DateInterval(start: now.addingTimeInterval(-seconds), end: now)
            let time = { (date: Date) in date.formatted(date: .abbreviated, time: .shortened) }
            return [
                Explained("Battery", Result { try client.investigateBattery(window) }) { investigation in
                    (investigation.sessions.map { ("\(time($0.from)) to \(time($0.to)) · \($0.startCharge)% to \($0.endCharge)%", $0.summary, $0.findings) }, investigation.limits)
                },
                Explained("Network", Result { try client.investigateNetwork(window) }) { investigation in
                    (investigation.spikes.map { ("\(time($0.from)) to \(time($0.to)) · \(ResourceSample.fileBytes($0.received)) in, \(ResourceSample.fileBytes($0.sent)) out", $0.summary, $0.findings) },
                     investigation.limits)
                },
                Explained("Disk", Result { try client.investigateDisk(window) }) { investigation in
                    (investigation.incidents.map { ("\(time($0.from)) to \(time($0.to)) · \(ResourceSample.fileBytes($0.written)) written", $0.summary, $0.findings) }, investigation.limits)
                },
            ]
        }.value
        // A span picked while this ran gets its own explanation.
        if span == selected { explained = result }
    }

    private func load() async {
        // The previous span's charts must not stay under the new picker value while this loads.
        (history, failure) = (nil, nil)
        let (client, now, seconds) = (client, Date(), span.seconds)
        let result = await Task.detached {
            Result { try client.resources(DateInterval(start: now.addingTimeInterval(-seconds), end: now), top: 1, points: 120) }
        }.value
        // A slower, older span must not overwrite the one now selected.
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let summary): (history, failure) = (summary, nil)
        case .failure(let error): (history, failure) = (nil, (error as? ServiceError)?.message ?? "\(error)")
        }
    }
}

/// One investigation, kept as display rows only, so its evidence events aren't held by the window.
private struct Explained: Sendable {
    typealias Row = (heading: String, summary: String, findings: [Finding])
    let title: String
    var rows: [Row] = []
    var limits: [Limit] = []
    var failure: String?

    init<T>(_ title: String, _ result: Result<T, any Error>, rows: (T) -> ([Row], [Limit])) {
        self.title = title
        switch result {
        case .success(let investigation): (self.rows, limits) = rows(investigation)
        case .failure(let error): failure = (error as? ServiceError)?.message ?? "\(error)"
        }
    }
}

private struct ExplainedSection: View {
    let explained: Explained

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(explained.title)
            if let failure = explained.failure {
                Text("Unavailable: \(failure)").font(.callout).foregroundStyle(.secondary)
            } else if explained.rows.isEmpty {
                Text("Nothing to explain in this range.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(explained.rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.heading).monospacedDigit().bold()
                    Text(row.summary)
                    ForEach(row.findings.filter { $0.confidence == .correlated }, id: \.statement) {
                        Text("Also: \($0.statement) Timing only, not a cause.").font(.callout).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Evidence") { EvidenceList(findings: row.findings, limits: []) }.font(.callout)
                }
                .padding(.vertical, 4)
            }
            if !explained.limits.isEmpty {
                DisclosureGroup("What GhostTrace couldn't see") { EvidenceList(findings: [], limits: explained.limits) }.font(.callout)
            }
        }
    }
}

// MARK: - Tiles

private struct SystemTile: View {
    let tile: Live.Tile

    var body: some View {
        StatCard(title: tile.title, value: tile.value, detail: tile.detail, symbol: tile.symbol, color: tile.color)
            .overlay(alignment: .topTrailing) {
                if tile.spark.count > 1 {
                    Sparkline(values: tile.spark, domain: tile.domain)
                        .stroke(tile.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 80, height: 28).padding(14)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tile.label)
    }
}

/// A plain line through up to 150 values, scaled to `domain` (or to 0...the largest value). Cheaper than a chart.
private struct Sparkline: Shape {
    let values: [Double]
    let domain: ClosedRange<Double>?

    func path(in rect: CGRect) -> Path {
        let top = domain?.upperBound ?? max((values.max() ?? 1) * 1.1, 0.001), bottom = domain?.lowerBound ?? 0
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                                y: rect.maxY - rect.height * CGFloat(min(max((value - bottom) / (top - bottom), 0), 1)))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

private struct HistoryChart: View {
    let title: String
    let domain: ClosedRange<Double>?
    let points: [(Date, Double?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            if points.contains(where: { $0.1 != nil }) {
                Chart(Array(points.enumerated()), id: \.offset) { _, point in
                    if let value = point.1 { LineMark(x: .value("Time", point.0), y: .value(title, value)) }
                }
                .chartYScale(domain: domain ?? 0...(points.compactMap(\.1).max() ?? 1) * 1.1 + 0.001)
                .frame(height: 110)
                .accessibilityLabel("\(title) over the window")
            } else {
                Text("No data in this window").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            }
        }
    }
}

// MARK: - Live readings

/// The latest reading, the rates between the last two, and five minutes (150 polls) of history for each sparkline.
private struct Live {
    struct Tile: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        let value: String
        let detail: String
        /// What a screen reader says, e.g. "CPU 12 percent".
        let label: String
        let spark: [Double]
        var domain: ClosedRange<Double>? = nil
        var title: String { id }
    }

    static let keep = 150
    /// Longer than this between two readings means the Mac slept or the recorder was away: no rates across the gap.
    static let maxGap: TimeInterval = 10

    var latest: SystemReading?
    private var cpu: Double?, received: Double?, sent: Double?, read: Double?, written: Double?
    private var series: [String: [Double]] = [:]

    mutating func add(_ now: SystemReading) {
        let before = latest.flatMap { now.at.timeIntervalSince($0.at) <= Self.maxGap ? $0 : nil }
        let seconds = before.map { now.at.timeIntervalSince($0.at) } ?? 0
        let rate = { (new: UInt64?, old: UInt64?) -> Double? in
            guard let new, let old, seconds > 0 else { return nil }
            let change = Counter.delta(new, since: old)
            return change.reset ? nil : Double(change.bytes) / seconds
        }
        cpu = nil
        if let new = now.cpu, let old = before?.cpu {
            let (busy, total) = (Counter.delta(new.busy, since: old.busy), Counter.delta(new.total, since: old.total))
            if !busy.reset, !total.reset, total.bytes > 0 { cpu = 100 * Double(busy.bytes) / Double(total.bytes) }
        }
        (received, sent) = (rate(now.network?.received, before?.network?.received), rate(now.network?.sent, before?.network?.sent))
        (read, written) = (rate(now.disk?.read, before?.disk?.read), rate(now.disk?.written, before?.disk?.written))
        push("CPU", cpu)
        push("GPU", now.gpuUtilization.map(Double.init))
        push("Memory", now.memoryUsed.flatMap { used in now.memoryTotal.map { 100 * Double(used) / Double($0) } })
        push("Network", received.flatMap { r in sent.map { r + $0 } })
        push("Disk", read.flatMap { r in written.map { r + $0 } })
        push("Battery", now.battery.map { Double($0.charge) })
        latest = now
    }

    private mutating func push(_ key: String, _ value: Double?) {
        guard let value else { return }
        series[key, default: []].append(value)
        if series[key]!.count > Self.keep { series[key]!.removeFirst() }
    }

    func tiles(capabilities: [CapabilityStatus]) -> [Tile] {
        let why = { (id: String) in capabilities.first { $0.id == id }?.detail ?? "Not reported by this Mac." }
        let spark = { (key: String) in series[key] ?? [] }
        let percent = { (value: Double?) in value.map { "\(Int($0.rounded()))%" } ?? "…" }
        let spoken = { (name: String, value: Double?) in value.map { "\(name) \(Int($0.rounded())) percent" } ?? "\(name) measuring" }
        let formatter = ByteCountFormatter()
        formatter.allowsNonnumericFormatting = false  // "0 KB/s", not "Zero KB/s"
        let speed = { (bytes: Double?) in bytes.map { formatter.string(fromByteCount: Int64($0)) + "/s" } ?? "…" }
        let size = { (bytes: UInt64) in formatter.string(fromByteCount: Int64(bytes)) }
        let none = { (title: String, symbol: String, color: Color, detail: String, key: String) in
            Tile(id: title, symbol: symbol, color: color, value: "Not available", detail: detail, label: "\(title) not available. \(detail)", spark: spark(key))
        }
        let now = latest
        var tiles: [Tile] = []

        tiles.append(now?.cpu == nil && now != nil ? none("CPU", "cpu", .blue, "The recorder couldn't read CPU load.", "CPU")
                     : Tile(id: "CPU", symbol: "cpu", color: .blue, value: percent(cpu), detail: "All cores", label: spoken("CPU", cpu), spark: spark("CPU"), domain: 0...100))
        tiles.append(now?.gpuUtilization == nil && now != nil ? none("GPU", "display", .purple, why("gpu-utilization"), "GPU")
                     : Tile(id: "GPU", symbol: "display", color: .purple, value: percent(now?.gpuUtilization.map(Double.init)), detail: "Device utilization",
                            label: spoken("GPU", now?.gpuUtilization.map(Double.init)), spark: spark("GPU"), domain: 0...100))
        if let used = now?.memoryUsed, let total = now?.memoryTotal, total > 0 {
            let share = 100 * Double(used) / Double(total)
            tiles.append(Tile(id: "Memory", symbol: "memorychip", color: .pink, value: ResourceSample.bytes(used),
                              detail: "of \(ResourceSample.bytes(total)) · pressure \(now?.pressure?.rawValue ?? "unknown")",
                              label: spoken("Memory", share) + ", pressure \(now?.pressure?.rawValue ?? "unknown")", spark: spark("Memory"), domain: 0...100))
        } else {
            tiles.append(now != nil ? none("Memory", "memorychip", .pink, "The recorder couldn't read memory use.", "Memory")
                         : Tile(id: "Memory", symbol: "memorychip", color: .pink, value: "…", detail: "", label: "Memory measuring", spark: []))
        }
        tiles.append(now != nil && now?.network == nil ? none("Network", "arrow.up.arrow.down", .green, "The recorder couldn't read network counters.", "Network")
                     : Tile(id: "Network", symbol: "arrow.up.arrow.down", color: .green, value: "↓ \(speed(received))", detail: "↑ \(speed(sent))",
                            label: received == nil ? "Network measuring" : "Network, download \(speed(received)), upload \(speed(sent))", spark: spark("Network")))
        let free = now?.freeSpace.map { "\(size($0)) free" } ?? ""
        tiles.append(now != nil && now?.disk == nil ? none("Disk", "internaldrive", .orange, "The recorder couldn't read disk counters.", "Disk")
                     : Tile(id: "Disk", symbol: "internaldrive", color: .orange, value: "R \(speed(read))", detail: "W \(speed(written)) · \(free)",
                            label: read == nil ? "Disk measuring" : "Disk, read \(speed(read)), write \(speed(written)), \(free)", spark: spark("Disk")))
        if let battery = now?.battery {
            let state = battery.charging ? "Charging" : battery.onBattery ? "On battery" : "Plugged in"
            var left = ""
            if battery.onBattery, let minutes = battery.minutesToEmpty, minutes > 0 {
                left = " · " + Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) + " left"
            }
            let detail = state + (battery.watts.flatMap { $0 >= 0.05 ? String(format: " · %.1f W", $0) : nil } ?? "") + left
            tiles.append(Tile(id: "Battery", symbol: "battery.100", color: .yellow, value: "\(battery.charge)%", detail: detail,
                              label: "Battery \(battery.charge) percent. \(detail)", spark: spark("Battery"), domain: 0...100))
        } else {
            tiles.append(now != nil ? none("Battery", "battery.100", .yellow, why("battery"), "Battery")
                         : Tile(id: "Battery", symbol: "battery.100", color: .yellow, value: "…", detail: "", label: "Battery measuring", spark: []))
        }
        return tiles
    }
}
