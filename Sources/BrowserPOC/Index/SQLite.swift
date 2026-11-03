import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// A small wrapper over the system SQLite library. Not thread-safe on its own;
/// callers serialize access.
final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false, uri: Bool = false) throws {
        var flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if uri { flags |= SQLITE_OPEN_URI }
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(message: msg)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(message: msg + " in: " + sql.prefix(120))
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK || stmt == nil {
            throw SQLiteError(message: errorMessage + " in: " + sql.prefix(160))
        }
        return Statement(stmt!)
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        let s = try prepare(sql)
        s.bind(args)
        while try s.step() {}
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ args: [Any?] = [], _ row: (Statement) -> T) throws -> [T] {
        let s = try prepare(sql)
        s.bind(args)
        var out: [T] = []
        while try s.step() { out.append(row(s)) }
        return out
    }

    func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        try query(sql, args) { $0.int(0) }.first ?? 0
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    let stmt: OpaquePointer
    init(_ stmt: OpaquePointer) { self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    func bind(_ args: [Any?]) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil:
                sqlite3_bind_null(stmt, idx)
            case let x as Int:
                sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Int64:
                sqlite3_bind_int64(stmt, idx, x)
            case let x as Int32:
                sqlite3_bind_int64(stmt, idx, Int64(x))
            case let x as Bool:
                sqlite3_bind_int64(stmt, idx, x ? 1 : 0)
            case let x as Double:
                sqlite3_bind_double(stmt, idx, x)
            case let x as String:
                sqlite3_bind_text(stmt, idx, x, -1, SQLITE_TRANSIENT)
            case let x as Data:
                x.withUnsafeBytes { buf in
                    _ = sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            default:
                sqlite3_bind_text(stmt, idx, String(describing: v!), -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// Returns true when a row is available.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        let db = sqlite3_db_handle(stmt)
        throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
    }

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func text(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: p)
    }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    func blob(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return Data(bytes: p, count: n)
    }
}
