import SwiftUI

private struct RequirementRow: View {
    let met: Bool
    let label: String
    let tab: ContentView.Tab
    @Binding var selectedTab: ContentView.Tab

    var body: some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(met ? Color.green : Color.red)
                    .font(.body)
                Text(label)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

public struct ContentView: View {
    @State private var state = AppState()
    @State private var selectedTab: Tab = .dataset
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    enum Tab: String, CaseIterable {
        case dataset = "Dataset"
        case providers = "Providers"
        case run = "Run"
        case results = "Results"
    }

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("Navigate") {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Label(tab.rawValue, systemImage: icon(for: tab))
                        }
                        .buttonStyle(.plain)
                        .tag(tab)
                    }
                }
                Section("Requirements") {
                    RequirementRow(
                        met: isDatasetDownloaded,
                        label: "Dataset downloaded",
                        tab: .dataset,
                        selectedTab: $selectedTab
                    )
                    RequirementRow(
                        met: !state.selectedLanguages.isEmpty,
                        label: "At least one language selected",
                        tab: .dataset,
                        selectedTab: $selectedTab
                    )
                    RequirementRow(
                        met: !state.providers.isEmpty,
                        label: "At least one provider",
                        tab: .providers,
                        selectedTab: $selectedTab
                    )
                    RequirementRow(
                        met: state.selectedProviderId != nil,
                        label: "Provider selected",
                        tab: .run,
                        selectedTab: $selectedTab
                    )
                    RequirementRow(
                        met: hasSelectedModelId,
                        label: "Model ID entered",
                        tab: .run,
                        selectedTab: $selectedTab
                    )
                    RequirementRow(
                        met: state.lastSandboxCheck == true,
                        label: "Sandbox reachable (for evaluation)",
                        tab: .results,
                        selectedTab: $selectedTab
                    )
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selectedTab {
                case .dataset: DatasetView(state: state)
                case .providers: ProvidersView(state: state)
                case .run: RunSetupView(state: state)
                case .results: ResultsView(state: state)
                }
            }
            .frame(minWidth: 400, minHeight: 400)
        }
        .navigationTitle(selectedTab.rawValue)
        .onAppear {
            if !hasSeenOnboarding, shouldShowOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet {
                hasSeenOnboarding = true
                showOnboarding = false
            }
        }
    }

    private func icon(for tab: Tab) -> String {
        switch tab {
        case .dataset: return "doc.zipper"
        case .providers: return "server.rack"
        case .run: return "play.circle"
        case .results: return "table"
        }
    }

    private var isDatasetDownloaded: Bool {
        guard let url = state.cachedDatasetPath else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var hasSelectedModelId: Bool {
        guard let id = state.selectedModelId?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !id.isEmpty
    }

    private var shouldShowOnboarding: Bool {
        !isDatasetDownloaded && state.providers.isEmpty
    }
}

private struct OnboardingSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to AutoCodeBench")
                .font(.title2)
            Text("To get started: add an inference provider (Providers), download the dataset (Dataset), and select languages. Then choose a model and start a run (Run).")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Got it") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
