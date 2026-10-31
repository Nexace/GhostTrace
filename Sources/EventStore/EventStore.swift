import Foundation
import RecorderCore
import SQLite3

public struct StoreError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { message }
    var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

/// The event database. One connection, serialized by a lock; the recorder is its only writer (docs/adr/0002-recorder-ipc-and-storage.md).
public final class EventStore: @unchecked Sendable {
    public static var schemaVersion: Int { migrations.count }

    public let path: String
    /// Where a corrupt database was moved during init, if that happened.
    public let recoveredCorruptFile: String?
    /// Where the database was copied before a schema upgrade during init, if one ran. Never deleted automatically.
    public let migrationBackup: String?
    private let db: OpaquePointer
    private let lock = NSLock()

    /// A file that fails SQLite's integrity check is moved aside (never deleted) and a new database is created.
    public convenience init(path: String) throws {
        try self.init(path: path, migrations: Self.migrations)
    }

    /// `migrations` is injectable so tests can exercise an upgrade.
    init(path: String, migrations: [String]) throws {
        self.path = path
        do {
            (db, migrationBackup) = try Self.openAndMigrate(path, migrations)
            recoveredCorruptFile = nil
        } catch let error as StoreError where error.isCorruption {
            let aside = "\(path).corrupt-\(Int(Date().timeIntervalSince1970))"
            try FileManager.default.moveItem(atPath: path, toPath: aside)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.moveItem(atPath: path + suffix, toPath: aside + suffix) }
            (db, migrationBackup) = try Self.openAndMigrate(path, migrations)
            recoveredCorruptFile = aside
        }
    }

    deinit { sqlite3_close_v2(db) }

    /// Idempotent per event id, so a retried batch cannot store duplicates. Returns how many were new.
    @discardableResult
    public func insert(_ events: [Event]) throws -> Int {
        let encoder = GhostTraceJSON.encoder()
        return try locked { db in
            try exec(db, "BEGIN IMMEDIATE")
            do {
                var inserted = 0
                for event in events {
                    _ = try run(db, "INSERT OR IGNORE INTO events (id, occurred_at, ended_at, kind, bundle_id, json) VALUES (?, ?, ?, ?, ?, ?)",
                                [.text(event.id.uuidString), .int(event.occurredAt.milliseconds), event.endedAt.map { .int($0.milliseconds) } ?? .null,
                                 .text(event.kind.rawValue), event.subject?.bundleID.map(SQLValue.text) ?? .null,
                                 .text(String(decoding: try encoder.encode(event), as: UTF8.self))]) { _ in }
                    inserted += Int(sqlite3_changes(db))
                }
                try exec(db, "COMMIT")
                return inserted
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    public func page(_ query: EventQuery) throws -> EventPage {
        let limit = min(max(query.limit, 1), EventQuery.maxLimit)
        let newest = query.newestFirst == true
        let after = query.parsedCursor ?? (newest ? (Int64.max, Int64.max) : (Int64.min, Int64.min))
        let from = query.from.milliseconds
        let decoder = GhostTraceJSON.decoder()
        return try locked { db in
            // Point events inside [from, to), plus interval events (gaps) that started earlier and overlap `from`.
            let rows = try run(db, """
                SELECT occurred_at, seq, json FROM events
                WHERE ((occurred_at >= ?1 AND occurred_at < ?2) OR (occurred_at < ?1 AND ended_at > ?1))
                  AND (?3 IS NULL OR kind = ?3 OR kind = 'event_gap')
                  AND (occurred_at, seq) \(newest ? "<" : ">") (?4, ?5)
                ORDER BY occurred_at \(newest ? "DESC" : "ASC"), seq \(newest ? "DESC" : "ASC") LIMIT ?6
                """, [.int(from), .int(query.to.milliseconds), query.kind.map { .text($0.rawValue) } ?? .null,
                      .int(after.0), .int(after.1), .int(Int64(limit + 1))]) { stmt in
                (EventQuery.cursor(occurredAt: sqlite3_column_int64(stmt, 0), seq: sqlite3_column_int64(stmt, 1)),
                 try decoder.decode(Event.self, from: blob(stmt, 2)))
            }
            let kept = rows.prefix(limit)
            return EventPage(events: kept.map(\.1), nextCursor: rows.count > limit ? kept.last?.0 : nil,
                             retainedSince: try summary(db).oldest)
        }
    }

    public func event(id: UUID) throws -> Event? {
        let decoder = GhostTraceJSON.decoder()
        return try locked { db in
            try run(db, "SELECT json FROM events WHERE id = ?", [.text(id.uuidString)]) { try decoder.decode(Event.self, from: blob($0, 0)) }.first
        }
    }

    public func summary() throws -> (count: Int, oldest: Date?) {
        try locked(summary)
    }

    /// Retention: drops events that occurred before `cutoff`, then the oldest-inserted beyond `maxRows`.
    @discardableResult
    public func purge(before cutoff: Date, keepingAtMost maxRows: Int) throws -> Int {
        try locked { db in
            _ = try run(db, "DELETE FROM events WHERE occurred_at < ?", [.int(cutoff.milliseconds)]) { _ in }
            var deleted = Int(sqlite3_changes(db))
            _ = try run(db, "DELETE FROM events WHERE seq <= (SELECT seq FROM events ORDER BY seq DESC LIMIT 1 OFFSET ?)", [.int(Int64(maxRows))]) { _ in }
            deleted += Int(sqlite3_changes(db))
            return deleted
        }
    }

    /// Small key/value state that survives recorder restarts (heartbeat, clean-stop flag, pause).
    public func state(_ key: String) throws -> String? {
        try locked { db in try run(db, "SELECT value FROM recorder_state WHERE key = ?", [.text(key)]) { text($0, 0) }.first }
    }

    /// `nil` removes the key.
    public func setState(_ key: String, _ value: String?) throws {
        try locked { db in
            if let value {
                _ = try run(db, "INSERT INTO recorder_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                            [.text(key), .text(value)]) { _ in }
            } else {
                _ = try run(db, "DELETE FROM recorder_state WHERE key = ?", [.text(key)]) { _ in }
            }
        }
    }

    private func locked<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock { try body(db) }
    }

    private func summary(_ db: OpaquePointer) throws -> (count: Int, oldest: Date?) {
        try run(db, "SELECT COUNT(*), MIN(occurred_at) FROM events") { stmt in
            (Int(sqlite3_column_int64(stmt, 0)),
             sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Date(milliseconds: sqlite3_column_int64(stmt, 1)))
        }.first ?? (0, nil)
    }

    /// Append-only: entry `i` moves the schema from version `i` to `i + 1` (`PRAGMA user_version`).
    static let migrations = [
        """
        CREATE TABLE events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, -- insertion order; never reused, so cursors stay valid across retention
            id TEXT NOT NULL UNIQUE,
            occurred_at INTEGER NOT NULL,          -- UTC milliseconds since 1970
            ended_at INTEGER,
            kind TEXT NOT NULL,
            bundle_id TEXT,
            json TEXT NOT NULL                     -- the full Event in GhostTraceJSON format
        );
        CREATE INDEX events_by_time ON events(occurred_at, seq);
        CREATE INDEX events_by_kind ON events(kind, occurred_at);
        CREATE INDEX events_by_bundle ON events(bundle_id, occurred_at);
        CREATE INDEX intervals_by_end ON events(ended_at) WHERE ended_at IS NOT NULL;
        CREATE TABLE recorder_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """,
    ]

    /// Returns the connection and the pre-upgrade backup's path, if an upgrade ran.
    private static func openAndMigrate(_ path: String, _ migrations: [String]) throws -> (OpaquePointer, String?) {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard let db = handle else { throw StoreError(code: rc, message: "sqlite3_open_v2 failed (\(rc)) for \(path)") }
        do {
            guard rc == SQLITE_OK else { throw StoreError(db, rc) }
            sqlite3_busy_timeout(db, 2000)
            let check = try run(db, "PRAGMA quick_check") { text($0, 0) }
            guard check == ["ok"] else {
                throw StoreError(code: SQLITE_CORRUPT, message: "Integrity check failed: \(check.prefix(3).joined(separator: "; "))")
            }
            // A 512 KB page cache (SQLite's default is 2 MB) keeps the recorder small; queries are mostly by time index.
            try exec(db, "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA cache_size = -512;")
            // Files created before the recorder set umask 077 were 0644; the folder is 0700, but the files shouldn't rely on it.
            for suffix in ["", "-wal", "-shm"] { chmod(path + suffix, 0o600) }
            let version = try run(db, "PRAGMA user_version") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            guard version <= migrations.count else {
                throw StoreError(code: SQLITE_ERROR, message: "Database schema \(version) is newer than this build supports (\(migrations.count)).")
            }
            var backup: String?
            if version > 0, version < migrations.count {
                // A consistent copy of the old schema's data, so an upgrade that misbehaves later can be undone by hand.
                let copy = "\(path).pre-v\(migrations.count)-\(Int(Date().timeIntervalSince1970))"
                _ = try run(db, "VACUUM INTO ?", [.text(copy)]) { _ in }
                chmod(copy, 0o600)
                backup = copy
            }
            for (index, sql) in migrations.enumerated() where index >= version {
                do {
                    try exec(db, "BEGIN IMMEDIATE; \(sql) PRAGMA user_version = \(index + 1); COMMIT;")
                } catch {
                    // sqlite3_exec stops at the failing statement and leaves the transaction open.
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    throw error
                }
            }
            return (db, backup)
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
    }
}

extension StoreError {
    init(_ db: OpaquePointer, _ rc: Int32? = nil) {
        self.init(code: (rc ?? sqlite3_extended_errcode(db)) & 0xff, message: String(cString: sqlite3_errmsg(db)))
    }
}

private enum SQLValue {
    case int(Int64), text(String), null
}

// sqlite3.h: SQLITE_TRANSIENT makes SQLite copy the bound string.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func exec(_ db: OpaquePointer, _ sql: String) throws {
    let rc = sqlite3_exec(db, sql, nil, nil, nil)
    guard rc == SQLITE_OK else { throw StoreError(db, rc) }
}

private func run<T>(_ db: OpaquePointer, _ sql: String, _ args: [SQLValue] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
    var handle: OpaquePointer?
    let rc = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
    guard rc == SQLITE_OK, let stmt = handle else { throw StoreError(db, rc) }
    defer { sqlite3_finalize(stmt) }
    for (offset, arg) in args.enumerated() {
        let index = Int32(offset + 1)
        switch arg {
        case .int(let value): sqlite3_bind_int64(stmt, index, value)
        case .text(let value): sqlite3_bind_text(stmt, index, value, -1, transient)
        case .null: sqlite3_bind_null(stmt, index)
        }
    }
    var rows: [T] = []
    while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return rows }
        guard rc == SQLITE_ROW else { throw StoreError(db, rc) }
        rows.append(try row(stmt))
    }
}

private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
}

private func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
}
