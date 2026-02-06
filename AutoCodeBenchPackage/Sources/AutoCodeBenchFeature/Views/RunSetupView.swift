import SwiftUI

/// Run tab landing: "New run" button (presents RunSetupSheet) and recent runs with Pause/Resume.
public struct RunSetupView: View {
    @Bindable var state: AppState
    @State private var runSetupSheetItem: RunSetupSheetItem?
    @State private var selectedRunForResume: RunState?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                newRunCard
                recentRunsSection
                if let msg = state.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .navigationTitle("Run")
        .onAppear {
            state.loadRuns()
        }
        .sheet(item: $runSetupSheetItem) { _ in
            RunSetupSheet(state: state) {
                runSetupSheetItem = nil
            }
        }
        .task(id: selectedRunForResume?.runId) {
            guard let run = selectedRunForResume else { return }
            selectedRunForResume = nil
            await state.resumeRun(run)
        }
    }

    private var newRunCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a new benchmark run")
                .font(.title2)
            Text("Configure provider, model, and options, then start. You’ll be taken to the run when it starts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("New run") {
                runSetupSheetItem = RunSetupSheetItem()
            }
            .buttonStyle(.glassProminent)
        }
        .padding(20)
        .glassCard(cornerRadius: 16)
    }

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent runs")
                    .font(.headline)
                Spacer()
                Button("Load runs") { state.loadRuns() }
                    .buttonStyle(.glass)
            }
            if state.runs.isEmpty {
                Text("No runs yet. Tap \"New run\" to start.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.runs.prefix(5), id: \.runId) { run in
                    let progress = state.liveProgress[run.runId]
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.modelId)
                            Text(String(run.runId.prefix(8)) + "…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let p = progress, p.inferenceTotal > 0 {
                                ProgressView(value: Double(p.inferenceCompleted), total: Double(p.inferenceTotal)) {
                                    Text("\(p.inferenceCompleted)/\(p.inferenceTotal)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .progressViewStyle(.linear)
                            } else {
                                Text("\(run.completedIndices.count) / \(run.languages.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if run.status == .inProgress {
                            Button("Pause") { state.pauseRun(runId: run.runId) }
                                .buttonStyle(.glass)
                        } else if run.status == .paused {
                            Button("Resume") {
                                selectedRunForResume = run
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(12)
                    .glassCard(cornerRadius: 12)
                }
            }
        }
    }
}

#Preview {
    RunSetupView(state: .preview())
}
