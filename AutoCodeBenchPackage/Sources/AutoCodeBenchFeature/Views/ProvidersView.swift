import SwiftUI

public struct ProvidersView: View {
    @Bindable var state: AppState
    @State private var showingAdd = false
    @State private var editingProvider: ProviderConfig?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        Form {
            Section("Inference providers") {
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Providers")
        .sheet(isPresented: $showingAdd) {
            ProviderEditView(config: ProviderConfig(kind: .openai, name: "New"), onSave: { state.addProvider($0); showingAdd = false })
        }
        .sheet(item: $editingProvider) { p in
            ProviderEditView(config: p, onSave: { state.updateProvider($0); editingProvider = nil })
        }
    }
}

struct ProviderEditView: View {
    @State var config: ProviderConfig
    var onSave: (ProviderConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $config.name)
            Picker("Kind", selection: $config.kind) {
                ForEach(ProviderKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            SecureField("API Key", text: $config.apiKey)
            TextField("Base URL (optional)", text: Binding(get: { config.baseURL ?? "" }, set: { config.baseURL = $0.isEmpty ? nil : $0 }))
            Toggle("Default", isOn: $config.isDefault)
            Button("Save") { onSave(config) }
        }
        .formStyle(.grouped)
    }
}

