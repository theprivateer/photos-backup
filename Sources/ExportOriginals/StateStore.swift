import Foundation

final class StateStore {
    private let database: SQLiteDatabase
    private let isoFormatter = ISO8601DateFormatter()
    private let stateDBURL: URL

    init(databaseURL: URL) throws {
        self.stateDBURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        self.database = try SQLiteDatabase(path: databaseURL.path)
        try migrate()
    }

    var logURL: URL {
        stateDBURL.deletingPathExtension().appendingPathExtension("log")
    }

    func beginRun() throws -> RunRecord {
        let now = Date()
        let statement = try database.prepare("INSERT INTO runs(started_at, status) VALUES(?, ?);")
        defer { statement.reset() }
        try statement.bind(isoFormatter.string(from: now), at: 1)
        try statement.bind("running", at: 2)
        _ = try statement.step()
        return RunRecord(id: database.lastInsertRowID(), startedAt: now)
    }

    func finishRun(_ run: RunRecord, summary: ExportSummary) throws {
        let statement = try database.prepare(
            """
            UPDATE runs
            SET finished_at = ?, status = ?, discovered_count = ?, copied_count = ?, skipped_count = ?, failed_count = ?, resumed_count = ?
            WHERE id = ?;
            """
        )
        defer { statement.reset() }
        try statement.bind(isoFormatter.string(from: Date()), at: 1)
        try statement.bind(summary.failedCount == 0 ? "success" : "failed", at: 2)
        try statement.bind(Int64(summary.discoveredCount), at: 3)
        try statement.bind(Int64(summary.copiedCount), at: 4)
        try statement.bind(Int64(summary.skippedCount), at: 5)
        try statement.bind(Int64(summary.failedCount), at: 6)
        try statement.bind(Int64(summary.resumedCount), at: 7)
        try statement.bind(run.id, at: 8)
        _ = try statement.step()
    }

    func fetchRecord(stableID: String) throws -> AssetRecord? {
        let statement = try database.prepare(
            """
            SELECT stable_id, asset_id, source_path, source_size, source_creation_date, source_modification_date,
                   capture_date, destination_path, temp_path, status, verification_mode, hash_value, last_error, updated_at
            FROM assets
            WHERE stable_id = ?;
            """
        )
        defer { statement.reset() }
        try statement.bind(stableID, at: 1)
        guard try statement.step() else { return nil }
        return try decodeRecord(statement)
    }

    func upsert(record: AssetRecord) throws {
        let statement = try database.prepare(
            """
            INSERT INTO assets(
                stable_id, asset_id, source_path, source_size, source_creation_date, source_modification_date,
                capture_date, destination_path, temp_path, status, verification_mode, hash_value, last_error, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(stable_id) DO UPDATE SET
                asset_id = excluded.asset_id,
                source_path = excluded.source_path,
                source_size = excluded.source_size,
                source_creation_date = excluded.source_creation_date,
                source_modification_date = excluded.source_modification_date,
                capture_date = excluded.capture_date,
                destination_path = excluded.destination_path,
                temp_path = excluded.temp_path,
                status = excluded.status,
                verification_mode = excluded.verification_mode,
                hash_value = excluded.hash_value,
                last_error = excluded.last_error,
                updated_at = excluded.updated_at;
            """
        )
        defer { statement.reset() }
        try statement.bind(record.stableID, at: 1)
        try statement.bind(record.assetID, at: 2)
        try statement.bind(record.sourcePath, at: 3)
        try statement.bind(Int64(record.sourceSize), at: 4)
        try bind(date: record.sourceCreationDate, to: statement, at: 5)
        try bind(date: record.sourceModificationDate, to: statement, at: 6)
        try statement.bind(isoFormatter.string(from: record.captureDate), at: 7)
        try statement.bind(record.destinationPath, at: 8)
        try statement.bind(record.tempPath, at: 9)
        try statement.bind(record.status.rawValue, at: 10)
        try statement.bind(record.verificationMode.rawValue, at: 11)
        try statement.bind(record.hashValue, at: 12)
        try statement.bind(record.lastError, at: 13)
        try statement.bind(isoFormatter.string(from: record.updatedAt), at: 14)
        _ = try statement.step()
    }

    func appendLog(event: [String: String]) {
        let data = (event
            .map { key, value in "\"\(escape(key))\":\"\(escape(value))\"" }
            .sorted()
            .joined(separator: ","))
        let line = "{\(data)}\n"
        if FileManager.default.fileExists(atPath: logURL.path) == false {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            Console.error("warning: failed to write log \(error.localizedDescription)")
        }
    }

    private func migrate() throws {
        try database.exec(
            """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS runs(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at TEXT NOT NULL,
                finished_at TEXT,
                status TEXT NOT NULL,
                discovered_count INTEGER NOT NULL DEFAULT 0,
                copied_count INTEGER NOT NULL DEFAULT 0,
                skipped_count INTEGER NOT NULL DEFAULT 0,
                failed_count INTEGER NOT NULL DEFAULT 0,
                resumed_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS assets(
                stable_id TEXT PRIMARY KEY,
                asset_id TEXT NOT NULL,
                source_path TEXT NOT NULL,
                source_size INTEGER NOT NULL,
                source_creation_date TEXT,
                source_modification_date TEXT,
                capture_date TEXT NOT NULL,
                destination_path TEXT NOT NULL,
                temp_path TEXT,
                status TEXT NOT NULL,
                verification_mode TEXT NOT NULL,
                hash_value TEXT,
                last_error TEXT,
                updated_at TEXT NOT NULL
            );
            """
        )
    }

    private func bind(date: Date?, to statement: SQLiteStatement, at index: Int32) throws {
        if let date {
            try statement.bind(isoFormatter.string(from: date), at: index)
        } else {
            try statement.bind(nil as String?, at: index)
        }
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return isoFormatter.date(from: value)
    }

    private func decodeRecord(_ statement: SQLiteStatement) throws -> AssetRecord {
        AssetRecord(
            stableID: statement.string(at: 0) ?? "",
            assetID: statement.string(at: 1) ?? "",
            sourcePath: statement.string(at: 2) ?? "",
            sourceSize: UInt64(statement.int64(at: 3)),
            sourceCreationDate: parseDate(statement.string(at: 4)),
            sourceModificationDate: parseDate(statement.string(at: 5)),
            captureDate: parseDate(statement.string(at: 6)) ?? Date.distantPast,
            destinationPath: statement.string(at: 7) ?? "",
            tempPath: statement.string(at: 8),
            status: AssetStatus(rawValue: statement.string(at: 9) ?? "") ?? .failed,
            verificationMode: VerificationMode(rawValue: statement.string(at: 10) ?? "") ?? .fast,
            hashValue: statement.string(at: 11),
            lastError: statement.string(at: 12),
            updatedAt: parseDate(statement.string(at: 13)) ?? Date()
        )
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
