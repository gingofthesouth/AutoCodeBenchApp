import Foundation

/// Runs inference on filtered problems, skips indices that already have output, persists run state.
public actor InferenceRunner {
    private let provider: any InferenceProvider
    private let datasetService: DatasetDownloadService
    private let runStatePath: URL
    private var state: RunState
    private var rows: [BenchmarkRow]
    private var isCancelled = false

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
    public func run(progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let pending = (0..<rows.count).filter { !state.completedIndices.contains($0) }
        let outputURL = datasetService.appSupportDirectory
            .appending(path: "runs", directoryHint: .isDirectory)
            .appending(path: "\(state.runId)_output.jsonl")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        for (i, idx) in pending.enumerated() {
            if isCancelled { state.status = .paused; try? persistState(); return }
            let problem = rows[idx]
            let response: String
            do {
                response = try await provider.complete(
                    systemPrompt: DatasetDownloadService.systemPrompt,
                    userPrompt: problem.question
                )
            } catch {
                state.status = .failed
                state.updatedAt = Date()
                try? persistState()
                throw error
            }
            rows[idx].output = response
            state.completedIndices.insert(idx)
            state.updatedAt = Date()
            try persistState()
            try writeRows(to: outputURL)
            progress(state.completedIndices.count, rows.count)
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
