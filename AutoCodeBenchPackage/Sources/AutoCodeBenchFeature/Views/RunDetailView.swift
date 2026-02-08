import Charts
import SwiftUI

/// Detail view for a single run: identity, status, live inference and evaluation progress.
public struct RunDetailView: View {
    let runId: String
    @Bindable var state: AppState
    var onDeleted: (() -> Void)?
    @State private var resumeSheetItem: ResumeFromProblemSheetItem?

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
                ScrollView {
                    let _ = state.problemResultsVersion[runId] ?? 0
                    let rows = state.fetchRunProblemResults(runId: runId)
                    VStack(alignment: .leading, spacing: 24) {
                        if state.errorMessage != nil {
                            errorBannerSection
                        }
                        runInfoSection(run: run)
                        if run.temperature != nil || run.modelKind != nil || run.quantization != nil {
                            modelInfoSection(run: run)
                        }
                        if run.status == .inProgress, progress?.inferenceTotal ?? 0 > 0 {
                            inferenceProgressSection(run: run)
                        }
                        if run.status == .evaluating || (state.currentEvaluatingRunId == runId && state.isRunningEvaluation) {
                            evaluationProgressSection(run: run)
                        }
                        actionsSection(run: run)
                        if !rows.isEmpty {
                            chartsAndResultsSection(rows: rows, run: run)
                            inferenceSummarySection(rows: rows)
                            inferenceTableSection(rows: rows)
                            if rows.contains(where: { $0.evalPassed != nil }) {
                                evaluationSummarySection(rows: rows)
                                evaluationTableSection(rows: rows)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("Run not found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(run?.modelId ?? "Run")
        .onAppear {
            state.loadRuns()
        }
        .sheet(item: $resumeSheetItem) { item in
            ResumeFromProblemSheet(run: item.run, totalProblems: item.totalProblems, onResume: { idx in
                Task { await state.resumeRun(item.run, startFromIndex: idx) }
            }, onDismiss: { resumeSheetItem = nil })
        }
    }

    // MARK: - Section views

    @ViewBuilder
    private var errorBannerSection: some View {
        if let msg = state.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
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
    }

    private func runInfoSection(run: RunState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run")
                .font(.headline)
            LabeledContent("Run ID", value: String(run.runId.prefix(8)) + "…")
            LabeledContent("Model", value: run.modelDisplayName ?? run.modelId)
            LabeledContent("Provider", value: run.providerId)
            LabeledContent("Status", value: statusText(run.status))
            LabeledContent("Languages", value: run.languages.joined(separator: ", "))
        }
    }

    private func modelInfoSection(run: RunState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model info")
                .font(.headline)
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

    private func inferenceProgressSection(run: RunState) -> some View {
        let p = progress!
        return VStack(alignment: .leading, spacing: 8) {
            Text("Inference")
                .font(.headline)
            ProgressView(value: Double(p.inferenceCompleted), total: Double(p.inferenceTotal)) {
                Text("\(p.inferenceCompleted) / \(p.inferenceTotal) problems")
            }
            .progressViewStyle(.linear)
        }
    }

    private func evaluationProgressSection(run: RunState) -> some View {
        let (passed, total): (Int, Int) = if let p = progress, let t = p.evaluationTotal, t > 0 {
            (p.evaluationPassed ?? 0, t)
        } else if let (c, t) = state.evaluationProgress {
            (c, t)
        } else {
            (0, 1)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Evaluation")
                .font(.headline)
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

    private func actionsSection(run: RunState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.headline)
            if run.status == .paused || run.status == .failed {
                Button("Resume run") {
                    let total = state.problemCountForRun(run) ?? run.completedIndices.count
                    resumeSheetItem = ResumeFromProblemSheetItem(run: run, totalProblems: total)
                }
                .buttonStyle(.glass)
            }
            if run.status == .inferenceComplete {
                Button("Run evaluation") {
                    Task { await state.runEvaluation(runId: runId) }
                }
                .disabled(state.isRunningEvaluation)
                .buttonStyle(.glass)
            }
            if run.status == .inProgress {
                Button("Pause run") {
                    state.pauseRun(runId: runId)
                }
                .buttonStyle(.glass)
            }
            Button("Delete run", role: .destructive) {
                state.deleteRun(runId: runId)
                onDeleted?()
            }
            .buttonStyle(.glass)
        }
    }

    private func chartsAndResultsSection(rows: [ResultsStore.RunProblemResultRow], run: RunState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Progress & results")
                .font(.headline)
            runProgressChart(rows: rows, run: run)
            passRateByLanguageChart(rows: rows)
            avgInferenceTimeByLanguageChart(rows: rows)
            avgEvalTimeByLanguageChart(rows: rows)
            runSummaryStats(rows: rows)
        }
    }

    private func inferenceSummarySection(rows: [ResultsStore.RunProblemResultRow]) -> some View {
        let totalInferenceMs = rows.reduce(0) { $0 + $1.inferenceDurationMs }
        let totalInputTokens = rows.compactMap(\.inferenceInputTokens).reduce(0, +)
        let totalOutputTokens = rows.compactMap(\.inferenceOutputTokens).reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Inference summary")
                .font(.headline)
            LabeledContent("Total time", value: formatSeconds(totalInferenceMs))
            if totalInputTokens > 0 || totalOutputTokens > 0 {
                LabeledContent("Input tokens", value: "\(totalInputTokens)")
                LabeledContent("Output tokens", value: "\(totalOutputTokens)")
            }
        }
    }

    private func inferenceTableSection(rows: [ResultsStore.RunProblemResultRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-problem inference")
                .font(.headline)
            Table(rows) {
                TableColumn("#") { r in Text("\(r.problemIndex)").font(.system(.body, design: .monospaced)) }
                TableColumn("Language", value: \.language)
                TableColumn("Duration (s)") { r in Text(formatSeconds(r.inferenceDurationMs)).font(.system(.body, design: .monospaced)) }
                TableColumn("In") { r in Text(r.inferenceInputTokens.map { "\($0)" } ?? "—").font(.system(.body, design: .monospaced)) }
                TableColumn("Out") { r in Text(r.inferenceOutputTokens.map { "\($0)" } ?? "—").font(.system(.body, design: .monospaced)) }
            }
            .frame(minHeight: 200, maxHeight: 400)
        }
    }

    private func evaluationSummarySection(rows: [ResultsStore.RunProblemResultRow]) -> some View {
        let totalEvalMs = rows.compactMap(\.evalDurationMs).reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Evaluation summary")
                .font(.headline)
            LabeledContent("Total eval time", value: formatSeconds(totalEvalMs))
        }
    }

    private func evaluationTableSection(rows: [ResultsStore.RunProblemResultRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-problem evaluation")
                .font(.headline)
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
            .frame(minHeight: 200, maxHeight: 400)
        }
    }

    // MARK: - Helpers

    /// Formats duration in milliseconds as seconds (e.g. "12.35 s").
    private func formatSeconds(_ ms: Int) -> String {
        String(format: "%.2f s", Double(ms) / 1000)
    }

    // MARK: - Progress & results charts

    private func runProgressChart(rows: [ResultsStore.RunProblemResultRow], run: RunState) -> some View {
        let progress = state.liveProgress[runId]
        let inferenceTotal = progress?.inferenceTotal ?? state.problemCountForRun(run) ?? run.completedIndices.count
        let inferenceCompleted = progress?.inferenceCompleted ?? rows.count
        let inferenceTotalSafe = max(inferenceTotal, 1)
        let evalRows = rows.filter { $0.evalPassed != nil }
        let evalTotal = progress?.evaluationTotal ?? evalRows.count
        let evalPassed = progress?.evaluationPassed ?? evalRows.filter(\.evalPassed!).count
        let evalTotalSafe = max(evalTotal, 1)
        struct ProgressPoint: Identifiable {
            let id: String
            let phase: String
            let percent: Double
        }
        var points: [ProgressPoint] = [
            ProgressPoint(id: "inference", phase: "Inference", percent: Double(inferenceCompleted) / Double(inferenceTotalSafe) * 100)
        ]
        if evalTotal > 0 {
            points.append(ProgressPoint(id: "evaluation", phase: "Evaluation pass rate", percent: Double(evalPassed) / Double(evalTotalSafe) * 100))
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Run progress")
                .font(.headline)
            Chart(points) { item in
                BarMark(
                    x: .value("Phase", item.phase),
                    y: .value("%", item.percent)
                )
            }
            .chartYScale(domain: 0 ... 100)
            .chartYAxisLabel("%")
            .frame(height: 280)
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }

    private func passRateByLanguageChart(rows: [ResultsStore.RunProblemResultRow]) -> some View {
        let byLang: [String: (passed: Int, total: Int)] = Dictionary(grouping: rows.filter { $0.evalPassed != nil }, by: \.language)
            .mapValues { langRows in
                let passed = langRows.filter(\.evalPassed!).count
                return (passed: passed, total: langRows.count)
            }
        let series: [(language: String, passRate: Double)] = byLang
            .map { (language: $0.key, passRate: $0.value.total > 0 ? Double($0.value.passed) / Double($0.value.total) * 100 : 0) }
            .sorted { $0.passRate > $1.passRate }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Pass rate by language")
                .font(.headline)
            if series.isEmpty {
                Text("No evaluation results yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(series, id: \.language) { item in
                    BarMark(
                        x: .value("Language", item.language),
                        y: .value("Pass rate %", item.passRate)
                    )
                }
                .chartYScale(domain: 0 ... 100)
                .chartYAxisLabel("Pass rate %")
                .frame(height: 280)
            }
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }

    private func avgInferenceTimeByLanguageChart(rows: [ResultsStore.RunProblemResultRow]) -> some View {
        let byLang: [String: [Int]] = Dictionary(grouping: rows, by: \.language)
            .mapValues { $0.map(\.inferenceDurationMs) }
        let series: [(language: String, avgSeconds: Double)] = byLang
            .map { (language: $0.key, avgSeconds: $0.value.isEmpty ? 0 : Double($0.value.reduce(0, +)) / Double($0.value.count) / 1000) }
            .sorted { $0.avgSeconds < $1.avgSeconds }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Avg inference time per problem by language")
                .font(.headline)
            if series.isEmpty {
                Text("No data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(series, id: \.language) { item in
                    BarMark(
                        x: .value("Language", item.language),
                        y: .value("Seconds", item.avgSeconds)
                    )
                }
                .chartYAxisLabel("Seconds")
                .frame(height: 280)
            }
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }

    private func avgEvalTimeByLanguageChart(rows: [ResultsStore.RunProblemResultRow]) -> some View {
        let byLang: [String: [Int]] = Dictionary(grouping: rows.filter { $0.evalDurationMs != nil }, by: \.language)
            .mapValues { $0.compactMap(\.evalDurationMs) }
        let series: [(language: String, avgSeconds: Double)] = byLang
            .compactMap { language, msValues in
                guard !msValues.isEmpty else { return nil }
                return (language: language, avgSeconds: Double(msValues.reduce(0, +)) / Double(msValues.count) / 1000)
            }
            .sorted { $0.avgSeconds < $1.avgSeconds }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Avg evaluation time per problem by language")
                .font(.headline)
            if series.isEmpty {
                Text("No evaluation timing yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(series, id: \.language) { item in
                    BarMark(
                        x: .value("Language", item.language),
                        y: .value("Seconds", item.avgSeconds)
                    )
                }
                .chartYAxisLabel("Seconds")
                .frame(height: 280)
            }
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }

    private func runSummaryStats(rows: [ResultsStore.RunProblemResultRow]) -> some View {
        let evaluated = rows.filter { $0.evalPassed != nil }
        let passed = evaluated.filter(\.evalPassed!).count
        let failed = evaluated.count - passed
        let totalInferenceMs = rows.reduce(0) { $0 + $1.inferenceDurationMs }
        let throughputPerMin: Double? = totalInferenceMs > 0 ? Double(rows.count) / (Double(totalInferenceMs) / 60_000) : nil
        return VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.headline)
            if !evaluated.isEmpty {
                HStack(spacing: 16) {
                    Text("Passed: \(passed)")
                        .font(.subheadline)
                    Text("Failed: \(failed)")
                        .font(.subheadline)
                }
            }
            if let rate = throughputPerMin, rate > 0 {
                Text("Throughput: \(String(format: "%.1f", rate)) problems/min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
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
