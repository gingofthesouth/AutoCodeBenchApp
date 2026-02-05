import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to make its own copy of the string
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite store for runs and pass@1 results (model × language × date).
public final class ResultsStore: Sendable {
    private let dbPath: URL
    private let queue = DispatchQueue(label: "com.autocodebench.resultsstore")

    public init(appSupportDirectory: URL) {
        self.dbPath = appSupportDirectory.appending(path: "results.db")
        queue.sync { createTables() }
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS runs (
            run_id TEXT PRIMARY KEY,
            model_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            status TEXT NOT NULL,
            output_path TEXT
        );
        CREATE TABLE IF NOT EXISTS run_results (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT NOT NULL,
            language TEXT NOT NULL,
            total INTEGER NOT NULL,
            passed INTEGER NOT NULL,
            pass_at_1 REAL NOT NULL,
            FOREIGN KEY (run_id) REFERENCES runs(run_id)
        );
        CREATE INDEX IF NOT EXISTS idx_run_results_run_id ON run_results(run_id);
        CREATE INDEX IF NOT EXISTS idx_run_results_language ON run_results(language);
        """
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    public func saveRun(_ state: RunState) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            let sql = "INSERT OR REPLACE INTO runs (run_id, model_id, provider_id, created_at, updated_at, status, output_path) VALUES (?,?,?,?,?,?,?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let createdAt = ISO8601DateFormatter().string(from: state.createdAt)
            let updatedAt = ISO8601DateFormatter().string(from: state.updatedAt)
            sqlite3_bind_text(stmt, 1, state.runId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, state.modelId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, state.providerId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, createdAt, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, updatedAt, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, state.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, state.outputPath, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func saveResult(runId: String, language: String, total: Int, passed: Int) {
        let passAt1 = total > 0 ? Double(passed) / Double(total) : 0
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            let sql = "INSERT INTO run_results (run_id, language, total, passed, pass_at_1) VALUES (?,?,?,?,?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, language, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(total))
            sqlite3_bind_int(stmt, 4, Int32(passed))
            sqlite3_bind_double(stmt, 5, passAt1)
            sqlite3_step(stmt)
        }
    }

    public struct ResultRow: Sendable, Identifiable {
        public var id: String { "\(runId)-\(language)" }
        public let runId: String
        public let modelId: String
        public let providerId: String
        public let language: String
        public let total: Int
        public let passed: Int
        public let passAt1: Double
        public let createdAt: String
    }

    public func fetchAllResults() -> [ResultRow] {
        queue.sync {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_close(db) }
            let sql = "SELECT r.run_id, r.model_id, r.provider_id, r.created_at, rr.language, rr.total, rr.passed, rr.pass_at_1 FROM runs r JOIN run_results rr ON r.run_id = rr.run_id ORDER BY r.created_at DESC, rr.language;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [ResultRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let runId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let modelId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let providerId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let createdAt = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let language = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let total = Int(sqlite3_column_int(stmt, 5))
                let passed = Int(sqlite3_column_int(stmt, 6))
                let passAt1 = sqlite3_column_double(stmt, 7)
                rows.append(ResultRow(runId: runId, modelId: modelId, providerId: providerId, language: language, total: total, passed: passed, passAt1: passAt1, createdAt: createdAt))
            }
            return rows
        }
    }
}
