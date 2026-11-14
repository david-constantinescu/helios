import Foundation
import SQLite3

enum SQLValue {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

struct SQLRow {
    let values: [SQLValue]
    subscript(i: Int) -> SQLValue { values[i] }
    func string(_ i: Int) -> String? { if case let .text(s) = values[i] { return s }; return nil }
    func double(_ i: Int) -> Double? {
        switch values[i] { case let .double(d): return d; case let .int(n): return Double(n); default: return nil }
    }
    func int(_ i: Int) -> Int? {
        switch values[i] { case let .int(n): return Int(n); case let .double(d): return Int(d); default: return nil }
    }
    func data(_ i: Int) -> Data? {
        switch values[i] { case let .blob(b): return b; case let .text(s): return Data(s.utf8); default: return nil }
    }
}

struct SQLError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin, thread-safe wrapper over the SQLite C API. All access is serialised with a recursive lock
/// so HealthKit background callbacks, the simulator and the UI can share one connection.
final class SQLiteDB {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let path: String

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw SQLError(message: "Cannot open database at \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(db) }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw SQLError(message: msg)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [SQLValue]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .double(v): sqlite3_bind_double(stmt, idx, v)
            case let .text(s): sqlite3_bind_text(stmt, idx, s, -1, SQLiteDB.TRANSIENT)
            case let .blob(d):
                _ = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(d.count), SQLiteDB.TRANSIENT)
                }
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLError(message: "\(lastError) in \(sql)") }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLError(message: "\(lastError) in \(sql)") }
        return Int(sqlite3_changes(db))
    }

    /// Runs one prepared statement for many parameter rows (fast batch insert). Returns total changes.
    @discardableResult
    func runMany(_ sql: String, _ rows: [[SQLValue]]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLError(message: "\(lastError) in \(sql)") }
        defer { sqlite3_finalize(stmt) }
        var total = 0
        for r in rows {
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            bind(stmt, r)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLError(message: "\(lastError) in \(sql)") }
            total += Int(sqlite3_changes(db))
        }
        return total
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLError(message: "\(lastError) in \(sql)") }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var rows: [SQLRow] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var vals: [SQLValue] = []
            vals.reserveCapacity(Int(n))
            for i in 0..<n {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: vals.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: vals.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: vals.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i) { vals.append(.blob(Data(bytes: p, count: len))) } else { vals.append(.blob(Data())) }
                default: vals.append(.null)
                }
            }
            rows.append(SQLRow(values: vals))
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
