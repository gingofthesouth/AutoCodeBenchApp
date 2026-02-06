import SwiftUI

/// List of all runs (active and recent); tap a run to see RunDetailView.
public struct RunsListView: View {
    @Bindable var state: AppState
    @Binding var selectedRunId: String?

    public init(state: AppState, selectedRunId: Binding<String?>) {
        self.state = state
        self._selectedRunId = selectedRunId
    }

    public var body: some View {
        NavigationSplitView {
            List(state.runs, selection: $selectedRunId) { run in
                NavigationLink(value: run.runId) {
                    RunRowView(run: run, progress: state.liveProgress[run.runId])
                }
                .contextMenu {
                    Button("Delete Run", role: .destructive) {
                        state.deleteRun(runId: run.runId)
                        if selectedRunId == run.runId {
                            selectedRunId = nil
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Runs")
            .onAppear {
                state.loadRuns()
                if selectedRunId != nil, !state.runs.contains(where: { $0.runId == selectedRunId }) {
                    selectedRunId = nil
                }
            }
        } detail: {
            if let runId = selectedRunId {
                RunDetailView(runId: runId, state: state) {
                    selectedRunId = nil
                }
            } else {
                ContentUnavailableView("Select a run", systemImage: "play.rectangle")
            }
        }
    }
}

private struct RunRowView: View {
    let run: RunState
    let progress: LiveRunProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.modelId)
                    .font(.headline)
                Spacer()
                statusBadge(run.status)
            }
            Text(run.runId.prefix(8) + "…")
                .font(.caption)
                .foregroundStyle(.secondary)
            if run.modelDisplayName != nil || run.temperature != nil || run.modelKind != nil || run.quantization != nil {
                Text(metadataSummary(run))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let p = progress, p.inferenceTotal > 0 {
                HStack(spacing: 8) {
                    Text("Inference \(p.inferenceCompleted)/\(p.inferenceTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let ep = p.evaluationPassed, let et = p.evaluationTotal, et > 0 {
                        Text("•")
                        Text("Eval \(ep)/\(et)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func metadataSummary(_ run: RunState) -> String {
        var parts: [String] = []
        if let name = run.modelDisplayName, name != run.modelId { parts.append(name) }
        if let t = run.temperature { parts.append("temp \(String(format: "%.2g", t))") }
        if let k = run.modelKind { parts.append(k) }
        if let q = run.quantization { parts.append(q) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusBadge(_ status: RunStatus) -> some View {
        Text(statusLabel(status))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.2))
            .foregroundStyle(statusColor(status))
            .clipShape(Capsule())
    }

    private func statusLabel(_ status: RunStatus) -> String {
        switch status {
        case .inProgress: return "Running"
        case .inferenceComplete: return "Ready to evaluate"
        case .evaluating: return "Evaluating"
        case .done: return "Done"
        case .failed: return "Failed"
        case .paused: return "Paused"
        }
    }

    private func statusColor(_ status: RunStatus) -> Color {
        switch status {
        case .inProgress, .evaluating: return .blue
        case .inferenceComplete: return .orange
        case .done: return .green
        case .failed: return .red
        case .paused: return .secondary
        }
    }
}

#Preview {
    RunsListViewPreviewContainer(empty: true)
}

#Preview("With runs") {
    RunsListViewPreviewContainer(empty: false)
}

private struct RunsListViewPreviewContainer: View {
    let empty: Bool
    @State private var selectedRunId: String? = nil

    var body: some View {
        RunsListView(
            state: empty ? .preview() : .previewWithData(),
            selectedRunId: $selectedRunId
        )
    }
}

#Preview("Run row") {
    RunRowView(
        run: RunState(
            runId: "preview-run-1",
            modelId: "gpt-4o",
            providerId: "preview-provider-1",
            languages: ["python", "swift"],
            status: .inProgress,
            temperature: 0.5,
            modelDisplayName: "GPT-4o"
        ),
        progress: LiveRunProgress(inferenceCompleted: 5, inferenceTotal: 10, evaluationPassed: 3, evaluationTotal: 5)
    )
    .padding()
    .frame(width: 280, alignment: .leading)
}
