import SQLite3

/// Storage uses the SDK's SQLite3 module (docs/adr/0001-foundation.md). Schema and migrations arrive in Phase 1.
public enum SQLiteLibrary {
    /// Version of the library linked at runtime, which can differ from the SDK header.
    public static var version: String { String(cString: sqlite3_libversion()) }
}
