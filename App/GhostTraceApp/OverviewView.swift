import GhostTraceIPC
import RecorderCore
import SwiftUI

/// The recorder at a glance: its state and storage, today's gaps, the latest events, and what each source can see.
struct OverviewView: View {
    @Environment(RecorderModel.self) private var model
    @State private var recent: [Event] = []
    @State private var gapsToday: [Event] = []
    private let client = RecorderClient()

    var body: some View {
        Group {
            if let status = model.status {
                ScrollView { content(status).padding(24) }
            } else if let problem = model.problem {
                RecorderProblemView(problem: problem)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Overview")
        .navigationSubtitle(subtitle)
        .toolbar {
            if let status = model.status {
                Button(status.state == .paused ? "Resume Recording" : "Pause Recording") { Task { await model.togglePause() } }
            }
        }
        // Reloads as new events arrive, so the lists match the counts above them.
        .task(id: model.status?.eventCount) { await load() }
    }

    private func content(_ status: RecorderStatus) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) {
                StatCard(title: "Status", value: stateTitle(status),
                         detail: status.pausedAt.map { "Paused since \(Self.when($0))" } ?? "Since \(Self.when(status.startedAt))",
                         symbol: status.state == .paused ? "pause.fill" : "record.circle", color: status.state == .running ? .green : .orange)
                StatCard(title: "Events stored", value: status.eventCount.formatted(),
                         detail: (status.retainedSince.map { "Oldest \($0.formatted(.dateTime.day().month())) · " } ?? "") + "kept \(status.retentionDays) days",
                         symbol: "tray.full.fill", color: .blue)
                StatCard(title: "Database", value: status.databaseBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
                         detail: "Owner-only · schema \(status.schemaVersion ?? 1)", symbol: "internaldrive.fill", color: .indigo)
                StatCard(title: "Gaps today", value: gapsToday.count.formatted(), detail: gapDetail, symbol: "pause.circle.fill", color: .purple)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Recent activity") { Button("Show Timeline") { model.pane = .timeline }.buttonStyle(.link) }
                if recent.isEmpty {
                    Text("Nothing recorded in the last 24 hours.").foregroundStyle(.secondary)
                } else {
                    ListBox { ForEach(recent) { EventLine(event: $0) } }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Sources")
                ListBox {
                    ForEach(status.capabilities) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            row.state.badge.frame(width: 92, alignment: .leading)
                            Text(row.name).frame(width: 200, alignment: .leading)
                            Text(row.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// "12:54 AM" today, "27 Oct, 12:54 AM" otherwise.
    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private var subtitle: String {
        guard let status = model.status else { return "" }
        return "\(stateTitle(status)) · \(status.eventCount.formatted()) events · " + (status.droppedEvents == 0 ? "nothing dropped" : "\(status.droppedEvents) dropped")
    }

    private func stateTitle(_ status: RecorderStatus) -> String {
        switch status.state {
        case .running: "Recording"
        case .paused: "Paused"
        case .permissionLimited: "Limited"
        }
    }

    private var gapDetail: String {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let missed = gapsToday.reduce(0.0) { total, gap in
            total + max(0, min(gap.endedAt ?? gap.occurredAt, Date()).timeIntervalSince(max(gap.occurredAt, dayStart)))
        }
        guard missed > 0 else { return "Nothing missed since midnight" }
        return Duration.seconds(missed).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)) + " not recorded"
    }

    /// The newest few events, and every gap since midnight. The client blocks on IPC, so it runs off the main actor.
    private func load() async {
        let (client, now) = (client, Date())
        let dayStart = Calendar.current.startOfDay(for: now)
        let result = await Task.detached { () -> Result<([Event], [Event]), any Error> in
            Result {
                func all(_ query: EventQuery) throws -> [Event] {
                    var (query, events) = (query, [Event]())
                    repeat {
                        let page = try client.events(query)
                        events += page.events
                        query.cursor = page.nextCursor
                    } while query.cursor != nil && events.count < 5000
                    return events
                }
                let latest = try client.events(EventQuery(from: now.addingTimeInterval(-86400), to: now, limit: 6, newestFirst: true)).events
                let gaps = try all(EventQuery(from: dayStart, to: now, kind: .eventGap, limit: EventQuery.maxLimit))
                return (latest, gaps)
            }
        }.value
        if case .success(let (latest, gaps)) = result { (recent, gapsToday) = (latest, gaps) }
    }
}

/// One event in a list: time, kind, what it's about, and how it was recorded.
struct EventLine: View {
    let event: Event

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(event.occurredAt.timeOfDay).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Label { Text(event.title) } icon: { Image(systemName: event.symbol).foregroundStyle(event.kind.color) }
                .frame(width: 120, alignment: .leading)
            Text(event.subjectLine).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            event.badge
        }
        .foregroundStyle(event.kind == .eventGap ? .secondary : .primary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
