import SwiftUI

/// Reusable dataset section (cached path, download button) for use in DatasetView or PrerequisitesView.
public struct DatasetSectionContent: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        if let path = state.cachedDatasetPath {
            LabeledContent("Cached", value: path.lastPathComponent)
            Text(path.path)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No dataset cached.")
                .foregroundStyle(.secondary)
        }
        Button(state.isDownloading ? "Downloading…" : "Download from Hugging Face") {
            Task { await state.downloadDataset() }
        }
        .disabled(state.isDownloading)
    }
}

/// Reusable languages section for use in DatasetView or PrerequisitesView.
public struct LanguagesSectionContent: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        if state.availableLanguages.isEmpty && state.cachedDatasetPath != nil {
            Button("Load languages") {
                state.loadLanguages()
            }
        }
        if !state.availableLanguages.isEmpty {
            ForEach(state.availableLanguages, id: \.self) { lang in
                Toggle(lang, isOn: Binding(
                    get: { state.selectedLanguages.contains(lang) },
                    set: {
                        if $0 { state.selectedLanguages.insert(lang) } else { state.selectedLanguages.remove(lang) }
                        state.saveSelectedLanguages()
                    }
                ))
            }
        }
    }
}

public struct DatasetView: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        Form {
            Section("Dataset") {
                DatasetSectionContent(state: state)
            }
            Section("Languages") {
                LanguagesSectionContent(state: state)
            }
            if let msg = state.errorMessage {
                Section {
                    Text(msg)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dataset")
    }
}

#Preview {
    DatasetView(state: .preview())
}
