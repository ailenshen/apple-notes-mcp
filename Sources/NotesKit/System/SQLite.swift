import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite3 library. Each instance belongs to one actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool) throws(NotesError) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            handle = nil
            throw .noAccess("cannot open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    enum Value {
        case text(String)
        case real(Double)
        case int(Int64)
        case null
    }

    /// Runs a statement, calling `row` for each result row.
    func query(_ sql: String, _ arguments: [Value] = [], row: (Row) throws(NotesError) -> Void = { _ throws(NotesError) in }) throws(NotesError) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure("prepare") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case .text(let s): sqlite3_bind_text(statement, position, s, -1, transient)
            case .real(let d): sqlite3_bind_double(statement, position, d)
            case .int(let i): sqlite3_bind_int64(statement, position, i)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw failure("step")
            }
        }
    }

    private func failure(_ stage: String) -> NotesError {
        .failed("SQLite \(stage) failed: \(String(cString: sqlite3_errmsg(handle)))")
    }

    struct Row {
        let statement: OpaquePointer?
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func data(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}
