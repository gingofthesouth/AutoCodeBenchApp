import SwiftUI

/// Item for item-driven sheet presentation.
public struct RunSetupSheetItem: Identifiable {
    public let id = UUID()
    public init() {}
}

/// Create Run sheet: model, languages, options, evaluation, and Start run. Uses Liquid Glass cards.
public struct RunSetupSheet: View {
    @Bindable var state: AppState
    var onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isStarting = false

    public init(state: AppState, onDismiss: @escaping () -> Void) {
        self.state = state
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let msg = state.errorMessage {
                        errorBanner(msg)
                    }
                    GlassEffectContainer(spacing: 12) {
                        modelSection
                        modelInfoSection
                        languagesSection
                        runOptionsSection
                        evaluationSection
                    }
                    startButton
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle("New run")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                        dismiss()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .onAppear {
            state.loadRuns()
            if state.selectedProviderId != nil, state.availableModels.isEmpty, !state.isLoadingModels {
                Task { await state.fetchAvailableModels() }
            }
        }
    }

    // MARK: - Subviews

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(.headline)
            Picker("Provider", selection: Binding(
                get: { state.selectedProviderId ?? "" },
                set: { state.selectedProviderId = $0 }
            )) {
                Text("Select…").tag("")
                ForEach(state.providers) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .onChange(of: state.selectedProviderId) { _, _ in
                Task { await state.fetchAvailableModels() }
            }
            if state.isLoadingModels {
                HStack {
                    ProgressView()
                    Text("Loading models…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if state.selectedProviderId != nil {
                Picker("Model", selection: Binding(
                    get: { state.selectedModelId ?? "" },
                    set: { state.selectedModelId = $0 }
                )) {
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
            if let modelId = state.selectedModelId,
               let model = state.availableModels.first(where: { $0.id == modelId }),
               model.modelKind == "thinking" {
                Text("This model supports extended thinking. Use Model type below to choose Thinking or Instruct.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    @ViewBuilder
    private var modelInfoSection: some View {
        if let modelId = state.selectedModelId,
           let model = state.availableModels.first(where: { $0.id == modelId }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Model info")
                    .font(.headline)
                LabeledContent("Name", value: model.displayName)
                if let kind = model.modelKind, !kind.isEmpty {
                    LabeledContent("Model type", value: kind)
                }
                if let q = model.quantization, !q.isEmpty {
                    LabeledContent("Quantization", value: q)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassCard(cornerRadius: 12)
        }
    }

    private var languagesSection: some View {
        HStack {
            Text("Dataset")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(state.selectedLanguages.count) selected (see Dataset tab)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private var runOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run options")
                .font(.headline)
            HStack {
                Text("Temperature")
                Spacer()
                Picker("Temperature", selection: Binding(
                    get: {
                        guard let t = state.runTemperature else { return "default" }
                        let tags = ["0", "0.25", "0.5", "0.75", "1", "1.5", "2"]
                        return tags.first { abs((Double($0) ?? 0) - t) < 0.01 } ?? "default"
                    },
                    set: {
                        if $0 == "default" {
                            state.runTemperature = nil
                        } else if let d = Double($0) {
                            state.runTemperature = d
                        }
                    }
                )) {
                    Text("Model default").tag("default")
                    Text("0").tag("0")
                    Text("0.25").tag("0.25")
                    Text("0.5").tag("0.5")
                    Text("0.75").tag("0.75")
                    Text("1").tag("1")
                    Text("1.5").tag("1.5")
                    Text("2").tag("2")
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }
            .help("Model default uses the provider’s default. Presets: 0–2.")
            HStack {
                Text("Max output tokens")
                Spacer()
                TextField("8192 or empty for default", text: Binding(
                    get: { state.runMaxOutputTokens.map { String($0) } ?? "" },
                    set: {
                        if $0.isEmpty { state.runMaxOutputTokens = nil; return }
                        if let n = Int($0), n > 0 { state.runMaxOutputTokens = n }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .multilineTextAlignment(.trailing)
            }
            .help("Maximum tokens the model can generate. Leave empty for provider default (e.g. 8192).")
            VStack(alignment: .leading, spacing: 4) {
                Text("Model type")
                    .font(.subheadline)
                Picker("Model type", selection: Binding(
                    get: { state.runModelKind ?? "" },
                    set: { state.runModelKind = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Default").tag("")
                    Text("Thinking").tag("thinking")
                    Text("Instruct").tag("instruct")
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private var evaluationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evaluation")
                .font(.headline)
            Text("When to evaluate")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("When to evaluate", selection: Binding(
                get: { state.evaluateWhenRunCompletes },
                set: { state.setEvaluateWhenRunCompletes($0) }
            )) {
                Text("When run completes").tag(true)
                Text("As each answer is ready").tag(false)
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private var startButton: some View {
        Button {
            Task { await startRun() }
        } label: {
            Text("Start run")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .disabled(
            state.selectedProviderId == nil
            || state.selectedModelId?.isEmpty == true
            || state.selectedLanguages.isEmpty
            || isStarting
        )
    }

    // MARK: - Actions

    private func startRun() async {
        isStarting = true
        await state.startRun()
        isStarting = false
        if state.errorMessage == nil {
            onDismiss()
            dismiss()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
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
        .padding(16)
        .glassCard(cornerRadius: 12)
    }
}

#Preview {
    RunSetupSheet(state: .preview(), onDismiss: {})
}
