import SwiftUI

/// Lists model variants that have results, grouped by provider, with color pickers and run stats.
public struct ModelsView: View {
    @Bindable var state: AppState
    @State private var selectedAssignmentId: String?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedAssignmentId) {
                ForEach(providerSections, id: \.providerId) { section in
                    Section(section.providerName) {
                        ForEach(section.assignments) { assignment in
                            ModelColorRowView(
                                assignment: assignment,
                                runCount: runCount(for: assignment),
                                bestPassAt1: bestPassAt1(for: assignment),
                                state: state
                            )
                            .tag(assignment.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Models")
            .onAppear {
                state.refreshResults()
            }
        } detail: {
            if let id = selectedAssignmentId,
               let assignment = state.modelColors.first(where: { $0.id == id }) {
                ModelDetailView(assignment: assignment, state: state)
            } else {
                ContentUnavailableView("Select a model", systemImage: "cpu")
            }
        }
    }

    private var providerSections: [(providerId: String, providerName: String, assignments: [ModelColorAssignment])] {
        let byProvider = Dictionary(grouping: state.modelColors, by: { $0.providerId })
        return byProvider.map { providerId, assignments in
            let name = state.providers.first(where: { $0.id == providerId })?.name ?? providerId
            return (providerId: providerId, providerName: name, assignments: assignments.sorted { $0.modelDisplayName < $1.modelDisplayName })
        }.sorted { $0.providerName < $1.providerName }
    }

    private func runCount(for assignment: ModelColorAssignment) -> Int {
        let runIds = Set(state.resultsTable.filter { row in
            ModelColorAssignment.makeId(providerId: row.providerId, modelId: row.modelId, quantization: row.quantization) == assignment.id
        }.map(\.runId))
        return runIds.count
    }

    private func bestPassAt1(for assignment: ModelColorAssignment) -> Double? {
        let rows = state.resultsTable.filter { row in
            ModelColorAssignment.makeId(providerId: row.providerId, modelId: row.modelId, quantization: row.quantization) == assignment.id
        }
        guard !rows.isEmpty else { return nil }
        return rows.map(\.passAt1).max()
    }
}

private struct ModelColorRowView: View {
    let assignment: ModelColorAssignment
    let runCount: Int
    let bestPassAt1: Double?
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            ColorPicker("", selection: Binding(
                get: { Color(hex: assignment.colorHex) },
                set: { state.updateModelColor(id: assignment.id, newColor: $0) }
            ))
            .labelsHidden()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: assignment.colorHex))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(assignment.modelDisplayName)
                    .font(.headline)
                HStack(spacing: 6) {
                    if let q = assignment.quantization, !q.isEmpty {
                        Text(q)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Text("\(runCount) run\(runCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let best = bestPassAt1 {
                        Text(String(format: "%.1f%% best", best * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct ModelDetailView: View {
    let assignment: ModelColorAssignment
    @Bindable var state: AppState

    private var resultRows: [ResultsStore.ResultRow] {
        state.resultsTable.filter { row in
            ModelColorAssignment.makeId(providerId: row.providerId, modelId: row.modelId, quantization: row.quantization) == assignment.id
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var runSummaries: [(runId: String, rows: [ResultsStore.ResultRow], run: RunState?)] {
        var seen = Set<String>()
        return resultRows.compactMap { row -> (String, [ResultsStore.ResultRow], RunState?)? in
            guard seen.insert(row.runId).inserted else { return nil }
            let rows = resultRows.filter { $0.runId == row.runId }
            let run = state.runs.first { $0.runId == row.runId }
            return (row.runId, rows, run)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modelHeaderCard
                runsSection
            }
            .padding(24)
        }
        .navigationTitle(assignment.modelDisplayName)
    }

    private var modelHeaderCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: assignment.colorHex))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(assignment.modelDisplayName)
                    .font(.title2)
                    .bold()
                if let q = assignment.quantization, !q.isEmpty {
                    Text("Quantization: \(q)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .glassCard(cornerRadius: 12)
    }

    @ViewBuilder
    private var runsSection: some View {
        Text("Runs with results")
            .font(.headline)
        if resultRows.isEmpty {
            Text("No results yet for this model.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            runsList
        }
    }

    private var runsList: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(runSummaries, id: \.runId) { summary in
                RunResultSummaryRow(runId: summary.runId, rows: summary.rows, run: summary.run)
            }
        }
    }
}

private struct RunResultSummaryRow: View {
    let runId: String
    let rows: [ResultsStore.ResultRow]
    let run: RunState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(runId.prefix(8) + "…")
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if let run {
                    Text(run.updatedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                ForEach(rows, id: \.id) { row in
                    Text("\(row.language): \(Int(row.passAt1 * 100))%")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 8)
    }
}

#Preview {
    ModelsView(state: .previewWithData())
}
