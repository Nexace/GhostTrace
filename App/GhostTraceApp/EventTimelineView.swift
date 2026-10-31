import AppKit
import GhostTraceIPC
import RecorderCore
import SwiftUI

/// Recorded events, newest first, filtered by time, kind and text. The inspector shows where the selected one came from.
struct EventTimelineView: View {
    enum Span: TimeInterval, CaseIterable, Identifiable {
        case hour = 3600, day = 86400, week = 604800, month = 2_592_000
        var id: Self { self }
        var title: String { switch self { case .hour: "Hour"; case .day: "Day"; case .week: "Week"; case .month: "30 Days" } }
        var phrase: String { switch self { case .hour: "Last hour"; case .day: "Last 24 hours"; case .week: "Last 7 days"; case .month: "Last 30 days" } }
    }

    /// Bounds what one refresh pulls over IPC; the note below the table says when it was hit.
    nonisolated static let maxEvents = 5000

    @Environment(RecorderModel.self) private var model
    @State private var span = Span.day
    @State private var kind: EventKind?
    @State private var search = ""
    @State private var events: [Event] = []
    @State private var truncated = false
    @State private var retainedSince: Date?
    @State private var selection: Event.ID?
    @State private var showInspector: Bool
    @State private var problem: ServiceError?
    @State private var busy = false
    private let client = RecorderClient()

    /// `selecting` opens the inspector on that event (an alert's notification was clicked).
    init(selecting event: Event.ID? = nil) {
        _selection = State(initialValue: event)
        _showInspector = State(initialValue: event != nil)
    }

