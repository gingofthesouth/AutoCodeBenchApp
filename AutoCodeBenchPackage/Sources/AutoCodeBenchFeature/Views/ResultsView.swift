import AppKit
import SwiftUI

public struct ResultsView: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        Form {
            Section("Sandbox") {
                let status = state.sandboxStatus
                Label(status.title, systemImage: statusIcon(for: status.kind))
                    .foregroundStyle(statusColor(for: status.kind))
                Text(status.message)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Check again") {
                        Task { await state.runSandboxDiagnostics() }
                    }
                    .disabled(state.isCheckingSandbox || state.isFixingSandbox)

                    Button("Fix it for me") {
                        Task { await state.fixSandboxAutomatically() }
                    }
                    .disabled(state.isCheckingSandbox || state.isFixingSandbox || status.isHealthy)
                }

                if state.isCheckingSandbox || state.isFixingSandbox {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView()
                        if let step = state.fixSandboxStep, !step.isEmpty {
                            Text(step)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                    }
                }

                if let err = state.sandboxLastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !status.isHealthy, let command = status.suggestedCommand {
                    Divider()
                    Text("Manual steps")
                        .font(.headline)
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy command") { copyToPasteboard(command) }
                }
            }
            Section("Evaluate") {
                ForEach(state.runs.filter { $0.status == .inferenceComplete }, id: \.runId) { run in
                    HStack {
                        Text(run.modelId)
                        Text(run.runId.prefix(8) + "…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Run evaluation") {
                            Task { await state.runEvaluation(runId: run.runId) }
                        }
                        .disabled(state.isRunningEvaluation)
                    }
                }
                if state.isRunningEvaluation, let (c, t) = state.evaluationProgress {
                    ProgressView(value: Double(c), total: Double(t)) {
                        Text("Evaluating \(c)/\(t)")
                    }
                }
            }
            Section("Results (model × language)") {
                Table(state.resultsTable) {
                    TableColumn("Model") { row in
                        Text(row.modelId)
                    }
                    .width(min: 100, ideal: 150)
                    TableColumn("Language") { row in
                        Text(row.language)
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Passed") { row in
                        Text("\(row.passed)/\(row.total)")
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("Pass@1") { row in
                        Text(String(format: "%.1f%%", row.passAt1 * 100))
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("Date") { row in
                        Text(row.createdAt.prefix(10))
                    }
                    .width(min: 80, ideal: 100)
                }
                .frame(minHeight: 150)
            }
            if let msg = state.errorMessage {
                Section {
                    Text(msg)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Results")
        .onAppear {
            state.loadRuns()
            state.refreshResults()
            if state.sandboxStatus.kind == .unknown {
                Task { await state.runSandboxDiagnostics() }
            }
        }
    }

    private func statusIcon(for kind: SandboxStatus.Kind) -> String {
        switch kind {
        case .sandboxReachable: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle"
        default: return "xmark.circle.fill"
        }
    }

    private func statusColor(for kind: SandboxStatus.Kind) -> Color {
        switch kind {
        case .sandboxReachable: return .green
        case .unknown: return .secondary
        default: return .red
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
