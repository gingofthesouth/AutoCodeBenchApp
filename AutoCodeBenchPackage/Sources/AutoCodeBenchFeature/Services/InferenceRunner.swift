import Foundation

/// Per-problem inference record for persistence (timing and token usage).
public struct InferenceCallRecord: Sendable {
    public let problemIndex: Int
    public let language: String
    public let durationMs: Int
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(problemIndex: Int, language: String, durationMs: Int, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.problemIndex = problemIndex
        self.language = language
        self.durationMs = durationMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Runs inference on filtered problems, skips indices that already have output, persists run state.
public actor InferenceRunner {
    private let provider: any InferenceProvider
    private let datasetService: DatasetDownloadService
    private let runStatePath: URL
    private var state: RunState
    private var rows: [BenchmarkRow]
    private var isCancelled = false
    /// Per-problem inference results (duration, tokens) for persistence.
    private var inferenceCallRecords: [InferenceCallRecord] = []

    public init(provider: any InferenceProvider, datasetService: DatasetDownloadService, runState: RunState, problems: [BenchmarkProblem]) {
        self.provider = provider
        self.datasetService = datasetService
        self.state = runState
        self.rows = problems.map { BenchmarkRow(from: $0, output: nil) }
        self.runStatePath = datasetService.appSupportDirectory
            .appending(path: "runs", directoryHint: .isDirectory)
            .appending(path: "\(runState.runId)_state.json")
        try? FileManager.default.createDirectory(at: runStatePath.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Load existing output into rows (for resume).
    public func loadExistingOutput(from path: URL) throws {
        let data = try Data(contentsOf: path)
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let decoder = JSONDecoder()
        for (idx, line) in lines.enumerated() where idx < rows.count {
            struct RowDecode: Decodable {
                let output: String?
            }
            if let decoded = try? decoder.decode(RowDecode.self, from: Data(line)), let out = decoded.output, !out.isEmpty {
                rows[idx].output = out
                state.completedIndices.insert(idx)
            }
        }
        state.updatedAt = Date()
        try persistState()
    }

    /// Run inference for all indices that don't have output yet. Calls progress(completed, total) on each item.
    /// If onProblemComplete is non-nil, it is called after each problem with (index, row) for e.g. evaluation queue.
    /// If onInferenceRecord is non-nil, it is called after each problem with the inference record for real-time persistence.
    public func run(
        progress: @escaping @Sendable (Int, Int) -> Void,
        onProblemComplete: (@Sendable (Int, BenchmarkRow) -> Void)? = nil,
        onInferenceRecord: (@Sendable (InferenceCallRecord) -> Void)? = nil
    ) async throws {
        let pending = (0..<rows.count).filter { !state.completedIndices.contains($0) }
        let outputURL = datasetService.appSupportDirectory
            .appending(path: "runs", directoryHint: .isDirectory)
            .appending(path: "\(state.runId)_output.jsonl")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        for (_, idx) in pending.enumerated() {
            if isCancelled { state.status = .paused; try? persistState(); return }
            let problem = rows[idx]
            let result: InferenceResult
            do {
                result = try await provider.complete(
                    systemPrompt: DatasetDownloadService.systemPrompt,
                    userPrompt: problem.question,
                    temperature: state.temperature,
                    maxTokens: state.maxOutputTokens
                )
            } catch {
                state.status = .failed
                state.updatedAt = Date()
                try? persistState()
                throw error
            }
            rows[idx].output = result.text
            let record = InferenceCallRecord(
                problemIndex: idx,
                language: rows[idx].language,
                durationMs: Int(result.duration * 1000),
                inputTokens: result.usage?.inputTokens,
                outputTokens: result.usage?.outputTokens
            )
            inferenceCallRecords.append(record)
            state.completedIndices.insert(idx)
            state.updatedAt = Date()
            try persistState()
            try writeRows(to: outputURL)
            progress(state.completedIndices.count, rows.count)
            onProblemComplete?(idx, rows[idx])
            onInferenceRecord?(record)
        }

        state.status = .inferenceComplete
        state.outputPath = outputURL.path
        try persistState()
        try writeRows(to: outputURL)
    }

    public func cancel() {
        isCancelled = true
    }

    public func currentState() -> RunState { state }
    public func currentRows() -> [BenchmarkRow] { rows }
    /// Per-problem inference records (duration, tokens) for persistence.
    public func getInferenceCallRecords() -> [InferenceCallRecord] { inferenceCallRecords }

    private func persistState() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var stateToEncode = state
        stateToEncode.completedIndices = state.completedIndices
        let data = try encoder.encode(stateToEncode)
        try data.write(to: runStatePath)
    }

    private func writeRows(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines: [String] = []
        for row in rows {
            let data = try encoder.encode(row)
            lines.append(String(data: data, encoding: .utf8)!)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