    var body: some View {
        // A plain trailing panel rather than .inspector, which overflows the AppKit-hosted window when it opens.
        HStack(spacing: 0) {
            table
            if showInspector {
                Divider()
                Group {
                    if let event = events.first(where: { $0.id == selection }) {
                        EventInspector(event: event)
                    } else {
                        ContentUnavailableView("No Selection", systemImage: "cursorarrow.click", description: Text("Select an event to see where it came from."))
                    }
                }
                .frame(width: 290)
            }
        }
        .navigationTitle("Timeline")
        .navigationSubtitle("\(span.phrase) · \(events.count.formatted()) events · \(gapCount) gap\(gapCount == 1 ? "" : "s")")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter events")
        .toolbar {
            ToolbarItem {
                Picker("Range", selection: $span) { ForEach(Span.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
            }
            ToolbarItem {
                Picker("Kind", selection: $kind) {
                    Text("All Kinds").tag(EventKind?.none)
                    Divider()
                    ForEach(EventKind.allCases.filter { $0 != .eventGap }, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.menu).fixedSize()
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { load() }.disabled(busy).keyboardShortcut("r")
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
            }
        }
        // Opens on the first selection, so a narrow window keeps room for the table until then.
        .onChange(of: selection) { if selection != nil { showInspector = true } }
        .task(id: "\(span.rawValue)-\(kind?.rawValue ?? "all")") { load() }
    }

    @ViewBuilder private var table: some View {
        if let problem, events.isEmpty {
            RecorderProblemView(problem: problem)
        } else {
            Table(shown, selection: $selection) {
                TableColumn("Time") { Text(timeLabel($0.occurredAt)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 64, ideal: span.rawValue > 86400 ? 120 : 72, max: 160)
                TableColumn("Kind") { event in
                    Label { Text(event.title) } icon: { Image(systemName: event.symbol).foregroundStyle(event.kind.color) }
                        .foregroundStyle(event.kind == .eventGap ? .secondary : .primary)
                }
                .width(min: 110, ideal: 120, max: 180)
                TableColumn("Subject") { event in
                    Text(event.subjectLine).foregroundStyle(event.kind == .eventGap ? .secondary : .primary).help(event.subjectLine)
                }
                .width(min: 160, ideal: 260)
                TableColumn("Quality") { $0.badge }.width(min: 80, ideal: 90, max: 110)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footnote }
        }
    }

    private var shown: [Event] {
        guard !search.isEmpty else { return events }
        return events.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.subjectLine.localizedCaseInsensitiveContains(search) }
    }

    private var gapCount: Int { events.count { $0.kind == .eventGap } }

    private func timeLabel(_ date: Date) -> String {
        span.rawValue > 86400 ? date.formatted(.dateTime.day().month(.abbreviated)) + " " + date.timeOfDay : date.timeOfDay
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 2) {
            if truncated { Text("Showing the newest \(Self.maxEvents.formatted()) events. Pick a shorter range or one kind to see the rest.") }
            if let retainedSince, retainedSince > Date().addingTimeInterval(-span.rawValue) {
                Text("Nothing is stored before \(retainedSince.formatted(date: .abbreviated, time: .shortened)). Earlier activity wasn't recorded or is past retention.")
            }
            Text("Gaps, when GhostTrace wasn't recording, are always shown, whatever the kind filter.")
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    /// Pages back from now, so the cap keeps the newest events.
    private func load() {
        busy = true
        let (client, kind, now) = (client, kind, Date())
        let query = EventQuery(from: now.addingTimeInterval(-span.rawValue), to: now, kind: kind, limit: EventQuery.maxLimit, newestFirst: true)
        Task {
            let result = await Task.detached { () -> Result<(events: [Event], truncated: Bool, retainedSince: Date?), any Error> in
                Result {
                    var query = query
                    var all: [Event] = []
                    var retained: Date?
                    repeat {
                        let page = try client.events(query)
                        all += page.events
                        retained = page.retainedSince
                        query.cursor = page.nextCursor
                    } while query.cursor != nil && all.count < Self.maxEvents
                    return (Array(all.prefix(Self.maxEvents)), query.cursor != nil || all.count > Self.maxEvents, retained)
                }
            }.value
            switch result {
            case .success(let value):
                (events, truncated, retainedSince) = value
                problem = nil
            case .failure(let error):
                problem = error as? ServiceError ?? ServiceError(.internalError, "\(error)")
            }
            busy = false
        }
    }
}

/// Everything recorded about one event: when, from where, how, and its id.
private struct EventInspector: View {
    let event: Event
    @Environment(RecorderModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Label { Text(event.title) } icon: { IconTile(symbol: event.symbol, color: event.kind.color, size: 24) }
                            .font(.title3.weight(.semibold))
                        Spacer()
                        event.badge
                    }
                    Text(event.subjectLine).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                VStack(spacing: 0) {
                    ForEach(Array(details.enumerated()), id: \.offset) { index, pair in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(pair.0).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                            Text(pair.1).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        if index < details.count - 1 { Divider().padding(.leading, 12) }
                    }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                if let provenance = event.provenance {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How it was recorded").font(.headline)
                        Text(provenance).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                HStack {
                    Text("ID " + event.id.uuidString.prefix(8) + "…").font(.caption.monospaced()).foregroundStyle(.tertiary).help(event.id.uuidString)
                    Spacer()
                    Button("Copy ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(event.id.uuidString, forType: .string)
                    }
                }
                if [.wake, .sleep, .diagnostic].contains(event.kind) {
                    Button {
                        model.wakeFocus = event.occurredAt
                        model.pane = .wakes
                    } label: {
                        Text("Investigate This Wake").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .padding(20)
        }
    }

    private var details: [(String, String)] {
        let full: (Date) -> String = { $0.formatted(.dateTime.day().month().year().hour().minute().second().secondFraction(.fractional(3)).timeZone()) }
        var rows = [("Time", full(event.occurredAt))]
        if let end = event.endedAt { rows.append(("Until", full(end))) }
        rows.append(("Source", event.source))
        rows.append(("Quality", event.quality.rawValue.replacingOccurrences(of: "_", with: " ").capitalized))
        if let subject = event.subject {
            if let name = subject.name ?? subject.bundleID { rows.append(("Subject", name)) }
            if let pid = subject.pid { rows.append(("Process", "pid \(pid)")) }
            if let path = subject.path { rows.append(("Path", path)) }
        }
        // A resource sample's payload is one large JSON value; its summary line already says what matters.
        for (key, value) in event.payload.sorted(by: { $0.key < $1.key }) where key != "sample" {
            rows.append((key.replacingOccurrences(of: "_", with: " ").capitalized, value))
        }
        rows.append(("Recorded", event.recordedAt.timeOfDay))
        if let boot = event.bootSessionID { rows.append(("Boot", String(boot.prefix(8)))) }
        return rows
    }
}
