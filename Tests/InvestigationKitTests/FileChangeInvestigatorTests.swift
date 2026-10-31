import Foundation
import InvestigationKit
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_100_000_000) })
private let start = Date(milliseconds: 1_793_000_000_000)
private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private func change(_ path: String, _ seconds: TimeInterval, _ changes: String = "modified", id: UInt64) -> Event {
    Event(kind: .fileChange, source: "file-watch/FSEvents", occurredAt: at(seconds), subject: Subject(path: path),
          payload: ["changes": changes, "item": "file", "fsevent_id": String(id)], privacyClass: .sensitive, clock: clock)
}

private let folder = WatchedPath(path: "/Users/me/Documents", since: start.addingTimeInterval(-86400))

private func investigate(_ path: String, _ events: [Event], watches: [WatchedPath] = [folder]) -> FileChangeInvestigation {
    FileChangeInvestigator.investigate(path: path, from: start, to: at(3600), events: events.sorted { $0.occurredAt < $1.occurredAt }, watches: watches)
}

@Test func changesUnderAFolderAreFoundAndNoWriterIsEverNamed() throws {
    let launch = Event(kind: .appLaunch, source: "app-lifecycle/NSWorkspaceDidLaunchApplicationNotification", occurredAt: at(90),
                       subject: Subject(pid: 7, name: "TextEdit"), clock: clock)
    let events = [change("/Users/me/Documents/a.txt", 100, id: 1), change("/Users/me/Documents/sub/b.txt", 200, id: 5),
                  change("/Users/me/Documents-old/c.txt", 300, id: 9), launch]
    let investigation = investigate("/Users/me/Documents", events)
    #expect(investigation.changes.map(\.path) == ["/Users/me/Documents/a.txt", "/Users/me/Documents/sub/b.txt"])
    #expect(investigation.watchedBy == folder)
    for change in investigation.changes {
        #expect(change.findings.contains { $0.confidence == .unknown && $0.statement == "Which process made this change is unknown." })
        // Only a correlated finding may mention an app.
        #expect(change.findings.filter { $0.statement.contains("TextEdit") }.allSatisfy { $0.confidence == .correlated })
    }
    #expect(investigation.changes[0].findings.contains { $0.confidence == .correlated && $0.statement == "TextEdit launched about 10 s before the change." })
    #expect(investigation.changes[0].summary == "Changed. Which process changed it is unknown.")
}

@Test func renamesPairByConsecutiveIdsInBothDirections() throws {
    let events = [change("/Users/me/Documents/a.txt", 100, "renamed,modified", id: 41), change("/Users/me/Documents/b.txt", 100.1, "renamed", id: 42)]
    let old = try #require(investigate("/Users/me/Documents/a.txt", events).changes.first)
    #expect(old.summary == "Renamed to /Users/me/Documents/b.txt. Which process did it is unknown.")
    let new = try #require(investigate("/Users/me/Documents/b.txt", events).changes.first)
    #expect(new.findings.contains { $0.confidence == .likely && $0.statement == "It was renamed (or moved) from /Users/me/Documents/a.txt." })
}

@Test func recordsInOneDeliveryGroupButSeparateSavesDoNot() {
    let events = [change("/Users/me/Documents/a.txt", 100, "created,modified", id: 1), change("/Users/me/Documents/a.txt", 100.2, "renamed", id: 2),
                  change("/Users/me/Documents/a.txt", 102, id: 3)]
    let changes = investigate("/Users/me/Documents/a.txt", events).changes
    #expect(changes.count == 2)
    #expect(changes[0].changes == ["created", "modified", "renamed"])
}

@Test func anUnwatchedPathOrALaterWatchIsALimit() {
    let unwatched = investigate("/Users/me/Desktop/x.txt", [])
    #expect(unwatched.watchedBy == nil)
    #expect(unwatched.limits.contains { $0.statement.hasPrefix("/Users/me/Desktop/x.txt isn't in a watched folder") })
    let late = WatchedPath(path: "/Users/me/Documents", since: at(1800))
    #expect(investigate("/Users/me/Documents/a.txt", [], watches: [late]).limits.contains { $0.statement.contains("watched only since") })
}

@Test func theInnermostWatchCoversAPath() {
    let inner = WatchedPath(path: "/Users/me/Documents/project", since: start.addingTimeInterval(-7 * 86400))
    #expect(investigate("/Users/me/Documents/project/main.swift", [], watches: [folder, inner]).watchedBy == inner)
}

@Test func droppedChangesAreCitedAndPowerLogHolesIgnored() {
    let dropped = Event.gap(from: at(10), to: at(20), reason: .watchDropped, detail: ["dropped_count": "300"], clock: clock)
    let hole = Event.gap(from: at(-86400), to: at(100), reason: .powerLogHole, clock: clock)
    let limits = investigate("/Users/me/Documents", [dropped, hole]).limits
    #expect(limits.contains { $0.evidence == [dropped.id] && $0.statement.hasPrefix("Some file changes were dropped") })
    #expect(!limits.contains { $0.evidence.contains(hole.id) })
}

@Test func aChangeReadBackFromFSEventsHistoryKeepsItsIntervalAndNamesNoApp() throws {
    // The recorder was down from 50 s before the window to 600 s into it; the history says a.txt changed then.
    let gap = Event.gap(from: at(-50), to: at(600), reason: .recorderInterrupted, clock: clock)
    let replayed = Event(kind: .fileChange, source: "file-watch/FSEvents-history", occurredAt: at(-50), endedAt: at(600),
                         subject: Subject(path: "/Users/me/Documents/a.txt"), payload: ["changes": "modified", "item": "file", "replayed": "true"],
                         quality: .inferred, privacyClass: .sensitive, clock: clock)
    let launch = Event(kind: .appLaunch, source: "app-lifecycle/NSWorkspaceDidLaunchApplicationNotification", occurredAt: at(-60),
                       subject: Subject(pid: 7, name: "TextEdit"), clock: clock)
    let investigation = investigate("/Users/me/Documents", [gap, replayed, launch])
    let change = try #require(investigation.changes.first)
    #expect(change.at == at(-50) && change.endedAt == at(600))
    #expect(change.summary.hasPrefix("Changed while GhostTrace wasn't running, between "))
    #expect(change.findings.map(\.confidence) == [.observed, .unknown])
    #expect(!change.findings.contains { $0.statement.contains("TextEdit") })
    #expect(investigation.limits.contains { $0.evidence == [gap.id] && $0.statement.contains("FSEvents' history") })
}
