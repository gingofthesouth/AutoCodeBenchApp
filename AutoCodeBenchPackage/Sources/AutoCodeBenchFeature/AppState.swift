import Foundation
import Observation

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
    public var inferenceProgress: (completed: Int, total: Int)?
    public var evaluationProgress: (completed: Int, total: Int)?
    public var resultsTable: [ResultsStore.ResultRow] = []
    public var errorMessage: String?
    public var isDownloading = false
    public var isRunningInference = false
    public var isRunningEvaluation = false
    public var availableModels: [ProviderModel] = []
    public var isLoadingModels = false
    public var modelListingError: String?
    public var lastSandboxCheck: Bool?
    public var sandboxStatus = SandboxStatus(kind: .unknown, message: "Not checked yet.")
    public var isCheckingSandbox = false
    public var isFixingSandbox = false
    public var fixSandboxStep: String?
    public var sandboxLastError: String?

    private let datasetService = DatasetDownloadService()
    private let modelListingService = ModelListingService()
    private let sandboxDiagnostics = SandboxDiagnosticsService()
    private var resultsStore: ResultsStore?
    private var inferenceRunner: InferenceRunner?
    private var evaluationService = EvaluationService()

    public init() {
        loadSelectedLanguages()
        loadCachedPath()
        loadProviders()
        resultsStore = ResultsStore(appSupportDirectory: datasetService.appSupportDirectory)
        refreshResults()
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
        var state = RunState(runId: runId, modelId: modelId, providerId: providerId, languages: languages)
        let provider: any InferenceProvider
        switch providerConfig.kind {
        case .anthropic:
            provider = AnthropicProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, modelId: modelId)
        case .openai, .openRouter, .lmStudio, .ollama, .custom:
            let base = providerConfig.baseURL ?? (providerConfig.kind == .openai ? "https://api.openai.com" : "http://localhost:1234")
            provider = OpenAIProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, baseURL: base, modelId: modelId)
        }
        let runner = InferenceRunner(provider: provider, datasetService: datasetService, runState: state, problems: problems)
        inferenceRunner = runner
        isRunningInference = true
        inferenceProgress = (0, problems.count)
        errorMessage = nil
        resultsStore?.saveRun(state)

        let (stream, continuation) = AsyncStream.makeStream(of: (Int, Int).self)
        let consumerTask = Task { @MainActor in
            for await (c, t) in stream {
                self.inferenceProgress = (c, t)
            }
            self.inferenceProgress = nil
        }
        do {
            try await runner.run { c, t in continuation.yield((c, t)) }
            continuation.finish()
            _ = await consumerTask.value
            let updated = await runner.currentState()
            resultsStore?.saveRun(updated)
            await MainActor.run {
                isRunningInference = false
                loadRuns()
                currentRunId = runId
            }
        } catch {
            continuation.finish()
            _ = await consumerTask.value
            await MainActor.run {
                errorMessage = Self.userFacingMessage(for: error)
                inferenceProgress = nil
                isRunningInference = false
                loadRuns()
            }
        }
    }

    /// Returns a short, user-friendly message for inference/network errors (e.g. timeout).
    private static func userFacingMessage(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut {
            return "The request timed out. The model may be slow or overloaded; try again or use a faster model."
        }
        return error.localizedDescription
    }

    public func resumeRun(_ state: RunState) async {
        guard let providerConfig = providers.first(where: { $0.id == state.providerId }),
              let path = cachedDatasetPath else { return }
        let problems: [BenchmarkProblem]
        do {
            problems = try datasetService.loadProblems(from: path, languages: state.languages)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let provider: any InferenceProvider
        switch providerConfig.kind {
        case .anthropic:
            provider = AnthropicProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, modelId: state.modelId)
        default:
            let base = providerConfig.baseURL ?? "http://localhost:1234"
            provider = OpenAIProvider(id: providerConfig.id, name: providerConfig.name, apiKey: providerConfig.apiKey, baseURL: base, modelId: state.modelId)
        }
        var runState = state
        runState.status = .inProgress
        let runner = InferenceRunner(provider: provider, datasetService: datasetService, runState: runState, problems: problems)
        if let outPath = state.outputPath {
            try? await runner.loadExistingOutput(from: URL(fileURLWithPath: outPath))
        }
        inferenceRunner = runner
        isRunningInference = true
        inferenceProgress = (0, problems.count)
        let (stream, continuation) = AsyncStream.makeStream(of: (Int, Int).self)
        let consumerTask = Task { @MainActor in
            for await (c, t) in stream {
                self.inferenceProgress = (c, t)
            }
            self.inferenceProgress = nil
        }
        do {
            try await runner.run { c, t in continuation.yield((c, t)) }
            continuation.finish()
            _ = await consumerTask.value
            let updated = await runner.currentState()
            resultsStore?.saveRun(updated)
            await MainActor.run {
                isRunningInference = false
                loadRuns()
            }
        } catch {
            continuation.finish()
            _ = await consumerTask.value
            await MainActor.run {
                errorMessage = Self.userFacingMessage(for: error)
                inferenceProgress = nil
                isRunningInference = false
                loadRuns()
            }
        }
    }

    public func pauseRun() {
        Task { await inferenceRunner?.cancel() }
    }

    public func loadRuns() {
        let dir = datasetService.appSupportDirectory.appending(path: "runs", directoryHint: .isDirectory)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { runs = []; return }
        let stateFiles = contents.filter { $0.lastPathComponent.hasSuffix("_state.json") }
        var loaded: [RunState] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in stateFiles {
            guard let data = try? Data(contentsOf: url),
                  let state = try? decoder.decode(RunState.self, from: data) else { continue }
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
        isRunningEvaluation = true
        errorMessage = nil
        let (evalStream, evalContinuation) = AsyncStream.makeStream(of: (Int, Int).self)
        let evalConsumerTask = Task { @MainActor in
            for await (c, t) in evalStream {
                self.evaluationProgress = (c, t)
            }
            self.evaluationProgress = nil
        }
        do {
            let (passed, total) = try await evaluationService.evaluateAll(rows: rows) { c, t in evalContinuation.yield((c, t)) }
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
                isRunningEvaluation = false
                loadRuns()
                refreshResults()
            }
        } catch {
            evalContinuation.finish()
            _ = await evalConsumerTask.value
            await MainActor.run {
                errorMessage = error.localizedDescription
                evaluationProgress = nil
                isRunningEvaluation = false
            }
        }
    }

    public func refreshResults() {
        resultsTable = resultsStore?.fetchAllResults() ?? []
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
