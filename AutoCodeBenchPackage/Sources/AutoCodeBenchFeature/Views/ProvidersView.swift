import SwiftUI

/// Reusable provider list and add/edit sheets for use in ProvidersView or PrerequisitesView.
public struct ProvidersSectionContent: View {
    @Bindable var state: AppState
    @State private var showingAdd = false
    @State private var editingProvider: ProviderConfig?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        ForEach(state.providers) { p in
            HStack {
                VStack(alignment: .leading) {
                    Text(p.name)
                        .font(.headline)
                    Text(p.kind.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.selectedProviderId == p.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("Edit") { editingProvider = p }
                Button("Delete", role: .destructive) { state.deleteProvider(id: p.id) }
            }
            .onTapGesture { state.selectedProviderId = p.id }
        }
        Button("Add provider") { showingAdd = true }
        .sheet(isPresented: $showingAdd) {
            ProviderEditView(config: ProviderConfig(kind: .openai, name: "New"), onSave: { state.addProvider($0); showingAdd = false })
        }
        .sheet(item: $editingProvider) { p in
            ProviderEditView(config: p, onSave: { state.updateProvider($0); editingProvider = nil })
        }
    }
}

public struct ProvidersView: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        Form {
            Section("Inference providers") {
                ProvidersSectionContent(state: state)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Providers")
    }
}

struct ProviderEditView: View {
    @State var config: ProviderConfig
    var onSave: (ProviderConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    private var baseURLHelpText: String {
        switch config.kind {
        case .lmStudio: return "Default: http://127.0.0.1:1234. Use your machine or network IP for remote LM Studio."
        case .ollama: return "Default: http://localhost:11434. Change if Ollama runs elsewhere."
        default: return "Required for OpenRouter/custom. Optional for LM Studio/Ollama."
        }
    }

    var body: some View {
        Form {
            TextField("Name", text: $config.name)
            Picker("Kind", selection: $config.kind) {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    Text(kind == .lmStudio ? "LM Studio" : kind.rawValue).tag(kind)
                }
            }
            .onChange(of: config.kind) { _, newKind in
                if newKind == .lmStudio, config.baseURL == nil || config.baseURL?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    config.baseURL = "http://127.0.0.1:1234"
                }
                if newKind == .ollama, config.baseURL == nil || config.baseURL?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    config.baseURL = "http://localhost:11434"
                }
            }
            SecureField("API Key (optional for LM Studio)", text: $config.apiKey)
            TextField("Base URL (optional)", text: Binding(get: { config.baseURL ?? "" }, set: { config.baseURL = $0.isEmpty ? nil : $0 }))
                .help(baseURLHelpText)
            Toggle("Default", isOn: $config.isDefault)
            Button("Save") { onSave(config) }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    ProvidersView(state: .preview())
}

#Preview("With providers") {
    ProvidersView(state: .previewWithData())
}

#Preview("Provider edit") {
    ProviderEditView(config: ProviderConfig(kind: .openai, name: "Preview"), onSave: { _ in })
}
