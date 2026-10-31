import Charts
import GhostTraceIPC
import InvestigationKit
import RecorderCore
import SwiftUI

/// Memory over time from the recorder's samples, the largest processes, and an explanation of each spike.
struct MemoryView: View {
    enum Span: String, CaseIterable, Identifiable {
        case hour = "Last hour", sixHours = "Last 6 hours", day = "Last 24 hours"
        var id: Self { self }
        var seconds: TimeInterval { switch self { case .hour: 3600; case .sixHours: 6 * 3600; case .day: 86400 } }
    }

    @State private var span = Span.hour
    @State private var summary: ResourceSummary?
    @State private var investigation: MemoryInvestigation?
    @State private var problem: ServiceError?
    @State private var busy = false
    private let client = RecorderClient(timeout: 30)
    private static let gb = Double(1 << 30)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Window", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Refresh") { run() }.disabled(busy).keyboardShortcut("r")
            }
            if let problem {
                Text(problem.code == .recorderNotRunning ? "The recorder is not running. Start RecorderAgent (see README)." : problem.message)
                    .foregroundStyle(.red)
            }
            if let summary {
                Chart(summary.points, id: \.start) { point in
                    LineMark(x: .value("Time", point.start), y: .value("GB", Double(point.memoryUsedAverage) / Self.gb))
                        .foregroundStyle(by: .value("Memory used", "Average"))
                    LineMark(x: .value("Time", point.start), y: .value("GB", Double(point.memoryUsedPeak) / Self.gb))
                        .foregroundStyle(by: .value("Memory used", "Peak"))
                }
                .chartYScale(domain: 0...(Double(summary.memoryTotal ?? 0) / Self.gb).rounded(.up))
                .chartYAxisLabel("GB used")
                .frame(height: 160)
                .accessibilityLabel("Memory used over the window, \(summary.sampleCount) samples")
                if let worst = summary.points.map(\.pressure).max(), worst != .normal,
                   let first = summary.points.first(where: { $0.pressure == worst }) {
                    Text("macOS's memory pressure reached \(worst.rawValue), first around \(first.start.formatted(date: .omitted, time: .shortened)).")
                        .foregroundStyle(.orange)
                }
                List {
                    if let investigation {
                        Section(investigation.spikes.isEmpty ? "No memory spikes" : "Memory spikes") {
                            ForEach(investigation.spikes.reversed(), id: \.from) { SpikeRow(spike: $0) }
                        }
                    }
                    Section("Largest processes (by peak memory)") {
                        ForEach(summary.top, id: \.pid) { process in
                            HStack {
                                Text(process.name).lineLimit(1)
                                Spacer()
                                Text("peak \(ResourceSample.bytes(process.peakFootprint)), last seen \(ResourceSample.bytes(process.latestFootprint))").monospacedDigit()
                                Text(process.peakCPU.map { String(format: "CPU max %.0f%%", $0) } ?? "").monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    if !summary.limits.isEmpty {
                        Section("What GhostTrace couldn't see") {
                            ForEach(summary.limits, id: \.statement) { Text($0.statement).foregroundStyle(.secondary) }
                        }
                    }
                }
            } else {
                Text("Shows memory use from GhostTrace's samples and explains each spike: what macOS measured, which process likely caused it, and what couldn't be seen.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .task(id: span) { run() }
    }

    /// The client blocks on IPC, so it runs off the main actor.
    private func run() {
        busy = true
        let now = Date()
        let (client, window) = (client, DateInterval(start: now.addingTimeInterval(-span.seconds), end: now))
        Task {
            let result = await Task.detached {
                Result { (try client.resources(window, top: 10, points: 120), try client.investigateMemory(window)) }
            }.value
            switch result {
            case .success(let (newSummary, newInvestigation)):
                (summary, investigation, problem) = (newSummary, newInvestigation, nil)
            case .failure(let error):
                problem = error as? ServiceError ?? ServiceError(.internalError, "\(error)")
            }
            busy = false
        }
    }
}

private struct SpikeRow: View {
    let spike: MemorySpike

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(spike.to.formatted(date: .abbreviated, time: .standard)).monospacedDigit().bold()
                Text("\(ResourceSample.bytes(spike.memoryBefore)) to \(ResourceSample.bytes(spike.memoryAfter))").foregroundStyle(.secondary)
            }
            Text(spike.summary)
            ForEach(spike.findings.filter { $0.confidence == .correlated }, id: \.statement) {
                Text("Also: \($0.statement) Timing only, not a cause.").font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Evidence") { EvidenceList(findings: spike.findings, limits: spike.limits) }
                .font(.callout)
        }
        .padding(.vertical, 4)
    }
}
