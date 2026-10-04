import Foundation
import SQLite3

/// A small wrapper around the SQLite C API: just what Clippa needs, no
/// external dependency. One connection, serialized by a lock.
public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    public var description: String {
        switch self {
        case .open(let message): return "SQLite open failed: \(message)"
        case .prepare(let message, let sql): return "SQLite prepare failed: \(message) [\(sql)]"
        case .step(let message, let sql): return "SQLite step failed: \(message) [\(sql)]"
        }
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
            | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteError.open(message)
        }
        // Another process (clippa-mcp) may write at the same time: wait
        // instead of failing.
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// Runs one or more statements without parameters.
    public func execute(_ sql: String) throws {
        try locked {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? errorMessage
                sqlite3_free(error)
                throw SQLiteError.step(message, sql: sql)
            }
        }
    }

    /// Runs a statement with parameters and returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ params: [Any?] = []) throws -> Int {
        try locked {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(params, to: statement, sql: sql)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw SQLiteError.step(errorMessage, sql: sql)
            }
            return Int(sqlite3_changes(handle))
        }
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ params: [Any?] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        try locked {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(params, to: statement, sql: sql)
            var rows: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    rows.append(try map(SQLiteRow(statement: statement!)))
                } else if result == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.step(errorMessage, sql: sql)
                }
            }
            return rows
        }
    }

    public func scalarInt(_ sql: String, _ params: [Any?] = []) throws -> Int {
        try query(sql, params) { $0.int(0) }.first ?? 0
    }

    public func scalarString(_ sql: String, _ params: [Any?] = []) throws -> String? {
        try query(sql, params) { $0.optionalString(0) }.first ?? nil
    }

    /// Runs `body` inside a transaction; rolls back if it throws. Nested
    /// calls join the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            if transactionDepth > 0 {
                transactionDepth += 1
                defer { transactionDepth -= 1 }
                return try body()
            }
            try execute("BEGIN IMMEDIATE")
            transactionDepth = 1
            defer { transactionDepth = 0 }
            do {
                let value = try body()
                try execute("COMMIT")
                return value
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private var transactionDepth = 0

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteError.prepare(errorMessage, sql: sql)
        }
        return statement
    }

    private func bind(_ params: [Any?], to statement: OpaquePointer?, sql: String) throws {
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case nil:
                result = sqlite3_bind_null(statement, index)
            case let string as String:
                result = sqlite3_bind_text(statement, index, string, -1, transient)
            case let int as Int:
                result = sqlite3_bind_int64(statement, index, Int64(int))
            case let int as Int64:
                result = sqlite3_bind_int64(statement, index, int)
            case let double as Double:
                result = sqlite3_bind_double(statement, index, double)
            case let bool as Bool:
                result = sqlite3_bind_int(statement, index, bool ? 1 : 0)
            case let date as Date:
                result = sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
            case let data as Data:
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
                }
            default:
                result = sqlite3_bind_text(statement, index, String(describing: value!), -1, transient)
            }
            if result != SQLITE_OK {
                throw SQLiteError.prepare(errorMessage, sql: sql)
            }
        }
    }
}

/// Read access to the current row of a query.
public struct SQLiteRow {
    let statement: OpaquePointer

    public func isNull(_ index: Int) -> Bool {
        sqlite3_column_type(statement, Int32(index)) == SQLITE_NULL
    }

    public func int(_ index: Int) -> Int {
        Int(sqlite3_column_int64(statement, Int32(index)))
    }

    public func optionalInt(_ index: Int) -> Int? {
        isNull(index) ? nil : int(index)
    }

    public func double(_ index: Int) -> Double {
        sqlite3_column_double(statement, Int32(index))
    }

    public func string(_ index: Int) -> String {
        optionalString(index) ?? ""
    }

    public func optionalString(_ index: Int) -> String? {
        guard let text = sqlite3_column_text(statement, Int32(index)) else { return nil }
        return String(cString: text)
    }

    public func date(_ index: Int) -> Date {
        Date(timeIntervalSince1970: double(index))
    }

    public func optionalDate(_ index: Int) -> Date? {
        isNull(index) ? nil : date(index)
    }
}
