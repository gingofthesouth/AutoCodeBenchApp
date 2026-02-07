import SwiftUI

/// Item for presenting ResumeFromProblemSheet (run + total problem count).
public struct ResumeFromProblemSheetItem: Identifiable {
    public let run: RunState
    public let totalProblems: Int
    public var id: String { run.runId }
    public init(run: RunState, totalProblems: Int) {
        self.run = run
        self.totalProblems = totalProblems
    }
}

/// Sheet to choose which problem index to resume from (default = first missing). Optionally trims and resumes from an earlier index.
public struct ResumeFromProblemSheet: View {
    let run: RunState
    let totalProblems: Int
    let onResume: (Int) -> Void
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    private var defaultIndex: Int {
        (0..<totalProblems).first { !run.completedIndices.contains($0) } ?? 0
    }
    @State private var selectedIndex: Int = 0

    public init(run: RunState, totalProblems: Int, onResume: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
        self.run = run
        self.totalProblems = totalProblems
        self.onResume = onResume
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Resume from problem (0-based index)")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            TextField("Index", value: $selectedIndex, format: .number)
                                .frame(width: 72)
                            Stepper("", value: $selectedIndex, in: 0...max(0, totalProblems - 1))
                                .labelsHidden()
                        }
                        if totalProblems > 0 {
                            Text("Index: \(selectedIndex) of \(totalProblems - 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if totalProblems > 0 {
                    Text("Problems in run: 0 to \(totalProblems - 1). Default is the next problem to run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if selectedIndex < defaultIndex {
                    Section {
                        Text("Results from problem \(selectedIndex) onward will be discarded and re-run.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 300)
            .navigationTitle("Resume run")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                        dismiss()
                    }
                    .buttonStyle(.glass)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resume") {
                        let index = min(max(0, selectedIndex), max(0, totalProblems - 1))
                        onResume(index)
                        onDismiss()
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .onAppear {
            selectedIndex = defaultIndex
        }
    }
}
