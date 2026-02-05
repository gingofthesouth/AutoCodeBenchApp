import SwiftUI

public struct RunSetupView: View {
    @Bindable var state: AppState
    @State private var selectedRunForResume: RunState?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        Form {
            Section("Model") {
                Picker("Provider", selection: Binding(get: { state.selectedProviderId ?? "" }, set: { state.selectedProviderId = $0 })) {
                    Text("Select…").tag("")
                    ForEach(state.providers) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .onChange(of: state.selectedProviderId) { _, _ in
                    Task { await state.fetchAvailableModels() }
                }
                if state.isLoadingModels {
                    ProgressView("Loading models…")
                } else if let pid = state.selectedProviderId {
                    Picker("Model", selection: Binding(get: { state.selectedModelId ?? "" }, set: { state.selectedModelId = $0 })) {
                        Text("Select…").tag("")
                        ForEach(state.availableModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .disabled(state.availableModels.isEmpty)
                }
                if let err = state.modelListingError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Languages") {
                Text("\(state.selectedLanguages.count) selected (see Dataset)")
                    .foregroundStyle(.secondary)
            }
            Section("Run") {
                if state.isRunningInference {
                    if let (c, t) = state.inferenceProgress {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Inference \(c)/\(t) problems")
                                .font(.headline)
                            ProgressView(value: Double(c), total: Double(max(t, 1))) {
                                if c < t {
                                    Text("Processing problem \(c + 1) of \(t)…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .progressViewStyle(.linear)
                        }
                    } else {
                        ProgressView("Starting run…")
                    }
                    Button("Pause") { state.pauseRun() }
                } else {
                    Button("Start run") {
                        Task { await state.startRun() }
                    }
                    .disabled(state.selectedProviderId == nil || state.selectedModelId?.isEmpty == true || state.selectedLanguages.isEmpty)
                }
            }
            Section("Resume") {
                Button("Load runs") { state.loadRuns() }
                ForEach(state.runs.filter { $0.status == .inProgress || $0.status == .paused }, id: \.runId) { run in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(run.modelId)
                            Text("\(run.completedIndices.count) / \(run.languages.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Resume") {
                            selectedRunForResume = run
                        }
                    }
                }
            }
            if let msg = state.errorMessage {
                Section {
                    Text(msg)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Run")
        .onAppear {
            state.loadRuns()
            if state.selectedProviderId != nil && state.availableModels.isEmpty && !state.isLoadingModels {
                Task { await state.fetchAvailableModels() }
            }
        }
        .task(id: selectedRunForResume?.runId) {
            guard let run = selectedRunForResume else { return }
            selectedRunForResume = nil
            await state.resumeRun(run)
        }
    }
}
