@testable import EventStore
import Foundation
import RecorderCore
import SQLite3
import Testing

private func tempPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).sqlite").path
}

private func event(_ kind: EventKind = .appLaunch, at ms: Int64, endedAt: Int64? = nil, boot: String = "boot-A", mono: UInt64 = 0) -> Event {
    let clock = RecorderClock(now: { Date(milliseconds: ms) }, monotonicNanos: { mono }, bootSessionID: boot)
    return Event(kind: kind, source: "test", occurredAt: Date(milliseconds: ms), endedAt: endedAt.map(Date.init(milliseconds:)), clock: clock)
}

private func all(_ store: EventStore, kind: EventKind? = nil) throws -> [Event] {
    try store.page(EventQuery(from: Date(milliseconds: 0), to: Date(milliseconds: 4_000_000_000_000), kind: kind, limit: 1000)).events
}

@Test func eventsSurviveReopeningTheDatabase() throws {
    let path = tempPath()
    let stored = [event(at: 100), event(.wake, at: 200)]
    do { try EventStore(path: path).insert(stored) }
    let reopened = try EventStore(path: path)
    #expect(try all(reopened) == stored)
    #expect(EventStore.schemaVersion == 1)
}

@Test func duplicateIdsAreStoredOnce() throws {
    let store = try EventStore(path: tempPath())
    let first = event(at: 100)
    #expect(try store.insert([first]) == 1)
    #expect(try store.insert([first, event(at: 200)]) == 1)
    #expect(try all(store).count == 2)
}

@Test func eventsAreOrderedByOccurrenceThenInsertion() throws {
    let store = try EventStore(path: tempPath())
    let (c, a, b1, b2) = (event(at: 300), event(at: 100), event(at: 200), event(at: 200))
    try store.insert([c, a, b1, b2])
    #expect(try all(store).map(\.id) == [a, b1, b2, c].map(\.id))
}

@Test func eventsAcrossABootBoundaryOrderByWallClockAndKeepTheirBootSession() throws {
    let store = try EventStore(path: tempPath())
    // The monotonic clock restarts at boot, so it must not decide order across boots.
    let beforeReboot = event(at: 100, boot: "boot-A", mono: 9_000_000_000)
    let afterReboot = event(at: 200, boot: "boot-B", mono: 1_000_000_000)
    try store.insert([afterReboot, beforeReboot])
    let listed = try all(store)
    #expect(listed.map(\.id) == [beforeReboot.id, afterReboot.id])
    #expect(listed.map(\.bootSessionID) == ["boot-A", "boot-B"])
}

@Test func cursorPagesCoverEveryEventExactlyOnce() throws {
    let store = try EventStore(path: tempPath())
    let stored = (1...5).map { event(at: Int64($0) * 100) }
    try store.insert(stored)
    var query = EventQuery(from: Date(milliseconds: 0), to: Date(milliseconds: 1000), limit: 2)
    var seen: [Event] = []
    var pages = 0
    repeat {
        let page = try store.page(query)
        seen += page.events
        pages += 1
        query.cursor = page.nextCursor
    } while query.cursor != nil
    #expect(pages == 3)
    #expect(seen == stored)
}

