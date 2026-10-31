import GhostTraceIPC
import InvestigationKit
import RecorderCore
import SwiftUI

/// Wake investigations from the recorder: one short answer per wake, its findings with their evidence, and what couldn't be seen.
struct WakesView: View {
    enum Span: String, CaseIterable, Identifiable {
        case hour = "Hour", night = "Last Night", day = "24 Hours", twoDays = "2 Days", around = "Around"
        var id: Self { self }
    }

    @Environment(RecorderModel.self) private var model
    @State private var span = Span.day
    @State private var around = Date()
    @State private var investigation: WakeInvestigation?
    @State private var expanded: Date?
    @State private var problem: ServiceError?
    @State private var busy = false
    /// The recorder reads the power log first, which takes a few seconds.
    private let client = RecorderClient(timeout: 30)

    var body: some View {
        Group {
            if let problem, investigation == nil {
                RecorderProblemView(problem: problem)
            } else if let investigation {
                ScrollView { content(investigation).padding(24) }
            } else {
                ProgressView("Reading the power log…")
            }
        }
        .navigationTitle("Wakes")
        .navigationSubtitle("Why did the Mac wake?")
        .toolbar {
            ToolbarItem {
                Picker("Range", selection: $span) { ForEach(Span.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
            }
            if span == .around {
                ToolbarItem { DatePicker("Around", selection: $around).labelsHidden() }
            }
            ToolbarItem {
                Button("Investigate") { run() }.buttonStyle(.borderedProminent).disabled(busy).keyboardShortcut(.return)
            }
        }
        .onAppear(perform: takeFocus)
        .onChange(of: model.wakeFocus) { takeFocus() }
        .task(id: "\(span.rawValue)-\(around.timeIntervalSince1970)") { run() }
    }

    private func content(_ investigation: WakeInvestigation) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if investigation.wakes.isEmpty {
                ContentUnavailableView("No Wakes", systemImage: "moon.zzz",
                                       description: Text("Nothing woke the Mac between \(investigation.from.formatted(date: .abbreviated, time: .shortened)) and \(investigation.to.formatted(date: .abbreviated, time: .shortened))."))
            }
            ForEach(investigation.wakes.reversed(), id: \.at) { wake in
                WakeCard(wake: wake, expanded: expanded == wake.at) { expanded = expanded == wake.at ? nil : wake.at }
            }
            if !investigation.keyLimits.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("What GhostTrace couldn't see")
                    ListBox {
                        ForEach(investigation.keyLimits, id: \.self) { FindingRow(badge: StatusBadge(title: "Limit", tint: .purple), statement: $0, basis: nil, evidence: []) }
                    }
                }
            }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// "Investigate This Wake" from the timeline lands here with a time to centre on.
    private func takeFocus() {
        guard let focus = model.wakeFocus else { return }
        (span, around, model.wakeFocus) = (.around, focus, nil)
    }

    private var window: DateInterval {
        let now = Date()
        switch span {
        case .hour: return DateInterval(start: now.addingTimeInterval(-3600), end: now)
        case .night:
            // 6 pm yesterday to 10 am today (or now, if earlier).
            let today = Calendar.current.startOfDay(for: now)
            return DateInterval(start: today.addingTimeInterval(-6 * 3600), end: min(now, today.addingTimeInterval(10 * 3600)))
        case .day: return DateInterval(start: now.addingTimeInterval(-86400), end: now)
        case .twoDays: return DateInterval(start: now.addingTimeInterval(-WakeInvestigator.maxWindow), end: now)
        case .around:
            let center = min(around, now)
            return DateInterval(start: center.addingTimeInterval(-1800), end: min(now, center.addingTimeInterval(1800)))
        }
    }

    /// The client blocks on IPC, so it runs off the main actor.
    private func run() {
        busy = true
        let (client, window) = (client, window)
        Task {
            let result = await Task.detached { Result { try client.investigateWake(window) } }.value
            switch result {
            case .success(let value):
                investigation = value
                expanded = value.wakes.last?.at
                problem = nil
            case .failure(let error):
                problem = error as? ServiceError ?? ServiceError(.internalError, "\(error)")
            }
            busy = false
        }
    }
}

/// One wake: the short answer on a card, and its findings underneath when expanded.
private struct WakeCard: View {
    let wake: WakeIncident
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(symbol: wake.type == .dark ? "moon.fill" : "sun.max.fill", color: .teal, size: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(wake.type.title) at \(wake.at.timeOfDay)").font(.title3.weight(.semibold))
                        Text(wake.summary).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    headline.badge
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .glassEffect(.regular.tint(.teal.opacity(0.18)).interactive(), in: .rect(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the findings" : "Shows the findings")
            if expanded {
                SectionHeader(title: "Findings") { Text("Correlated means close in time, not the cause").font(.caption).foregroundStyle(.tertiary) }
                EvidenceList(findings: wake.findings, limits: wake.limits)
            }
        }
    }

    /// The card's badge: GhostTrace's reading if it has one, else whether macOS recorded anything.
    private var headline: Confidence {
        let levels = Set(wake.findings.map(\.confidence))
        return levels.contains(.likely) ? .likely : levels.contains(.observed) ? .observed : .unknown
    }
}
