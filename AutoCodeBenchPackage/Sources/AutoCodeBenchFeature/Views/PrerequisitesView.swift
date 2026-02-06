import AppKit
import SwiftUI

public struct PrerequisitesView: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        Form {
            Section("Sandbox") {
                sandboxSectionContent
            }
            Section("Provider") {
                ProvidersSectionContent(state: state)
            }
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
        .navigationTitle("Prerequisites")
        .onAppear {
            if state.sandboxStatus.kind == .unknown {
                Task { await state.runSandboxDiagnostics() }
            }
        }
    }

    @ViewBuilder
    private var sandboxSectionContent: some View {
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

#Preview {
    PrerequisitesView(state: .preview())
}

#Preview("With data") {
    PrerequisitesView(state: .previewWithData())
}
