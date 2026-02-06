import Foundation

extension AppState {
    /// Returns an AppState suitable for SwiftUI previews. When `empty` is true, state is minimal; when false, equivalent to `previewWithData()`.
    public static func preview(empty: Bool = true) -> AppState {
        let state = AppState()
        state.isPreviewMode = true
        if !empty {
            configurePreviewWithData(state)
        }
        return state
    }

    /// Returns an AppState populated with sample results, runs, and providers for previewing charts and lists.
    public static func previewWithData() -> AppState {
        let state = AppState()
        state.isPreviewMode = true
        configurePreviewWithData(state)
        return state
    }
}

@MainActor
private func configurePreviewWithData(_ state: AppState) {
    let runId = "preview-run-1"
    let providerId = "preview-provider-1"
    let dateStr = ISO8601DateFormatter().string(from: Date())

    state.providers = [
        ProviderConfig(id: providerId, kind: .openai, name: "Preview OpenAI", apiKey: "", isDefault: true),
        ProviderConfig(id: "preview-provider-2", kind: .lmStudio, name: "Preview LM Studio", apiKey: "", baseURL: "http://127.0.0.1:1234", isDefault: false),
    ]
    state.selectedProviderId = providerId
    state.selectedLanguages = ["python", "swift"]
    state.availableLanguages = ["python", "swift", "rust"]
    state.resultsTable = [
        ResultsStore.ResultRow(
            runId: runId,
            modelId: "gpt-4o",
            providerId: providerId,
            language: "python",
            total: 10,
            passed: 7,
            passAt1: 0.7,
            createdAt: dateStr,
            temperature: 0.5,
            modelDisplayName: "GPT-4o",
            modelKind: "instruct",
            quantization: nil
        ),
        ResultsStore.ResultRow(
            runId: runId,
            modelId: "gpt-4o",
            providerId: providerId,
            language: "swift",
            total: 10,
            passed: 6,
            passAt1: 0.6,
            createdAt: dateStr,
            temperature: 0.5,
            modelDisplayName: "GPT-4o",
            modelKind: nil,
            quantization: nil
        ),
    ]
    state.timingStats = [
        ResultsStore.RunTimingStat(
            runId: runId,
            modelDisplayName: "GPT-4o",
            providerId: providerId,
            language: "python",
            totalInferenceMs: 120_000,
            totalEvalMs: 8_000,
            totalInputTokens: 50_000,
            totalOutputTokens: 12_000,
            problemCount: 10
        ),
        ResultsStore.RunTimingStat(
            runId: runId,
            modelDisplayName: "GPT-4o",
            providerId: providerId,
            language: "swift",
            totalInferenceMs: 95_000,
            totalEvalMs: 6_000,
            totalInputTokens: 45_000,
            totalOutputTokens: 10_000,
            problemCount: 10
        ),
    ]
    state.runs = [
        RunState(
            runId: runId,
            modelId: "gpt-4o",
            providerId: providerId,
            languages: ["python", "swift"],
            completedIndices: Set([0, 1, 2, 3, 4]),
            outputPath: nil,
            status: .inProgress,
            createdAt: Date(),
            updatedAt: Date(),
            temperature: 0.5,
            modelDisplayName: "GPT-4o",
            modelKind: "instruct",
            quantization: nil,
            maxOutputTokens: 8192
        ),
        RunState(
            runId: "preview-run-2",
            modelId: "claude-sonnet",
            providerId: providerId,
            languages: ["python"],
            completedIndices: Set(0..<10),
            outputPath: "/tmp/out.jsonl",
            status: .done,
            createdAt: Date().addingTimeInterval(-3600),
            updatedAt: Date(),
            temperature: 0.25,
            modelDisplayName: "Claude Sonnet",
            modelKind: nil,
            quantization: nil,
            maxOutputTokens: nil
        ),
    ]
    state.liveProgress = [
        runId: LiveRunProgress(
            inferenceCompleted: 5,
            inferenceTotal: 10,
            evaluationPassed: 3,
            evaluationTotal: 5
        ),
    ]
    state.sandboxStatus = SandboxStatus(kind: .sandboxReachable, message: "Sandbox reachable.")
    state.lastSandboxCheck = true
    state.modelColors = [
        ModelColorAssignment(id: "\(providerId)::gpt-4o", providerId: providerId, modelId: "gpt-4o", modelDisplayName: "GPT-4o", quantization: nil, colorHex: "#1f77b4"),
        ModelColorAssignment(id: "\(providerId)::claude-sonnet", providerId: providerId, modelId: "claude-sonnet", modelDisplayName: "Claude Sonnet", quantization: nil, colorHex: "#ff7f0e"),
    ]
}
