import SwiftUI

public struct ResultsView: View {
    @Bindable var state: AppState
    @State private var resultToDelete: (runId: String, language: String)?
    @State private var resultsSortOrder: [KeyPathComparator<ResultsStore.ResultRow>] = []

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Results (model × language)")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                resultsTable
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let msg = state.errorMessage {
                HStack {
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                    Spacer()
                }
                .padding()
                .background(.red.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Results")
        .onAppear {
            state.loadRuns()
            state.refreshResults()
        }
        .alert("Delete Result", isPresented: Binding(
            get: { resultToDelete != nil },
            set: { if !$0 { resultToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                resultToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let result = resultToDelete {
                    state.deleteResult(runId: result.runId, language: result.language)
                    resultToDelete = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete this evaluation result? The run will remain available for re-evaluation.")
        }
    }

    private var resultsTable: some View {
        let sortedResults = state.resultsTable.sorted(using: resultsSortOrder)
        return Table(sortedResults, sortOrder: $resultsSortOrder) {
            TableColumn("Model", value: \.modelId) { row in
                Text(row.modelDisplayName ?? row.modelId)
            }
            .width(min: 100, ideal: 180, max: nil)
            TableColumn("Language", value: \.language) { row in
                Text(row.language)
            }
            .width(min: 80, ideal: 100, max: 200)
            TableColumn("Passed", value: \.passed) { row in
                Text("\(row.passed)/\(row.total)")
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Pass@1", value: \.passAt1) { row in
                Text(String(format: "%.1f%%", row.passAt1 * 100))
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Date", value: \.createdAt) { row in
                Text(row.createdAt.prefix(10))
            }
            .width(min: 80, ideal: 100, max: 140)
            if state.resultsTable.contains(where: { $0.temperature != nil || $0.modelKind != nil || $0.quantization != nil }) {
                TableColumn("Temp") { row in
                    Text(row.temperature.map { String(format: "%.2g", $0) } ?? "—")
                }
                .width(min: 44, ideal: 50, max: 80)
                TableColumn("Type") { row in
                    Text(row.modelKind ?? "—")
                }
                .width(min: 60, ideal: 80, max: 140)
                TableColumn("Quant") { row in
                    Text(row.quantization ?? "—")
                }
                .width(min: 50, ideal: 70, max: 100)
            }
            TableColumn("") { row in
                Button(role: .destructive) {
                    resultToDelete = (row.runId, row.language)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete this result")
            }
            .width(min: 32, ideal: 32, max: 32)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 150)
    }
}

#Preview {
    ResultsView(state: .preview())
}

#Preview("Sandbox healthy") {
    ResultsView(state: .previewWithData())
}
