import Foundation
import SQLite3

enum SQLiteError: Error, LocalizedError, CustomStringConvertible {
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case step(String)
    case bind(String)

    var description: String {
        switch self {
        case .openDatabase(let message),
             .execute(let message),
             .prepare(let message),
             .step(let message),
             .bind(let message):
            return message
        }
    }

    var errorDescription: String? {
        description
    }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)

        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            defer { sqlite3_close(handle) }
            throw SQLiteError.openDatabase(String(cString: sqlite3_errmsg(handle)))
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorMessage)
            throw SQLiteError.execute(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(database: self, statement: statement)
    }

    func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    fileprivate var rawHandle: OpaquePointer? {
        handle
    }
}

final class SQLiteStatement {
    private let database: SQLiteDatabase
    private var statement: OpaquePointer?

    init(database: SQLiteDatabase, statement: OpaquePointer?) {
        self.database = database
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func bind(_ value: String?, at index: Int32) throws {
        if let value {
            if sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
                throw SQLiteError.bind(String(cString: sqlite3_errmsg(database.rawHandle)))
            }
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(database.rawHandle)))
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        if sqlite3_bind_int64(statement, index, value) != SQLITE_OK {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(database.rawHandle)))
        }
    }

    func bind(_ value: Double, at index: Int32) throws {
        if sqlite3_bind_double(statement, index, value) != SQLITE_OK {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(database.rawHandle)))
        }
    }

    func bindNull(at index: Int32) throws {
        if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(database.rawHandle)))
        }
    }

    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteError.step(String(cString: sqlite3_errmsg(database.rawHandle)))
        }
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func string(at index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