@Test func newestFirstPagesStartAtTheEnd() throws {
    // The Timeline caps at 5,000 events; paging oldest first kept the oldest and dropped today's.
    let store = try EventStore(path: tempPath())
    let stored = (1...5).map { event(at: Int64($0) * 100) }
    try store.insert(stored)
    var query = EventQuery(from: Date(milliseconds: 0), to: Date(milliseconds: 1000), limit: 2, newestFirst: true)
    var seen: [Event] = []
    repeat {
        let page = try store.page(query)
        seen += page.events
        query.cursor = page.nextCursor
    } while query.cursor != nil
    #expect(seen == stored.reversed())
    let older = try GhostTraceJSON.decoder().decode(EventQuery.self, from: Data(#"{"from":"2026-10-30T00:00:00Z","to":"2026-10-31T00:00:00Z","limit":5}"#.utf8))
    #expect(older.newestFirst == nil)
}

@Test func windowIncludesOverlappingGapsEvenWhenFilteringByKind() throws {
    let store = try EventStore(path: tempPath())
    let oldGap = event(.eventGap, at: 10, endedAt: 40)
    let overlappingGap = event(.eventGap, at: 50, endedAt: 150)
    let launch = event(.appLaunch, at: 120)
    let exit = event(.appExit, at: 130)
    let later = event(.appLaunch, at: 300)
    try store.insert([oldGap, overlappingGap, launch, exit, later])
    let page = try store.page(EventQuery(from: Date(milliseconds: 100), to: Date(milliseconds: 200), kind: .appLaunch))
    #expect(page.events.map(\.id) == [overlappingGap.id, launch.id])
    #expect(page.retainedSince == Date(milliseconds: 10))
}

@Test func retentionDropsOldEventsThenCapsRowCount() throws {
    let store = try EventStore(path: tempPath())
    try store.insert([event(at: 100), event(at: 200), event(at: 300), event(at: 400)])
    #expect(try store.purge(before: Date(milliseconds: 150), keepingAtMost: 2) == 2)
    let summary = try store.summary()
    #expect(summary.count == 2)
    #expect(summary.oldest == Date(milliseconds: 300))
}

@Test func recorderStateRoundTripsAndDeletes() throws {
    let store = try EventStore(path: tempPath())
    try store.setState("k", "1")
    try store.setState("k", "2")
    #expect(try store.state("k") == "2")
    try store.setState("k", nil)
    #expect(try store.state("k") == nil)
}

@Test func corruptDatabaseIsMovedAsideAndReplaced() throws {
    let path = tempPath()
    let garbage = Data(repeating: 0xAB, count: 8192)
    try garbage.write(to: URL(fileURLWithPath: path))
    let store = try EventStore(path: path)
    let aside = try #require(store.recoveredCorruptFile)
    #expect(FileManager.default.contents(atPath: aside) == garbage)
    try store.insert([event(at: 100)])
    #expect(try all(store).count == 1)
}

@Test func newerSchemaIsRefusedAndTheFileIsLeftInPlace() throws {
    let path = tempPath()
    do { _ = try EventStore(path: path) }
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    #expect(throws: (any Error).self) { try EventStore(path: path) }
    let siblings = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
    #expect(!siblings.contains { $0.hasPrefix((path as NSString).lastPathComponent + ".corrupt") })
}

// MARK: Migration safety

private func tableExists(_ path: String, _ name: String) -> Bool {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    return sqlite3_step(stmt) == SQLITE_ROW
}

@Test func anUpgradeCopiesTheOldDatabaseFirst() throws {
    let path = tempPath()
    let stored = event(at: 100)
    do {
        let fresh = try EventStore(path: path)
        #expect(fresh.migrationBackup == nil)
        try fresh.insert([stored])
    }
    let upgraded = try EventStore(path: path, migrations: EventStore.migrations + ["CREATE TABLE extra (x);"])
    let backup = try #require(upgraded.migrationBackup)
    #expect(tableExists(path, "extra") && !tableExists(backup, "extra"))
    #expect(try all(upgraded) == [stored])
    #expect(try all(EventStore(path: backup)) == [stored])
    #expect(try FileManager.default.attributesOfItem(atPath: backup)[.posixPermissions] as? Int == 0o600)
}

@Test func aFailingMigrationLeavesTheDatabaseAsItWas() throws {
    let path = tempPath()
    let stored = event(at: 100)
    do { try EventStore(path: path).insert([stored]) }
    #expect(throws: (any Error).self) {
        try EventStore(path: path, migrations: EventStore.migrations + ["CREATE TABLE extra (x); INSERT INTO no_such_table VALUES (1);"])
    }
    #expect(!tableExists(path, "extra"))
    let reopened = try EventStore(path: path)
    #expect(try all(reopened) == [stored])
}

@Test func databaseFilesAreMadeOwnerOnly() throws {
    let path = tempPath()
    do { try EventStore(path: path).insert([event(at: 100)]) }
    chmod(path, 0o644)
    _ = try EventStore(path: path)
    #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
}

/// Performance budget: 30 days at the measured rate is a few tens of thousands of rows, so 100,000 leaves headroom.
/// The limits are loose so a busy machine doesn't fail the test; a regression in the indexes would miss them by far.
@Test func aMonthOfEventsStaysFastToQueryAndPurge() throws {
    let store = try EventStore(path: tempPath())
    let start: Int64 = 1_790_000_000_000
    let step: Int64 = 26_000
    let events = (0..<100_000).map { i in
        event(i % 10 == 0 ? .appLaunch : .resourceSample, at: start + Int64(i) * step)
    }
    let clock = ContinuousClock()
    let insert = try clock.measure { _ = try store.insert(events) }
    let lastDay = Date(milliseconds: start + 100_000 * step)
    var (pageCount, rowCount, purged) = (0, 0, 0)
    let page = try clock.measure {
        pageCount = try store.page(EventQuery(from: lastDay.addingTimeInterval(-86400), to: lastDay, kind: .appLaunch, limit: 200)).events.count
    }
    let summary = try clock.measure { rowCount = try store.summary().count }
    let purge = try clock.measure { purged = try store.purge(before: Date(milliseconds: start + 50_000 * step), keepingAtMost: 1_000_000) }
    #expect(pageCount == 200)
    #expect(rowCount == 100_000)
    #expect(purged == 50_000)
    #expect(insert < .seconds(20), "insert: \(insert)")
    #expect(page < .milliseconds(200), "page: \(page)")
    #expect(summary < .milliseconds(500), "summary: \(summary)")
    #expect(purge < .seconds(10), "purge: \(purge)")
    print("100k events: insert \(insert), page \(page), summary \(summary), purge half \(purge)")
}
