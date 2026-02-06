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

private struct AcknowledgmentsView: View {
    private static let citation = """
    @misc{chou2025autocodebenchlargelanguagemodels,
          title={AutoCodeBench: Large Language Models are Automatic Code Benchmark Generators},
          author={Jason Chou and Ao Liu and Yuchi Deng and Zhiying Zeng and Tao Zhang and Haotian Zhu and Jianwei Cai and Yue Mao and Chenchen Zhang and Lingyun Tan and Ziyan Xu and Bohui Zhai and Hengyi Liu and Speed Zhu and Wiggin Zhou and Fengzong Lian},
          year={2025},
          eprint={2508.09101},
          archivePrefix={arXiv},
          primaryClass={cs.CL},
          url={https://arxiv.org/abs/2508.09101},
    }
    """
    private static let arxivURL = URL(string: "https://arxiv.org/abs/2508.09101")!
    private static let githubURL = URL(string: "https://github.com/Tencent-Hunyuan/AutoCodeBenchmark")!
    private static let licenseURL = URL(string: "https://github.com/Tencent-Hunyuan/AutoCodeBenchmark/blob/main/LICENSE")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AutoCodeBench: Large Language Models are Automatic Code Benchmark Generators")
                .font(.caption.bold())
            Text("Jason Chou, Ao Liu, Yuchi Deng et al., 2025")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Link("arXiv:2508.09101", destination: Self.arxivURL)
                .font(.caption)
            Divider()
            HStack(spacing: 8) {
                Link("GitHub", destination: Self.githubURL)
                Link("License", destination: Self.licenseURL)
                Spacer(minLength: 0)
                Button("Copy Citation") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.citation, forType: .string)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct ContentView: View {
    @State private var state = AppState()
    @State private var selectedTab: Tab = .prerequisites
    @State private var selectedRunId: String?
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    enum Tab: String, CaseIterable {
        case dashboard = "Dashboard"
        case models = "Models"
        case prerequisites = "Prerequisites"
        case run = "Run"
        case runs = "Runs"
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
                        tab: .prerequisites,
                        selectedTab: $selectedTab
                    )
                    RequirementRow(
                        met: !state.selectedLanguages.isEmpty,
                        label: "At least one language selected",
                        tab: .prerequisites,
                        selectedTab: $selectedTab
                    )
                    RequirementRow(
                        met: !state.providers.isEmpty,
                        label: "At least one provider",
                        tab: .prerequisites,
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
                        tab: .prerequisites,
                        selectedTab: $selectedTab
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                AcknowledgmentsView()
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            Group {
                switch selectedTab {
                case .dashboard: DashboardView(state: state)
                case .models: ModelsView(state: state)
                case .prerequisites: PrerequisitesView(state: state)
                case .run: RunSetupView(state: state)
                case .runs: RunsListView(state: state, selectedRunId: $selectedRunId)
                case .results: ResultsView(state: state)
                }
            }
            .frame(minWidth: 400, minHeight: 400)
        }
        .onChange(of: state.pendingRunIdToSelect) { _, newValue in
            if let runId = newValue {
                selectedTab = .runs
                selectedRunId = runId
                state.pendingRunIdToSelect = nil
            }
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
        case .dashboard: return "chart.bar"
        case .models: return "cpu"
        case .prerequisites: return "checklist"
        case .run: return "play.circle"
        case .runs: return "list.bullet.rectangle"
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
            Text("To get started: open Prerequisites to add a provider, download the dataset, select languages, and ensure the sandbox is reachable. Then use Run to choose a model and start a run.")
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

#Preview {
    ContentView()
}
