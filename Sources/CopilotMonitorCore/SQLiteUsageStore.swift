import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteUsageStoreError: Error, LocalizedError {
    case open(String)
    case statement(String)

    public var errorDescription: String? {
        switch self {
        case let .open(message): return "Não foi possível abrir o banco de uso: \(message)"
        case let .statement(message): return "Erro ao acessar o histórico de uso: \(message)"
        }
    }
}

public final class SQLiteUsageStore {
    private var database: OpaquePointer?

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let result = sqlite3_open(url.path, &database)
        guard result == SQLITE_OK, database != nil else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite não abriu o arquivo."
            throw SQLiteUsageStoreError.open(message)
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS samples(
                ts INTEGER NOT NULL,
                used REAL NOT NULL,
                entitlement REAL NOT NULL,
                overage REAL NOT NULL,
                reset_date TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS samples_ts_idx ON samples(ts);
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value BLOB NOT NULL);
            """)
    }

    deinit { sqlite3_close(database) }

    public func append(_ sample: UsageSample) throws {
        let statement = try prepare("INSERT INTO samples(ts, used, entitlement, overage, reset_date) VALUES(?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sample.timestamp)
        sqlite3_bind_double(statement, 2, sample.used)
        sqlite3_bind_double(statement, 3, sample.entitlement)
        sqlite3_bind_double(statement, 4, sample.overage)
        bind(sample.resetDate, to: statement, at: 5)
        try stepDone(statement)
    }

    public func samples(since timestamp: Int64 = 0) throws -> [UsageSample] {
        let statement = try prepare("SELECT ts, used, entitlement, overage, reset_date FROM samples WHERE ts >= ? ORDER BY ts")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, timestamp)
        var result: [UsageSample] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 4) else {
                throw currentError()
            }
            result.append(UsageSample(
                timestamp: sqlite3_column_int64(statement, 0),
                used: sqlite3_column_double(statement, 1),
                entitlement: sqlite3_column_double(statement, 2),
                overage: sqlite3_column_double(statement, 3),
                resetDate: String(cString: text)
            ))
        }
        return result
    }

    public func latestSample() throws -> UsageSample? {
        let statement = try prepare(
            "SELECT ts, used, entitlement, overage, reset_date FROM samples ORDER BY ts DESC LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 4) else {
            throw currentError()
        }
        return UsageSample(
            timestamp: sqlite3_column_int64(statement, 0),
            used: sqlite3_column_double(statement, 1),
            entitlement: sqlite3_column_double(statement, 2),
            overage: sqlite3_column_double(statement, 3),
            resetDate: String(cString: text)
        )
    }

    public func removeAllSamples() throws {
        try execute("DELETE FROM samples")
    }

    public func setMetadata(_ value: Data?, forKey key: String) throws {
        if let value {
            let statement = try prepare("INSERT OR REPLACE INTO metadata(key, value) VALUES(?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(key, to: statement, at: 1)
            _ = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
            try stepDone(statement)
        } else {
            let statement = try prepare("DELETE FROM metadata WHERE key = ?")
            defer { sqlite3_finalize(statement) }
            bind(key, to: statement, at: 1)
            try stepDone(statement)
        }
    }

    public func metadata(forKey key: String) throws -> Data? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw currentError() }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let description = message.map { String(cString: $0) } ?? currentMessage()
            sqlite3_free(message)
            throw SQLiteUsageStoreError.statement(description)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw currentError() }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func currentError() -> SQLiteUsageStoreError { .statement(currentMessage()) }
    private func currentMessage() -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "Conexão SQLite indisponível."
    }
}
