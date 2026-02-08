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
            output_path TEXT,
            temperature REAL,
            model_display_name TEXT,
            model_kind TEXT,
            quantization TEXT
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
        CREATE TABLE IF NOT EXISTS run_problem_results (
            run_id TEXT NOT NULL,
            problem_index INTEGER NOT NULL,
            language TEXT NOT NULL,
            inference_duration_ms INTEGER NOT NULL,
            inference_input_tokens INTEGER,
            inference_output_tokens INTEGER,
            eval_passed INTEGER,
            eval_duration_ms INTEGER,
            PRIMARY KEY (run_id, problem_index)
        );
        CREATE INDEX IF NOT EXISTS idx_run_problem_results_run_id ON run_problem_results(run_id);
        """
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, sql, nil, nil, nil)
        // Migrate existing runs table to add optional metadata columns if missing.
        let alterColumns = [
            "ALTER TABLE runs ADD COLUMN temperature REAL",
            "ALTER TABLE runs ADD COLUMN model_display_name TEXT",
            "ALTER TABLE runs ADD COLUMN model_kind TEXT",
            "ALTER TABLE runs ADD COLUMN quantization TEXT",
            "ALTER TABLE runs ADD COLUMN max_output_tokens INTEGER"
        ]
        for alter in alterColumns {
            sqlite3_exec(db, alter, nil, nil, nil) // ignore error if column exists
        }
        // Clean up any ghost rows with invalid run_id (empty, null bytes, or non-UUID) for data integrity
        sqlite3_exec(db, "DELETE FROM run_results WHERE LENGTH(run_id) < 36 OR run_id NOT LIKE '%-%';", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM run_problem_results WHERE LENGTH(run_id) < 36 OR run_id NOT LIKE '%-%';", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM runs WHERE LENGTH(run_id) < 36 OR run_id NOT LIKE '%-%';", nil, nil, nil)
    }

    /// Deletes a run and all its results (run_results, run_problem_results, runs). Call from MainActor; runs on store queue.
    public func deleteRun(runId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM run_problem_results WHERE run_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            if sqlite3_prepare_v2(db, "DELETE FROM run_results WHERE run_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            if sqlite3_prepare_v2(db, "DELETE FROM runs WHERE run_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Deletes per-problem and aggregate results from a given problem index onward (for resume-from-earlier trim).
    public func deleteRunProblemResultsFromIndex(runId: String, fromIndex: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM run_problem_results WHERE run_id = ? AND problem_index >= ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(fromIndex))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            if sqlite3_prepare_v2(db, "DELETE FROM run_results WHERE run_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Deletes only the evaluation result for a run+language, leaving the run intact.
    /// Clears eval_passed/eval_duration_ms from run_problem_results and removes from run_results.
    public func deleteResult(runId: String, language: String) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            // Clear eval columns from per-problem results for this run+language
            if sqlite3_prepare_v2(db, "UPDATE run_problem_results SET eval_passed = NULL, eval_duration_ms = NULL WHERE run_id = ? AND language = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, language, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            // Delete from run_results
            if sqlite3_prepare_v2(db, "DELETE FROM run_results WHERE run_id = ? AND language = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, language, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Deletes the evaluation result for run+language and sets run status to inferenceComplete, then calls completion on the main queue.
    /// Use this when the UI must refresh only after the delete is persisted (avoids race with refreshResults).
    public func deleteResultAndUpdateRunStatus(runId: String, language: String, completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                Task { @MainActor in completion() }
                return
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            // Clear eval columns from per-problem results for this run+language
            if sqlite3_prepare_v2(db, "UPDATE run_problem_results SET eval_passed = NULL, eval_duration_ms = NULL WHERE run_id = ? AND language = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, language, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            // Delete from run_results
            if sqlite3_prepare_v2(db, "DELETE FROM run_results WHERE run_id = ? AND language = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, language, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            // Update run status to inferenceComplete
            let updatedAt = ISO8601DateFormatter().string(from: Date())
            if sqlite3_prepare_v2(db, "UPDATE runs SET status = ?, updated_at = ? WHERE run_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, RunStatus.inferenceComplete.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, updatedAt, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, runId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            Task { @MainActor in completion() }
        }
    }

    /// Updates the status of a run in the database.
    public func updateRunStatus(runId: String, status: String) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            let updatedAt = ISO8601DateFormatter().string(from: Date())
            if sqlite3_prepare_v2(db, "UPDATE runs SET status = ?, updated_at = ? WHERE run_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, updatedAt, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, runId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    public func saveRun(_ state: RunState) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            let sql = "INSERT OR REPLACE INTO runs (run_id, model_id, provider_id, created_at, updated_at, status, output_path, temperature, model_display_name, model_kind, quantization, max_output_tokens) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);"
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
            if let t = state.temperature { sqlite3_bind_double(stmt, 8, t) } else { sqlite3_bind_null(stmt, 8) }
            sqlite3_bind_text(stmt, 9, state.modelDisplayName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, state.modelKind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 11, state.quantization, -1, SQLITE_TRANSIENT)
            if let m = state.maxOutputTokens { sqlite3_bind_int(stmt, 12, Int32(m)) } else { sqlite3_bind_null(stmt, 12) }
            sqlite3_step(stmt)
        }
    }

    /// Saves a single inference problem result for real-time run detail updates.
    public func saveSingleInferenceProblemResult(runId: String, record: InferenceCallRecord) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            let sql = "INSERT OR REPLACE INTO run_problem_results (run_id, problem_index, language, inference_duration_ms, inference_input_tokens, inference_output_tokens, eval_passed, eval_duration_ms) VALUES (?,?,?,?,?,?,NULL,NULL);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(record.problemIndex))
            sqlite3_bind_text(stmt, 3, record.language, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(record.durationMs))
            if let t = record.inputTokens { sqlite3_bind_int(stmt, 5, Int32(t)) } else { sqlite3_bind_null(stmt, 5) }
            if let t = record.outputTokens { sqlite3_bind_int(stmt, 6, Int32(t)) } else { sqlite3_bind_null(stmt, 6) }
            sqlite3_step(stmt)
        }
    }

    public func saveInferenceProblemResults(runId: String, records: [InferenceCallRecord]) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            let updateSql = "UPDATE run_problem_results SET language=?, inference_duration_ms=?, inference_input_tokens=?, inference_output_tokens=? WHERE run_id=? AND problem_index=?;"
            let insertSql = "INSERT OR IGNORE INTO run_problem_results (run_id, problem_index, language, inference_duration_ms, inference_input_tokens, inference_output_tokens, eval_passed, eval_duration_ms) VALUES (?,?,?,?,?,?,NULL,NULL);"
            var updateStmt: OpaquePointer?
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(updateStmt); sqlite3_finalize(insertStmt) }
            for r in records {
                sqlite3_bind_text(updateStmt, 1, r.language, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(updateStmt, 2, Int32(r.durationMs))
                if let t = r.inputTokens { sqlite3_bind_int(updateStmt, 3, Int32(t)) } else { sqlite3_bind_null(updateStmt, 3) }
                if let t = r.outputTokens { sqlite3_bind_int(updateStmt, 4, Int32(t)) } else { sqlite3_bind_null(updateStmt, 4) }
                sqlite3_bind_text(updateStmt, 5, runId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(updateStmt, 6, Int32(r.problemIndex))
                sqlite3_step(updateStmt)
                sqlite3_reset(updateStmt)
                if sqlite3_changes(db) == 0 {
                    sqlite3_bind_text(insertStmt, 1, runId, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(insertStmt, 2, Int32(r.problemIndex))
                    sqlite3_bind_text(insertStmt, 3, r.language, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(insertStmt, 4, Int32(r.durationMs))
                    if let t = r.inputTokens { sqlite3_bind_int(insertStmt, 5, Int32(t)) } else { sqlite3_bind_null(insertStmt, 5) }
                    if let t = r.outputTokens { sqlite3_bind_int(insertStmt, 6, Int32(t)) } else { sqlite3_bind_null(insertStmt, 6) }
                    sqlite3_step(insertStmt)
                    sqlite3_reset(insertStmt)
                }
            }
        }
    }

    public func saveEvalProblemResult(runId: String, problemIndex: Int, language: String, passed: Bool, durationMs: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            let updateSql = "UPDATE run_problem_results SET eval_passed=?, eval_duration_ms=? WHERE run_id=? AND problem_index=?;"
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(updateStmt) }
            sqlite3_bind_int(updateStmt, 1, passed ? 1 : 0)
            sqlite3_bind_int(updateStmt, 2, Int32(durationMs))
            sqlite3_bind_text(updateStmt, 3, runId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(updateStmt, 4, Int32(problemIndex))
            sqlite3_step(updateStmt)
            sqlite3_reset(updateStmt)
            if sqlite3_changes(db) == 0 {
                let insertSql = "INSERT INTO run_problem_results (run_id, problem_index, language, inference_duration_ms, inference_input_tokens, inference_output_tokens, eval_passed, eval_duration_ms) VALUES (?,?,?,0,NULL,NULL,?,?);"
                var insertStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(insertStmt) }
                sqlite3_bind_text(insertStmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(insertStmt, 2, Int32(problemIndex))
                sqlite3_bind_text(insertStmt, 3, language, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(insertStmt, 4, passed ? 1 : 0)
                sqlite3_bind_int(insertStmt, 5, Int32(durationMs))
                sqlite3_step(insertStmt)
            }
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

    /// Updates the aggregate result for (run_id, language). If no row exists, inserts one (e.g. after single-row re-eval).
    public func updateResult(runId: String, language: String, total: Int, passed: Int) {
        let passAt1 = total > 0 ? Double(passed) / Double(total) : 0
        queue.async { [weak self] in
            guard let self else { return }
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            let updateSql = "UPDATE run_results SET total=?, passed=?, pass_at_1=? WHERE run_id=? AND language=?;"
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(updateStmt) }
            sqlite3_bind_int(updateStmt, 1, Int32(total))
            sqlite3_bind_int(updateStmt, 2, Int32(passed))
            sqlite3_bind_double(updateStmt, 3, passAt1)
            sqlite3_bind_text(updateStmt, 4, runId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(updateStmt, 5, language, -1, SQLITE_TRANSIENT)
            sqlite3_step(updateStmt)
            if sqlite3_changes(db) == 0 {
                var insertStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO run_results (run_id, language, total, passed, pass_at_1) VALUES (?,?,?,?,?);", -1, &insertStmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(insertStmt) }
                sqlite3_bind_text(insertStmt, 1, runId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 2, language, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(insertStmt, 3, Int32(total))
                sqlite3_bind_int(insertStmt, 4, Int32(passed))
                sqlite3_bind_double(insertStmt, 5, passAt1)
                sqlite3_step(insertStmt)
            }
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
        public let temperature: Double?
        public let modelDisplayName: String?
        public let modelKind: String?
        public let quantization: String?

        public init(runId: String, modelId: String, providerId: String, language: String, total: Int, passed: Int, passAt1: Double, createdAt: String, temperature: Double? = nil, modelDisplayName: String? = nil, modelKind: String? = nil, quantization: String? = nil) {
            self.runId = runId
            self.modelId = modelId
            self.providerId = providerId
            self.language = language
            self.total = total
            self.passed = passed
            self.passAt1 = passAt1
            self.createdAt = createdAt
            self.temperature = temperature
            self.modelDisplayName = modelDisplayName
            self.modelKind = modelKind
            self.quantization = quantization
        }
    }

    /// Per-problem detail row for run detail view (inference + evaluation timing/tokens).
    public struct RunProblemResultRow: Sendable, Identifiable {
        public var id: String { "\(runId)-\(problemIndex)" }
        public let runId: String
        public let problemIndex: Int
        public let language: String
        public let inferenceDurationMs: Int
        public let inferenceInputTokens: Int?
        public let inferenceOutputTokens: Int?
        public let evalPassed: Bool?
        public let evalDurationMs: Int?
    }

    /// Aggregated timing and token totals per run × language for dashboard.
    public struct RunTimingStat: Sendable, Identifiable {
        public var id: String { "\(runId)-\(language)" }
        public let runId: String
        public let modelDisplayName: String
        public let providerId: String
        public let language: String
        public let totalInferenceMs: Int
        public let totalEvalMs: Int
        public let totalInputTokens: Int
        public let totalOutputTokens: Int
        public let problemCount: Int

        public init(runId: String, modelDisplayName: String, providerId: String, language: String, totalInferenceMs: Int, totalEvalMs: Int, totalInputTokens: Int, totalOutputTokens: Int, problemCount: Int) {
            self.runId = runId
            self.modelDisplayName = modelDisplayName
            self.providerId = providerId
            self.language = language
            self.totalInferenceMs = totalInferenceMs
            self.totalEvalMs = totalEvalMs
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.problemCount = problemCount
        }

        public var totalTimeMs: Int { totalInferenceMs + totalEvalMs }
        public var avgInferenceMsPerProblem: Int { problemCount > 0 ? totalInferenceMs / problemCount : 0 }
        public var tokensPerProblem: Int { problemCount > 0 ? (totalInputTokens + totalOutputTokens) / problemCount : 0 }
    }

    public func fetchAllResults() -> [ResultRow] {
        queue.sync {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_close(db) }
            let sql = "SELECT r.run_id, r.model_id, r.provider_id, r.created_at, rr.language, rr.total, rr.passed, rr.pass_at_1, r.temperature, r.model_display_name, r.model_kind, r.quantization FROM runs r JOIN run_results rr ON r.run_id = rr.run_id WHERE LENGTH(r.run_id) >= 36 AND r.run_id LIKE '%-%' ORDER BY r.created_at DESC, rr.language;"
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
                let temperature = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8)
                let modelDisplayName = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                let modelKind = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                let quantization = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
                rows.append(ResultRow(runId: runId, modelId: modelId, providerId: providerId, language: language, total: total, passed: passed, passAt1: passAt1, createdAt: createdAt, temperature: temperature, modelDisplayName: modelDisplayName, modelKind: modelKind, quantization: quantization))
            }
            return rows
        }
    }

    public func fetchRunProblemResults(runId: String) -> [RunProblemResultRow] {
        queue.sync {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_close(db) }
            let sql = "SELECT run_id, problem_index, language, inference_duration_ms, inference_input_tokens, inference_output_tokens, eval_passed, eval_duration_ms FROM run_problem_results WHERE run_id = ? ORDER BY problem_index;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
            var rows: [RunProblemResultRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let runIdStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let problemIndex = Int(sqlite3_column_int(stmt, 1))
                let language = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let inferenceDurationMs = Int(sqlite3_column_int(stmt, 3))
                let inferenceInputTokens = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
                let inferenceOutputTokens = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
                let evalPassed: Bool? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : (sqlite3_column_int(stmt, 6) != 0)
                let evalDurationMs: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 7))
                rows.append(RunProblemResultRow(runId: runIdStr, problemIndex: problemIndex, language: language, inferenceDurationMs: inferenceDurationMs, inferenceInputTokens: inferenceInputTokens, inferenceOutputTokens: inferenceOutputTokens, evalPassed: evalPassed, evalDurationMs: evalDurationMs))
            }
            return rows
        }
    }

    /// Aggregated timing per run × language for dashboard charts (sorted by total time ascending).
    public func fetchRunTimingStats() -> [RunTimingStat] {
        queue.sync {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_close(db) }
            let sql = """
            SELECT r.run_id, COALESCE(r.model_display_name, r.model_id), r.provider_id, p.language,
                   SUM(p.inference_duration_ms) AS total_inference_ms,
                   SUM(COALESCE(p.eval_duration_ms, 0)) AS total_eval_ms,
                   COALESCE(SUM(p.inference_input_tokens), 0) AS total_input_tokens,
                   COALESCE(SUM(p.inference_output_tokens), 0) AS total_output_tokens,
                   COUNT(*) AS problem_count
            FROM runs r
            JOIN run_problem_results p ON r.run_id = p.run_id
            WHERE LENGTH(r.run_id) >= 36 AND r.run_id LIKE '%-%'
            GROUP BY r.run_id, p.language
            ORDER BY total_inference_ms + total_eval_ms ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [RunTimingStat] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let runId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let modelDisplayName = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let providerId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let language = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let totalInferenceMs = Int(sqlite3_column_int(stmt, 4))
                let totalEvalMs = Int(sqlite3_column_int(stmt, 5))
                let totalInputTokens = Int(sqlite3_column_int(stmt, 6))
                let totalOutputTokens = Int(sqlite3_column_int(stmt, 7))
                let problemCount = Int(sqlite3_column_int(stmt, 8))
                rows.append(RunTimingStat(runId: runId, modelDisplayName: modelDisplayName, providerId: providerId, language: language, totalInferenceMs: totalInferenceMs, totalEvalMs: totalEvalMs, totalInputTokens: totalInputTokens, totalOutputTokens: totalOutputTokens, problemCount: problemCount))
            }
            return rows
        }
    }
}
