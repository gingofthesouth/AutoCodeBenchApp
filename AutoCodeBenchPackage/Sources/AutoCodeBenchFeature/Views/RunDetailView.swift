import SwiftUI

/// Detail view for a single run: identity, status, live inference and evaluation progress.
public struct RunDetailView: View {
    let runId: String
    @Bindable var state: AppState
    var onDeleted: (() -> Void)?

    public init(runId: String, state: AppState, onDeleted: (() -> Void)? = nil) {
        self.runId = runId
        self.state = state
        self.onDeleted = onDeleted
    }

    private var run: RunState? {
        state.runs.first { $0.runId == runId }
    }

    private var progress: LiveRunProgress? {
        state.liveProgress[runId]
    }

    public var body: some View {
        Group {
            if let run {
                Form {
                    // Error banner: stable Section when message present; Dismiss clears it.
                    if let msg = state.errorMessage {
                        Section {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(msg)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                    Button("Dismiss") {
                                        state.errorMessage = nil
                                    }
                                    .buttonStyle(.glass)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section("Run") {
                        LabeledContent("Run ID", value: String(run.runId.prefix(8)) + "…")
                        LabeledContent("Model", value: run.modelDisplayName ?? run.modelId)
                        LabeledContent("Provider", value: run.providerId)
                        LabeledContent("Status", value: statusText(run.status))
                        LabeledContent("Languages", value: run.languages.joined(separator: ", "))
                    }
                    if run.temperature != nil || run.modelKind != nil || run.quantization != nil {
                        Section("Model info") {
                            if let t = run.temperature {
                                LabeledContent("Temperature", value: String(format: "%.2f", t))
                            }
                            if let k = run.modelKind {
                                LabeledContent("Model type", value: k)
                            }
                            if let q = run.quantization {
                                LabeledContent("Quantization", value: q)
                            }
                        }
                    }
                    if run.status == .inProgress, let p = progress, p.inferenceTotal > 0 {
                        Section("Inference") {
                            ProgressView(value: Double(p.inferenceCompleted), total: Double(p.inferenceTotal)) {
                                Text("\(p.inferenceCompleted) / \(p.inferenceTotal) problems")
                            }
                            .progressViewStyle(.linear)
                        }
                    }
                    if run.status == .evaluating || (state.currentEvaluatingRunId == runId && state.isRunningEvaluation) {
                        Section("Evaluation") {
                            let (passed, total): (Int, Int) = if let p = progress, let t = p.evaluationTotal, t > 0 {
                                (p.evaluationPassed ?? 0, t)
                            } else if let (c, t) = state.evaluationProgress {
                                (c, t)
                            } else {
                                (0, 1)
                            }
                            ProgressView(value: Double(passed), total: Double(max(total, 1))) {
                                Text("Passed \(passed) / \(total)")
                            }
                            .progressViewStyle(.linear)
                            if total > 0 {
                                Text("Pass rate: \(String(format: "%.1f", Double(passed) / Double(total) * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if run.status == .inferenceComplete {
                        Section("Actions") {
                            Button("Run evaluation") {
                                Task { await state.runEvaluation(runId: runId) }
                            }
                            .disabled(state.isRunningEvaluation)
                        }
                    }
                    if run.status == .inProgress {
                        Section("Actions") {
                            Button("Pause run") {
                                state.pauseRun(runId: runId)
                            }
                        }
                    }
                    Section {
                        Button("Delete run", role: .destructive) {
                            state.deleteRun(runId: runId)
                            onDeleted?()
                        }
                        .buttonStyle(.glass)
                    }
                    detailSections(run: run)
                }
            } else {
                ContentUnavailableView("Run not found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(run?.modelId ?? "Run")
        .onAppear {
            state.loadRuns()
        }
    }

    @ViewBuilder
    private func detailSections(run: RunState) -> some View {
        let _ = state.problemResultsVersion[runId] ?? 0
        let rows = state.fetchRunProblemResults(runId: runId)
        if !rows.isEmpty {
        let totalInferenceMs = rows.reduce(0) { $0 + $1.inferenceDurationMs }
        let totalInputTokens = rows.compactMap(\.inferenceInputTokens).reduce(0, +)
        let totalOutputTokens = rows.compactMap(\.inferenceOutputTokens).reduce(0, +)
        let totalEvalMs = rows.compactMap(\.evalDurationMs).reduce(0, +)
        Section("Inference summary") {
            LabeledContent("Total time", value: formatSeconds(totalInferenceMs))
            if totalInputTokens > 0 || totalOutputTokens > 0 {
                LabeledContent("Input tokens", value: "\(totalInputTokens)")
                LabeledContent("Output tokens", value: "\(totalOutputTokens)")
            }
        }
        Section("Per-problem inference") {
            Table(rows) {
                TableColumn("#") { r in Text("\(r.problemIndex)").font(.system(.body, design: .monospaced)) }
                TableColumn("Language", value: \.language)
                TableColumn("Duration (s)") { r in Text(formatSeconds(r.inferenceDurationMs)).font(.system(.body, design: .monospaced)) }
                TableColumn("In") { r in Text(r.inferenceInputTokens.map { "\($0)" } ?? "—").font(.system(.body, design: .monospaced)) }
                TableColumn("Out") { r in Text(r.inferenceOutputTokens.map { "\($0)" } ?? "—").font(.system(.body, design: .monospaced)) }
            }
        }
        if rows.contains(where: { $0.evalPassed != nil }) {
            Section("Evaluation summary") {
                LabeledContent("Total eval time", value: formatSeconds(totalEvalMs))
            }
            Section("Per-problem evaluation") {
                Table(rows) {
                    TableColumn("#") { r in Text("\(r.problemIndex)").font(.system(.body, design: .monospaced)) }
                    TableColumn("Language", value: \.language)
                    TableColumn("Passed") { row in
                        if let passed = row.evalPassed {
                            Text(passed ? "Yes" : "No")
                                .foregroundStyle(passed ? Color.green : Color.red)
                        } else { Text("—") }
                    }
                    TableColumn("Duration (s)") { row in
                        Text(row.evalDurationMs.map { formatSeconds($0) } ?? "—")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        }
    }

    /// Formats duration in milliseconds as seconds (e.g. "12.35 s").
    private func formatSeconds(_ ms: Int) -> String {
        String(format: "%.2f s", Double(ms) / 1000)
    }

    private func statusText(_ status: RunStatus) -> String {
        switch status {
        case .inProgress: return "In progress"
        case .inferenceComplete: return "Inference complete"
        case .evaluating: return "Evaluating"
        case .done: return "Done"
        case .failed: return "Failed"
        case .paused: return "Paused"
        }
    }
}

#Preview {
    RunDetailView(runId: "preview-run-1", state: .previewWithData())
}
