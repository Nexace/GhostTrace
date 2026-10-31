import Foundation
import GhostTraceIPC
import InvestigationKit
import Observation
import RecorderCore
import SwiftUI

/// The window's sidebar destinations.
enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview", timeline = "Timeline", wakes = "Wakes", memory = "Memory", system = "System"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .timeline: "list.bullet"
        case .wakes: "moon"
        case .memory: "memorychip"
        case .system: "cpu"
        }
    }

    var color: Color {
        switch self {
        case .overview: .blue
        case .timeline: .indigo
        case .wakes: .teal
        case .memory: .pink
        case .system: .orange
        }
    }
}

/// A white symbol on a small rounded square, as in System Settings. Colour says what kind of thing it is, never how
/// sure GhostTrace is: that stays with the badges.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

/// Shared by the window's panes: the recorder's status (polled), and navigation between panes.
@MainActor
@Observable
final class RecorderModel {
    var status: RecorderStatus?
    var problem: ServiceError?
    var pane: Pane? = .overview
    /// Set by "Investigate This Wake"; the Wakes pane investigates around it.
    var wakeFocus: Date?
    @ObservationIgnored private let client = RecorderClient(timeout: 2)

    func poll() async {
        while !Task.isCancelled {
            await refresh { try $0.status() }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func togglePause() async {
        let paused = status?.state == .paused
        await refresh { paused ? try $0.resume() : try $0.pause() }
    }

    func setSystemMonitor(_ on: Bool) async {
        await refresh { try $0.configure(systemMonitor: on) }
    }

    /// The client blocks on IPC, so it runs off the main actor.
    private func refresh(_ call: @escaping @Sendable (RecorderClient) throws -> RecorderStatus) async {
        let client = client
        switch await Task.detached(operation: { Result { try call(client) } }).value {
        case .success(let value): (status, problem) = (value, nil)
        case .failure(let error): (status, problem) = (nil, error as? ServiceError ?? ServiceError(.internalError, "\(error)"))
        }
    }
}

// MARK: - Badges

/// A tinted capsule with a dot: the one way an evidence or capability state is shown.
struct StatusBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(tint.opacity(0.16), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

extension Confidence {
    var tint: Color {
        switch self {
        case .observed: .green
        case .likely: .blue
        case .correlated: .orange
        case .unknown: .gray
        }
    }

    var badge: StatusBadge { StatusBadge(title: rawValue.capitalized, tint: tint) }
}

extension CapabilityState {
    var badge: StatusBadge {
        switch self {
        case .observed: StatusBadge(title: "Observed", tint: .green)
        case .unverified: StatusBadge(title: "Unverified", tint: .yellow)
        case .missing: StatusBadge(title: "Missing", tint: .red)
        case .unavailable: StatusBadge(title: "Unavailable", tint: .gray)
        }
    }
}

extension Event {
    /// Gaps are their own state; everything else shows how it was recorded.
    var badge: StatusBadge {
        if kind == .eventGap { return StatusBadge(title: "Gap", tint: .purple) }
        return switch quality {
        case .directlyObserved: StatusBadge(title: "Observed", tint: .green)
        case .sampled: StatusBadge(title: "Sampled", tint: .green)
        case .imported: StatusBadge(title: "Imported", tint: .blue)
        case .inferred: StatusBadge(title: "Inferred", tint: .gray)
        }
    }

    var title: String { kind.title }
    var symbol: String { kind.symbol }

    /// One line about what the event is about.
    var subjectLine: String {
        switch kind {
        case .eventGap:
            let reason = switch payload["reason"].flatMap(GapReason.init(rawValue:)) {
            case .recorderStopped: "Recorder not running"
            case .recorderInterrupted: "Recorder interrupted"
            case .paused: "Paused by you"
            case .queueOverflow: "Events dropped (queue full)"
            case .watchDropped: "File changes dropped"
            case .powerLogHole: "Power log rolled off"
            case .systemMonitorOff: "System activity off"
            default: payload["reason"] ?? "Not recorded"
            }
            return endedAt.map { "\(reason) · \(Duration.seconds($0.timeIntervalSince(occurredAt)).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))" } ?? reason
        case .resourceSample:
            guard let sample = ResourceSample(self) else { return "Memory sample" }
            let bytes = { (value: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory) }
            return "\(bytes(sample.memoryUsed)) of \(bytes(sample.memoryTotal)) in use"
        case .fileChange:
            let path = subject?.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "?"
            return payload["replayed"] == "true" ? "\(path) (changed while GhostTrace wasn't running)" : path
        case .alert: return payload["message"] ?? ""
        case .collectorStatus:
            return (payload["state"] ?? "").replacingOccurrences(of: "_", with: " ").capitalized.replacingOccurrences(of: "Mcp", with: "MCP")
        case .wake: return "Woke from sleep"
        case .sleep: return "Went to sleep"
        default:
            return subject?.name ?? subject?.bundleID ?? payload["reason"] ?? payload["entry"] ?? ""
        }
    }
}

extension EventKind {
    var title: String {
        switch self {
        case .appLaunch: "App launch"
        case .appExit: "App quit"
        case .sleep: "Sleep"
        case .wake: "Wake"
        case .resourceSample: "Memory"
        case .fileChange: "File change"
        case .diagnostic: "Power log"
        case .collectorStatus: "Recorder"
        case .eventGap: "Gap"
        case .alert: "Alert"
        }
    }

    var symbol: String {
        switch self {
        case .appLaunch: "app.badge"
        case .appExit: "xmark.app"
        case .sleep: "moon.zzz"
        case .wake: "sun.max"
        case .resourceSample: "memorychip"
        case .fileChange: "doc"
        case .diagnostic: "bolt"
        case .collectorStatus: "record.circle"
        case .eventGap: "pause.circle"
        case .alert: "bell"
        }
    }

    /// One colour per category, shown on the kind's icon only.
    var color: Color {
        switch self {
        case .appLaunch, .appExit: .indigo
        case .sleep, .wake, .diagnostic: .teal
        case .resourceSample: .pink
        case .fileChange: .cyan
        case .alert: .orange
        case .collectorStatus, .eventGap: .gray
        }
    }
}

// MARK: - Building blocks

/// A label, a big value and a footnote, on a secondary background.
struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, color: color, size: 22)
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
            Text(value).font(.title.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        // Glass only on floating cards; lists and tables stay opaque so small text keeps its contrast.
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// Rows in a rounded, outlined box with separators between them.
struct ListBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                    if index < rows.count - 1 { Divider().padding(.leading, 12) }
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

/// A section title with an optional trailing note or action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// A badge, then a statement, the reasoning behind its confidence, and the evidence ids.
struct FindingRow: View {
    let badge: StatusBadge
    let statement: String
    let basis: String?
    let evidence: [UUID]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            badge.frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(statement)
                if let basis { Text(basis).font(.callout).foregroundStyle(.secondary) }
                if !evidence.isEmpty {
                    Text("Evidence: " + evidence.map { String($0.uuidString.prefix(8)) }.joined(separator: " · "))
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .help(evidence.map(\.uuidString).joined(separator: "\n"))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Findings, then limits, as rows. Shared by the investigation panes.
struct EvidenceList: View {
    let findings: [Finding]
    let limits: [Limit]

    var body: some View {
        ListBox {
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                FindingRow(badge: finding.confidence.badge, statement: finding.statement, basis: finding.basis, evidence: finding.evidence)
            }
            ForEach(limits, id: \.statement) { limit in
                FindingRow(badge: StatusBadge(title: "Limit", tint: .purple), statement: limit.statement, basis: nil, evidence: limit.evidence)
            }
        }
    }
}

/// Shown instead of a pane's content when the recorder can't be reached.
struct RecorderProblemView: View {
    let problem: ServiceError

    var body: some View {
        ContentUnavailableView {
            Label(problem.code == .recorderNotRunning ? "Recorder not running" : "Can't reach the recorder", systemImage: "record.circle")
        } description: {
            Text(problem.code == .recorderNotRunning
                 ? "Nothing is being recorded. Turn on Record in Background in the GhostTrace menu."
                 : problem.message)
        }
    }
}

extension Date {
    /// Local time of day with seconds, e.g. 09:41:07.
    var timeOfDay: String { formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) }
}
