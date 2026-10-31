import EventStore
import SQLite3
import Testing

@Test func sdkSQLiteLinksAndOpensInMemoryDatabase() {
    #expect(SQLiteLibrary.version.hasPrefix("3."))
    var db: OpaquePointer?
    #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES (1);", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_close(db) == SQLITE_OK)
}
