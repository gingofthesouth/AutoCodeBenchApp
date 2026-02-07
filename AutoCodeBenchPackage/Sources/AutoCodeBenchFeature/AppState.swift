import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class AppState {
    public var cachedDatasetPath: URL?
    public var availableLanguages: [String] = []
    public var selectedLanguages: Set<String> = []
    public var providers: [ProviderConfig] = []
    public var selectedProviderId: String?
    public var selectedModelId: String?
    public var runs: [RunState] = []
    public var currentRunId: String?
    /// Per-run live progress (inference and evaluation) for runs currently executing.
    public var liveProgress: [String: LiveRunProgress] = [:]
    /// Global progress for backward compatibility when a single run is focused (e.g. legacy evaluation).
    public var inferenceProgress: (completed: Int, total: Int)?
    public var evaluationProgress: (completed: Int, total: Int)?
    public var resultsTable: [ResultsStore.ResultRow] = []
    /// Aggregated run timing for dashboard (time to complete, tokens, speed).
    public var timingStats: [ResultsStore.RunTimingStat] = []
    /// Persistent color assignments for model variants (provider + model + quantization) used in dashboard charts.
    public var modelColors: [ModelColorAssignment] = []
    public var errorMessage: String?
    public var isDownloading = false
    /// True if any run is currently executing inference.
    public var isRunningInference: Bool { !runningRunTasks.isEmpty }
    public var isRunningEvaluation = false
    /// Run ID currently being evaluated (for showing progress in RunDetailView).
    public var currentEvaluatingRunId: String?
    /// When true, evaluation runs when inference completes (batch). When false, each answer is enqueued for evaluation (global queue).
    public var evaluateWhenRunCompletes: Bool = true
    /// Run-level options for new runs (temperature, model kind, quantization, max output tokens).
    public var runTemperature: Double?
    public var runModelKind: String?
    public var runQuantization: String?
    public var runMaxOutputTokens: Int?
    /// When set, ContentView should switch to Runs tab and select this run ID, then clear.
    public var pendingRunIdToSelect: String?

    /// Incremented when run problem results change so RunDetailView refetches (real-time updates).
    public var problemResultsVersion: [String: Int] = [:]

    /// Active inference tasks by runId; used to support multiple concurrent runs and pause by runId.
    private var runningRunTasks: [String: Task<Void, Never>] = [:]
    /// Runner references so pause/delete can signal cancel() for responsive stop.
    private var runRunners: [String: InferenceRunner] = [:]
    public var availableModels: [ProviderModel] = []
    public var isLoadingModels = false
    public var modelListingError: String?
    public var lastSandboxCheck: Bool?
    public var sandboxStatus = SandboxStatus(kind: .unknown, message: "Not checked yet.")
    public var isCheckingSandbox = false
    public var isFixingSandbox = false
    public var fixSandboxStep: String?
    public var sandboxLastError: String?

    /// When true, refreshResults() and loadRuns() no-op so preview state is not overwritten. Set only by preview factory.
    var isPreviewMode = false

    private let datasetService = DatasetDownloadService()
    private let modelListingService = ModelListingService()
    private let sandboxDiagnostics = SandboxDiagnosticsService()
    private var resultsStore: ResultsStore?
    private var evaluationService = EvaluationService()
    private var evaluationStream: AsyncStream<EvaluationQueueItem>?
    private var evaluationQueueContinuation: AsyncStream<EvaluationQueueItem>.Continuation?
    private var evaluationQueueAccumulator: [String: (passed: Int, evaluated: Int)] = [:]

    public init() {
        loadSelectedLanguages()
        loadCachedPath()
        loadProviders()
        loadEvaluateWhenRunCompletes()
        loadModelColors()
        resultsStore = ResultsStore(appSupportDirectory: datasetService.appSupportDirectory)
        refreshResults()
        let (stream, continuation) = AsyncStream.makeStream(of: EvaluationQueueItem.self)
        evaluationStream = stream
        evaluationQueueContinuation = continuation
        startEvaluationQueueConsumer(stream: stream)
    }

    public func setEvaluateWhenRunCompletes(_ value: Bool) {
        evaluateWhenRunCompletes = value
        saveEvaluateWhenRunCompletes()
    }

    private func loadEvaluateWhenRunCompletes() {
        let url = datasetService.appSupportDirectory.appending(path: "evaluate_when_complete.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Bool.self, from: data) else { return }
        evaluateWhenRunCompletes = decoded
    }

    private func saveEvaluateWhenRunCompletes() {
        let url = datasetService.appSupportDirectory.appending(path: "evaluate_when_complete.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(evaluateWhenRunCompletes).write(to: url)
    }

    private func startEvaluationQueueConsumer(stream: AsyncStream<EvaluationQueueItem>) {
        Task { @MainActor in
            for await item in stream {
                let passed: Bool
                let durationMs: Int
                do {
                    let result = try? await evaluationService.evaluateRow(item.row)
                    passed = result?.passed ?? false
                    durationMs = result.map { Int($0.duration * 1000) } ?? 0
                } catch {
                    continue
                }
                applyEvaluationQueueResult(runId: item.runId, problemIndex: item.problemIndex, language: item.row.language, passed: passed, durationMs: durationMs, totalProblems: item.totalProblems)
            }
        }
    }

    private func applyEvaluationQueueResult(runId: String, problemIndex: Int, language: String, passed: Bool, durationMs: Int, totalProblems: Int) {
        resultsStore?.saveEvalProblemResult(runId: runId, problemIndex: problemIndex, language: language, passed: passed, durationMs: durationMs)
        var acc = evaluationQueueAccumulator[runId] ?? (passed: 0, evaluated: 0)
        acc.evaluated += 1
        if passed { acc.passed += 1 }
        evaluationQueueAccumulator[runId] = acc
        var cur = liveProgress[runId] ?? LiveRunProgress()
        cur.evaluationPassed = acc.passed
        cur.evaluationTotal = acc.evaluated
        liveProgress[runId] = cur
        if acc.evaluated >= totalProblems {
            resultsStore?.saveResult(runId: runId, language: language, total: totalProblems, passed: acc.passed)
            evaluationQueueAccumulator.removeValue(forKey: runId)
            if var state = runs.first(where: { $0.runId == runId }) {
                state.status = .done
                state.updatedAt = Date()
                resultsStore?.saveRun(state)
                loadRuns()
                refreshResults()
            }
            liveProgress.removeValue(forKey: runId)
        }
    }

    public var appSupportDirectory: URL { datasetService.appSupportDirectory }

    public func loadCachedPath() {
        let path = datasetService.cachedDatasetPath
        if FileManager.default.fileExists(atPath: path.path) {
            cachedDatasetPath = path
            loadLanguages()
        } else {
            cachedDatasetPath = nil
            availableLanguages = []
        }
    }

    public func loadLanguages() {
        guard let path = cachedDatasetPath else { return }
        availableLanguages = (try? datasetService.availableLanguages(at: path)) ?? []
        // Keep only selected languages that still exist in the dataset
        selectedLanguages.formIntersection(availableLanguages)
    }

    public func loadSelectedLanguages() {
        let url = datasetService.appSupportDirectory.appending(path: "selected_languages.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            selectedLanguages = []
            return
        }
        selectedLanguages = Set(decoded)
    }

    public func saveSelectedLanguages() {
        let url = datasetService.appSupportDirectory.appending(path: "selected_languages.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let array = Array(selectedLanguages)
        try? JSONEncoder().encode(array).write(to: url)
    }

    public func downloadDataset() async {
        isDownloading = true
        errorMessage = nil
        do {
            _ = try await datasetService.downloadDataset()
            await MainActor.run {
                loadCachedPath()
                isDownloading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isDownloading = false
            }
        }
    }

    public func loadProviders() {
        let url = datasetService.appSupportDirectory.appending(path: "providers.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) else {
            providers = []
            return
        }
        providers = decoded
        if selectedProviderId == nil { selectedProviderId = decoded.first(where: \.isDefault)?.id ?? decoded.first?.id }
    }

    public func saveProviders() {
        let url = datasetService.appSupportDirectory.appending(path: "providers.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(providers).write(to: url)
    }

    public func addProvider(_ config: ProviderConfig) {
        providers.append(config)
        saveProviders()
    }

    public func updateProvider(_ config: ProviderConfig) {
        if let i = providers.firstIndex(where: { $0.id == config.id }) {
            providers[i] = config
            saveProviders()
        }
    }

    public func deleteProvider(id: String) {
        providers.removeAll { $0.id == id }
        if selectedProviderId == id {
            selectedProviderId = providers.first?.id
            selectedModelId = nil
            availableModels = []
        }
        saveProviders()
    }

    public func fetchAvailableModels() async {
        guard let providerId = selectedProviderId,
              let config = providers.first(where: { $0.id == providerId }) else {
            availableModels = []
            modelListingError = nil
            return
        }
        isLoadingModels = true
        modelListingError = nil
        do {
            let models = try await modelListingService.listModels(config: config)
            await MainActor.run {
                availableModels = models
                if selectedModelId.map({ mid in !models.contains(where: { $0.id == mid }) }) == true {
                    selectedModelId = models.first?.id
                }
                isLoadingModels = false
            }
        } catch {
            if let providerError = error as? ProviderError, case .apiError(let statusCode, let message) = providerError {
                print("[AutoCodeBench] Model listing API error: statusCode=\(statusCode) body=\(message)")
            } else if let urlError = error as? URLError {
                print("[AutoCodeBench] Model listing network error: \(urlError.code.rawValue) \(urlError.localizedDescription)")
            } else {
                let ns = error as NSError
                print("[AutoCodeBench] Model listing error: \(ns.domain) \(ns.code) \(error)")
            }
            await MainActor.run {
                availableModels = []
                modelListingError = error.localizedDescription
                isLoadingModels = false
            }
        }
    }

    public func startRun() async {
        guard let providerId = selectedProviderId,
              let modelId = selectedModelId,
              let providerConfig = providers.first(where: { $0.id == providerId }),
              let path = cachedDatasetPath else {
            errorMessage = "Select provider, model, and ensure dataset is downloaded."
            return
        }
        let languages = Array(selectedLanguages)
        guard !languages.isEmpty else {
            errorMessage = "Select at least one language."
            return
        }
        let problems: [BenchmarkProblem]
        do {
            problems = try datasetService.loadProblems(from: path, languages: languages)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard !problems.isEmpty else {
            errorMessage = "No problems found for selected languages."
            return
        }

        let runId = UUID().uuidString
        let selectedModel = availableModels.first(where: { $0.id == modelId })
        let modelDisplayName = selectedModel?.displayName
        let modelKind = selectedModel?.modelKind ?? runModelKind
        let quantization = selectedModel?.quantization
        var state = RunState(
            runId: runId,
            modelId: modelId,
            providerId: providerId,
            languages: languages,
            temperature: runTemperature,
            modelDisplayName: modelDisplayName,
            modelKind: modelKind,
            quantization: quantization,
            maxOutputTokens: runMaxOutputTokens
        )
        let runsDir = datasetService.appSupportDirectory.appending(path: "runs", directoryHint: .isDirectory)
        let stateURL = runsDir.appending(path: "\(runId)_state.json")
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateURL)
        }
        let provider: any InferenceProvider
        switch providerConfig.kind {
        case .anthropic:
            provider = AnthropicProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, modelId: modelId)
        case .lmStudio:
            let base = providerConfig.baseURL ?? "http://127.0.0.1:1234"
            provider = LMStudioProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, baseURL: base, modelId: modelId, modelKind: modelKind)
        case .openai, .openRouter, .ollama, .custom:
            let base = providerConfig.baseURL ?? (providerConfig.kind == .openai ? "https://api.openai.com" : "http://localhost:1234")
            provider = OpenAIProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, baseURL: base, modelId: modelId)
        }
        let runner = InferenceRunner(provider: provider, datasetService: datasetService, runState: state, problems: problems)
        runRunners[runId] = runner
        errorMessage = nil
        resultsStore?.saveRun(state)
        liveProgress[runId] = LiveRunProgress(inferenceCompleted: 0, inferenceTotal: problems.count)
        loadRuns()
        pendingRunIdToSelect = runId

        let totalProblems = problems.count
        let continuation = evaluationQueueContinuation
        let onProblemComplete: (@Sendable (Int, BenchmarkRow) -> Void)? = evaluateWhenRunCompletes ? nil : { [continuation] index, row in
            _ = continuation?.yield(EvaluationQueueItem(runId: runId, problemIndex: index, row: row, totalProblems: totalProblems))
        } as (@Sendable (Int, BenchmarkRow) -> Void)
        let store = resultsStore
        let onInferenceRecord: (@Sendable (InferenceCallRecord) -> Void)? = { [weak self] record in
            store?.saveSingleInferenceProblemResult(runId: runId, record: record)
            Task { @MainActor in
                self?.bumpProblemResultsVersion(runId: runId)
            }
        }
        let task = Task { [runId] in
            let (stream, progressContinuation) = AsyncStream.makeStream(of: (Int, Int).self)
            let consumerTask = Task { @MainActor in
                for await (c, t) in stream {
                    var cur = self.liveProgress[runId] ?? LiveRunProgress(inferenceTotal: t)
                    cur.inferenceCompleted = c
                    cur.inferenceTotal = t
                    self.liveProgress[runId] = cur
                }
            }
            do {
                try await runner.run(progress: { c, t in progressContinuation.yield((c, t)) }, onProblemComplete: onProblemComplete, onInferenceRecord: onInferenceRecord)
                progressContinuation.finish()
                _ = await consumerTask.value
                let updated = await runner.currentState()
                let inferenceRecords = await runner.getInferenceCallRecords()
                await MainActor.run {
                    self.resultsStore?.saveInferenceProblemResults(runId: runId, records: inferenceRecords)
                }
                if evaluateWhenRunCompletes {
                    resultsStore?.saveRun(updated)
                }
                await MainActor.run {
                    loadRuns()
                    if evaluateWhenRunCompletes {
                        liveProgress.removeValue(forKey: runId)
                        currentRunId = runId
                        Task { await self.runEvaluation(runId: runId) }
                    }
                    runningRunTasks.removeValue(forKey: runId)
                    runRunners.removeValue(forKey: runId)
                }
            } catch {
                progressContinuation.finish()
                _ = await consumerTask.value
                await MainActor.run {
                    if !(error is CancellationError) { errorMessage = Self.userFacingMessage(for: error) }
                    loadRuns()
                    liveProgress.removeValue(forKey: runId)
                    runningRunTasks.removeValue(forKey: runId)
                    runRunners.removeValue(forKey: runId)
                }
            }
        }
        runningRunTasks[runId] = task
    }

    /// Returns a short, user-friendly message for inference/network errors (e.g. timeout).
    /// For ProviderError.apiError, parses JSON body and extracts error.message when present (OpenAI/LM Studio shape).
    private static func userFacingMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut {
            return "The request timed out. The model may be slow or overloaded; try again or use a faster model."
        }
        if let providerError = error as? ProviderError, case .apiError(_, let body) = providerError {
            if let parsed = parseAPIErrorMessage(body), !parsed.isEmpty {
                return parsed
            }
            if body.count < 500 {
                return body
            }
            return String(body.prefix(497)) + "…"
        }
        return error.localizedDescription
    }

    /// Extracts error.message from OpenAI/LM Studio-style JSON: {"error": {"message": "..."}}.
    private static func parseAPIErrorMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any],
              let message = errorObj["message"] as? String, !message.isEmpty else { return nil }
        return message
    }

    /// Trims run state and output so inference can resume from startFromIndex (discards results from that index onward).
    public func trimRunToProblem(runId: String, startFromIndex: Int) {
        guard let path = cachedDatasetPath else { return }
        let runsDir = datasetService.appSupportDirectory.appending(path: "runs", directoryHint: .isDirectory)
        let stateURL = runsDir.appending(path: "\(runId)_state.json")
        var stateDecoder = JSONDecoder()
        stateDecoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateURL),
              var state = try? stateDecoder.decode(RunState.self, from: data) else { return }
        let problems: [BenchmarkProblem]
        do {
            problems = try datasetService.loadProblems(from: path, languages: state.languages)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        state.completedIndices = state.completedIndices.filter { $0 < startFromIndex }
        state.status = .paused
        state.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let stateData = try? encoder.encode(state) {
            try? stateData.write(to: stateURL)
        }
        let outputURL = runsDir.appending(path: "\(runId)_output.jsonl")
        var rows: [BenchmarkRow] = problems.map { BenchmarkRow(from: $0, output: nil) }
        if FileManager.default.fileExists(atPath: outputURL.path), let existingData = try? Data(contentsOf: outputURL) {
            let lines = existingData.split(separator: UInt8(ascii: "\n"))
            let decoder = JSONDecoder()
            for (idx, line) in lines.enumerated() where idx < rows.count && idx < startFromIndex {
                if let row = try? decoder.decode(BenchmarkRow.self, from: Data(line)), let out = row.output, !out.isEmpty {
                    rows[idx].output = out
                }
            }
        }
        for i in startFromIndex..<rows.count {
            rows[i].output = nil
        }
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        var lines: [String] = []
        for row in rows {
            if let rowData = try? encoder.encode(row), let s = String(data: rowData, encoding: .utf8) {
                lines.append(s)
            }
        }
        try? lines.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        resultsStore?.deleteRunProblemResultsFromIndex(runId: runId, fromIndex: startFromIndex)
        loadRuns()
    }

    /// Problem count for a run's languages (for resume sheet). Returns nil if dataset path unavailable.
    public func problemCountForRun(_ run: RunState) -> Int? {
        guard let path = cachedDatasetPath else { return nil }
        return (try? datasetService.loadProblems(from: path, languages: run.languages))?.count
    }

    public func resumeRun(_ state: RunState, startFromIndex: Int? = nil) async {
        var stateToUse = state
        if let start = startFromIndex, (state.completedIndices.max() ?? -1) >= start {
            trimRunToProblem(runId: state.runId, startFromIndex: start)
            stateToUse = runs.first { $0.runId == state.runId } ?? state
        }
        guard let providerConfig = providers.first(where: { $0.id == stateToUse.providerId }),
              let path = cachedDatasetPath else { return }
        let problems: [BenchmarkProblem]
        do {
            problems = try datasetService.loadProblems(from: path, languages: stateToUse.languages)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let provider: any InferenceProvider
        switch providerConfig.kind {
        case .anthropic:
            provider = AnthropicProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, modelId: stateToUse.modelId)
        case .lmStudio:
            let base = providerConfig.baseURL ?? "http://127.0.0.1:1234"
            provider = LMStudioProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, baseURL: base, modelId: stateToUse.modelId, modelKind: stateToUse.modelKind)
        default:
            let base = providerConfig.baseURL ?? "http://localhost:1234"
            provider = OpenAIProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, baseURL: base, modelId: stateToUse.modelId)
        }
        var runState = stateToUse
        runState.status = .inProgress
        let runner = InferenceRunner(provider: provider, datasetService: datasetService, runState: runState, problems: problems)
        let runId = stateToUse.runId
        let outputURL: URL = stateToUse.outputPath.map { URL(fileURLWithPath: $0) }
            ?? datasetService.appSupportDirectory.appending(path: "runs", directoryHint: .isDirectory).appending(path: "\(runId)_output.jsonl")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? await runner.loadExistingOutput(from: outputURL)
        }
        var stateToPersist = await runner.currentState()
        stateToPersist.status = .inProgress
        stateToPersist.updatedAt = Date()
        let runsDir = datasetService.appSupportDirectory.appending(path: "runs", directoryHint: .isDirectory)
        let stateURL = runsDir.appending(path: "\(runId)_state.json")
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(stateToPersist) {
            try? data.write(to: stateURL)
        }
        let totalProblems = problems.count
        resultsStore?.saveRun(stateToPersist)
        liveProgress[runId] = LiveRunProgress(inferenceCompleted: stateToPersist.completedIndices.count, inferenceTotal: problems.count)
        bumpProblemResultsVersion(runId: runId)
        loadRuns()

        runRunners[runId] = runner
        let continuation = evaluationQueueContinuation
        let onProblemComplete: (@Sendable (Int, BenchmarkRow) -> Void)? = evaluateWhenRunCompletes ? nil : { [continuation] index, row in
            _ = continuation?.yield(EvaluationQueueItem(runId: runId, problemIndex: index, row: row, totalProblems: totalProblems))
        } as (@Sendable (Int, BenchmarkRow) -> Void)
        let storeResume = resultsStore
        let onInferenceRecordResume: (@Sendable (InferenceCallRecord) -> Void)? = { [weak self] record in
            storeResume?.saveSingleInferenceProblemResult(runId: runId, record: record)
            Task { @MainActor in
                self?.bumpProblemResultsVersion(runId: runId)
            }
        }
        let task = Task { [runId] in
            let (stream, progressContinuation) = AsyncStream.makeStream(of: (Int, Int).self)
            let consumerTask = Task { @MainActor in
                for await (c, t) in stream {
                    var cur = self.liveProgress[runId] ?? LiveRunProgress(inferenceTotal: t)
                    cur.inferenceCompleted = c
                    cur.inferenceTotal = t
                    self.liveProgress[runId] = cur
                }
            }
            do {
                try await runner.run(progress: { c, t in progressContinuation.yield((c, t)) }, onProblemComplete: onProblemComplete, onInferenceRecord: onInferenceRecordResume)
                progressContinuation.finish()
                _ = await consumerTask.value
                let updated = await runner.currentState()
                let inferenceRecords = await runner.getInferenceCallRecords()
                await MainActor.run {
                    self.resultsStore?.saveInferenceProblemResults(runId: runId, records: inferenceRecords)
                }
                if evaluateWhenRunCompletes {
                    resultsStore?.saveRun(updated)
                }
                await MainActor.run {
                    loadRuns()
                    if evaluateWhenRunCompletes {
                        liveProgress.removeValue(forKey: runId)
                        Task { await self.runEvaluation(runId: runId) }
                    }
                    runningRunTasks.removeValue(forKey: runId)
                    runRunners.removeValue(forKey: runId)
                }
            } catch {
                progressContinuation.finish()
                _ = await consumerTask.value
                await MainActor.run {
                    if !(error is CancellationError) { errorMessage = Self.userFacingMessage(for: error) }
                    loadRuns()
                    liveProgress.removeValue(forKey: runId)
                    runningRunTasks.removeValue(forKey: runId)
                    runRunners.removeValue(forKey: runId)
                }
            }
        }
        runningRunTasks[runId] = task
    }

    public func pauseRun(runId: String) {
        if let r = runRunners[runId] { Task { await r.cancel() } }
        runRunners.removeValue(forKey: runId)
        runningRunTasks[runId]?.cancel()
        runningRunTasks.removeValue(forKey: runId)
    }

    /// Deletes a run: cancels any active task, removes from DB and disk, then reloads runs and results.
    public func deleteRun(runId: String) {
        if let r = runRunners[runId] { Task { await r.cancel() } }
        runRunners.removeValue(forKey: runId)
        runningRunTasks[runId]?.cancel()
        runningRunTasks.removeValue(forKey: runId)
        resultsStore?.deleteRun(runId: runId)
        let runsDir = datasetService.appSupportDirectory.appending(path: "runs", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: runsDir.appending(path: "\(runId)_state.json"))
        try? FileManager.default.removeItem(at: runsDir.appending(path: "\(runId)_output.jsonl"))
        loadRuns()
        liveProgress.removeValue(forKey: runId)
        // Refresh results table after a brief delay to allow DB delete to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshResults()
        }
    }

    public func loadRuns() {
        if isPreviewMode { return }
        let dir = datasetService.appSupportDirectory.appending(path: "runs", directoryHint: .isDirectory)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { runs = []; return }
        let stateFiles = contents.filter { $0.lastPathComponent.hasSuffix("_state.json") }
        var loaded: [RunState] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in stateFiles {
            guard let data = try? Data(contentsOf: url),
                  var state = try? decoder.decode(RunState.self, from: data) else { continue }
            if state.status == .inProgress, runningRunTasks[state.runId] == nil {
                state.status = .paused
                state.updatedAt = Date()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let newData = try? encoder.encode(state) {
                    try? newData.write(to: url)
                }
            }
            loaded.append(state)
        }
        runs = loaded.sorted { ($0.updatedAt) > ($1.updatedAt) }
    }

    public func runEvaluation(runId: String) async {
        guard let state = runs.first(where: { $0.runId == runId }),
              state.status == .inferenceComplete,
              let outputPath = state.outputPath else { return }
        let outputURL = URL(fileURLWithPath: outputPath)
        guard FileManager.default.fileExists(atPath: outputPath) else { return }
        let rows: [BenchmarkRow]
        do {
            let data = try Data(contentsOf: outputURL)
            let lines = data.split(separator: UInt8(ascii: "\n"))
            rows = try lines.map { try JSONDecoder().decode(BenchmarkRow.self, from: Data($0)) }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var stateCopy = state
        stateCopy.status = .evaluating
        stateCopy.updatedAt = Date()
        resultsStore?.saveRun(stateCopy)
        loadRuns()
        isRunningEvaluation = true
        currentEvaluatingRunId = runId
        errorMessage = nil
        let (evalStream, evalContinuation) = AsyncStream.makeStream(of: (Int, Int, Int).self)
        let evalConsumerTask = Task { @MainActor in
            for await (c, t, p) in evalStream {
                self.evaluationProgress = (p, t)
                var cur = self.liveProgress[runId] ?? LiveRunProgress(inferenceCompleted: state.completedIndices.count, inferenceTotal: rows.count)
                cur.evaluationPassed = p
                cur.evaluationTotal = t
                self.liveProgress[runId] = cur
            }
            self.evaluationProgress = nil
        }
        do {
            let store = resultsStore
            let (passed, total) = try await evaluationService.evaluateAll(rows: rows) { c, t, p in evalContinuation.yield((c, t, p)) } onRowResult: { [store, runId] index, passed, duration, language in
                store?.saveEvalProblemResult(runId: runId, problemIndex: index, language: language, passed: passed, durationMs: Int(duration * 1000))
                Task { @MainActor in
                    self.bumpProblemResultsVersion(runId: runId)
                }
            }
            evalContinuation.finish()
            _ = await evalConsumerTask.value
            let lang = state.languages.first ?? "all"
            resultsStore?.saveResult(runId: runId, language: lang, total: total, passed: passed)
            var updated = state
            updated.status = .done
            updated.updatedAt = Date()
            resultsStore?.saveRun(updated)
            await MainActor.run {
                evaluationProgress = nil
                currentEvaluatingRunId = nil
                isRunningEvaluation = false
                loadRuns()
                refreshResults()
                liveProgress.removeValue(forKey: runId)
            }
        } catch {
            evalContinuation.finish()
            _ = await evalConsumerTask.value
            await MainActor.run {
                errorMessage = error.localizedDescription
                evaluationProgress = nil
                currentEvaluatingRunId = nil
                isRunningEvaluation = false
                liveProgress.removeValue(forKey: runId)
            }
        }
    }

    public func refreshResults() {
        if isPreviewMode { return }
        resultsTable = resultsStore?.fetchAllResults() ?? []
        timingStats = resultsStore?.fetchRunTimingStats() ?? []
        ensureColorsForResults()
    }

    // MARK: - Model colors (dashboard chart differentiation)

    private static let modelColorPalette: [String] = [
        "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b",
        "#e377c2", "#17becf", "#bcbd22", "#aec7e8", "#ffbb78", "#98df8a",
        "#ff9896", "#c5b0d5", "#c49c94", "#f7b6d2"
    ]

    public func loadModelColors() {
        let url = datasetService.appSupportDirectory.appending(path: "model-colors.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ModelColorAssignment].self, from: data) else {
            modelColors = []
            return
        }
        modelColors = decoded
    }

    private func saveModelColors() {
        let url = datasetService.appSupportDirectory.appending(path: "model-colors.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(modelColors).write(to: url)
    }

    /// Ensures every model variant present in results OR timing stats has a color assignment.
    /// Both sources must be covered because Charts hangs if a foregroundStyle(by:) value
    /// is missing from an explicit chartForegroundStyleScale domain.
    public func ensureColorsForResults() {
        var existingIds = Set(modelColors.map(\.id))
        var added: [ModelColorAssignment] = []
        let palette = Self.modelColorPalette
        var paletteIndex = modelColors.count  // continue palette index from existing assignments

        // Cover models from completed evaluation results (resultsTable)
        for row in resultsTable {
            let q = row.quantization
            let id = ModelColorAssignment.makeId(providerId: row.providerId, modelId: row.modelId, quantization: q)
            guard !existingIds.contains(id) else { continue }
            existingIds.insert(id)
            let displayName = row.modelDisplayName ?? row.modelId
            let colorHex = palette[paletteIndex % palette.count]
            paletteIndex += 1
            added.append(ModelColorAssignment(
                id: id,
                providerId: row.providerId,
                modelId: row.modelId,
                modelDisplayName: displayName,
                quantization: q,
                colorHex: colorHex
            ))
        }

        // Cover models from timing stats (run_problem_results — includes in-progress inference)
        // These appear in performance charts but may not have evaluation results yet.
        for stat in timingStats {
            // timingStats doesn't carry quantization; use providerId + modelId (from runs table model_id)
            // We need to find the matching run to get modelId; stat has providerId and modelDisplayName.
            // Use a synthetic id from providerId + modelDisplayName to avoid gaps.
            let id = "\(stat.providerId)::\(stat.modelDisplayName)"
            guard !existingIds.contains(id) else { continue }
            existingIds.insert(id)
            let colorHex = palette[paletteIndex % palette.count]
            paletteIndex += 1
            added.append(ModelColorAssignment(
                id: id,
                providerId: stat.providerId,
                modelId: stat.modelDisplayName,  // best available from timing stat
                modelDisplayName: stat.modelDisplayName,
                quantization: nil,
                colorHex: colorHex
            ))
        }

        if !added.isEmpty {
            modelColors.append(contentsOf: added)
            saveModelColors()
        }
    }

    /// Returns the assigned color for a model variant, or a default gray if not found.
    public func colorForModel(providerId: String, modelId: String, quantization: String?) -> Color {
        let id = ModelColorAssignment.makeId(providerId: providerId, modelId: modelId, quantization: quantization)
        if let assignment = modelColors.first(where: { $0.id == id }) {
            return Color(hex: assignment.colorHex)
        }
        return Color.gray
    }

    /// Updates the stored color for a model variant and persists.
    public func updateModelColor(id: String, newColor: Color) {
        guard let index = modelColors.firstIndex(where: { $0.id == id }) else { return }
        modelColors[index].colorHex = newColor.hexString
        saveModelColors()
    }

    /// Domain and range for SwiftUI Charts foreground style scale (model display name -> color).
    /// CRITICAL: domain MUST contain every value used in `.foregroundStyle(by:)` across all charts,
    /// AND domain values MUST be unique. Missing or duplicate entries cause Charts to hang.
    public var modelColorScale: (domain: [String], range: [Color]) {
        let palette = Self.modelColorPalette
        // Start from persisted modelColors (deduplicated by display name)
        let sorted = modelColors.sorted { $0.modelDisplayName < $1.modelDisplayName }
        var seen = Set<String>()
        var domain: [String] = []
        var range: [Color] = []
        for entry in sorted {
            guard seen.insert(entry.modelDisplayName).inserted else { continue }
            domain.append(entry.modelDisplayName)
            range.append(Color(hex: entry.colorHex))
        }

        // Safety net: ensure every model name from chart data sources is in the domain.
        // Charts using resultsTable:
        for row in resultsTable {
            let name = row.modelDisplayName ?? row.modelId
            guard seen.insert(name).inserted else { continue }
            domain.append(name)
            range.append(Color(hex: palette[domain.count % palette.count]))
        }
        // Charts using timingStats:
        for stat in timingStats {
            let name = stat.modelDisplayName
            guard seen.insert(name).inserted else { continue }
            domain.append(name)
            range.append(Color(hex: palette[domain.count % palette.count]))
        }

        return (domain: domain, range: range)
    }

    /// Deletes only the evaluation result for a run+language, leaving the run intact for re-evaluation.
    public func deleteResult(runId: String, language: String) {
        resultsStore?.deleteResultAndUpdateRunStatus(runId: runId, language: language) { [weak self] in
            guard let self else { return }
            // Update the JSON state file on disk so loadRuns picks up the new status
            let runsDir = datasetService.appSupportDirectory.appending(path: "runs", directoryHint: .isDirectory)
            let stateURL = runsDir.appending(path: "\(runId)_state.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? Data(contentsOf: stateURL),
               var state = try? decoder.decode(RunState.self, from: data) {
                state.status = .inferenceComplete
                state.updatedAt = Date()
                if let newData = try? encoder.encode(state) {
                    try? newData.write(to: stateURL)
                }
            }
            loadRuns()
            refreshResults()
        }
    }

    public func fetchRunProblemResults(runId: String) -> [ResultsStore.RunProblemResultRow] {
        resultsStore?.fetchRunProblemResults(runId: runId) ?? []
    }

    /// Call after saving inference or eval problem results so RunDetailView refetches.
    public func bumpProblemResultsVersion(runId: String) {
        problemResultsVersion[runId] = (problemResultsVersion[runId] ?? 0) + 1
    }

    public func runSandboxDiagnostics() async {
        isCheckingSandbox = true
        sandboxLastError = nil
        let status = await sandboxDiagnostics.diagnose()
        await MainActor.run {
            sandboxStatus = status
            lastSandboxCheck = status.isHealthy
            isCheckingSandbox = false
        }
    }

    public func fixSandboxAutomatically() async {
        isFixingSandbox = true
        sandboxLastError = nil
        fixSandboxStep = "Checking sandbox…"

        let service = sandboxDiagnostics
        var status = await sandboxDiagnostics.diagnose()
        while !status.isHealthy {
            let result: SandboxDiagnosticsService.CommandResult?
            switch status.kind {
            case .brewMissing:
                fixSandboxStep = "Installing Homebrew…"
                result = await Task.detached(priority: .userInitiated) { service.installHomebrew() }.value
            case .dockerCLIMissing:
                fixSandboxStep = "Installing Colima and Docker…"
                result = await Task.detached(priority: .userInitiated) { service.installDockerStack() }.value
            case .dockerDaemonNotRunning:
                fixSandboxStep = "Starting Colima…"
                result = await Task.detached(priority: .userInitiated) { service.startColima() }.value
            case .imageNotPresent:
                fixSandboxStep = "Pulling sandbox image…"
                let (stream, continuation) = AsyncStream<String>.makeStream()
                let pullTask = Task.detached(priority: .userInitiated) {
                    let r = service.pullImage(progress: { continuation.yield($0) })
                    continuation.finish()
                    return r
                }
                for await line in stream {
                    fixSandboxStep = "Pulling sandbox image… \(line)"
                }
                result = await pullTask.value
            case .containerNotRunning:
                fixSandboxStep = "Starting sandbox container…"
                result = await Task.detached(priority: .userInitiated) { service.startContainer() }.value
            case .sandboxReachable:
                result = nil
            case .unknown:
                fixSandboxStep = "Checking sandbox…"
                status = await sandboxDiagnostics.diagnose()
                continue
            }

            guard let result else { break }
            if result.exitCode != 0 {
                let output = [result.stderr, result.stdout]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    sandboxLastError = output.isEmpty ? "Automatic fix failed." : output
                    isFixingSandbox = false
                    fixSandboxStep = nil
                }
                return
            }

            status = await sandboxDiagnostics.diagnose()
        }

        await MainActor.run {
            sandboxStatus = status
            lastSandboxCheck = status.isHealthy
            isFixingSandbox = false
            fixSandboxStep = nil
        }
    }

    public func sandboxHealthCheck() async -> Bool {
        let ok = await evaluationService.healthCheck()
        lastSandboxCheck = ok
        return ok
    }
}
