import Charts
import SwiftUI

/// Dashboard: summary stats and charts (pass@1 by model/language/provider, timing, tokens, speed).
public struct DashboardView: View {
    @Bindable var state: AppState
    @State private var providerChartByCategory = true
    @State private var selectedLanguageSortKey: String? = nil
    
    public init(state: AppState) {
        self.state = state
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dashboard")
                    .font(.largeTitle)
                    .bold()
                summaryCards
                
                if !state.resultsTable.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Pass@1")
                            .font(.title2)
                            .bold()
                        passAt1ByModelCard
                        passAt1ByModelLanguageCard
                        passAt1ByProviderCard
                        passAt1OverTimeCard
                        passAt1ByLanguageCard
                    }
                    
                    
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Performance@1")
                                .font(.title2)
                                .bold()
                            runTimingCard
                            tokenEfficiencyCard
                            inferenceSpeedCard
                        }
                } else {
                    Text("No results yet. Complete a run and evaluation to see charts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .onAppear {
            state.refreshResults()
            state.loadRuns()
        }
    }
    
    private var summaryCards: some View {
        GlassEffectContainer(spacing: 16) {
            let runsInProgress = state.runs.filter { $0.status == .inProgress }.count
            let uniqueRuns = Set(state.resultsTable.map(\.runId)).count
            let avgPassAt1 = state.resultsTable.isEmpty ? 0.0 : state.resultsTable.map(\.passAt1).reduce(0, +) / Double(state.resultsTable.count)
            
            HStack(spacing: 16) {
                summaryCard(title: "Total results", value: "\(state.resultsTable.count)", subtitle: "run × language")
                summaryCard(title: "Runs", value: "\(uniqueRuns)", subtitle: "with results")
                summaryCard(title: "Avg pass@1", value: String(format: "%.1f%%", avgPassAt1 * 100), subtitle: "across results")
                summaryCard(title: "In progress", value: "\(runsInProgress)", subtitle: "running now")
            }
        }
    }
    
    private func summaryCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.medium)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }
    
    // MARK: - Pass@1 by Model (vertical histogram)
    private var passAt1ByModelCard: some View {
        let byModel: [String: [Double]] = Dictionary(
            grouping: state.resultsTable,
            by: {
                $0.modelDisplayName ?? $0.modelId
            })
            .mapValues {
                $0.map(\.passAt1)
            }
        
        let series: [(model: String, avg: Double)] = byModel.map {
            (
                model: $0.key,
                avg: $0.value.reduce(0, +) / Double($0.value.count)
            )
        }
            .sorted { $0.avg > $1.avg }
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Pass@1 by model")
                .font(.headline)
            Chart(series, id: \.model) { item in
                BarMark(
                    x: .value("Model", item.model),
                    y: .value("Pass@1 %", item.avg * 100)
                )
                .foregroundStyle(by: .value("Model", item.model))
            }
            .chartForegroundStyleScale(domain: state.modelColorScale.domain, range: state.modelColorScale.range)
            .chartXAxisLabel("Model")
            .chartYAxisLabel("Pass@1 %")
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
        .frame(maxWidth: .infinity, minHeight: 400)
    }
    
    // MARK: - Pass@1 by Model / Language (multi-line per language, sortable by overall or by language)
    private var passAt1ByModelLanguageCard: some View {
        struct LangModelPoint: Identifiable {
            let id: String
            let model: String
            let modelOrder: Int
            let language: String
            let passAt1: Double
        }
        let rows = state.resultsTable
        let modelKey: (ResultsStore.ResultRow) -> String = { $0.modelDisplayName ?? $0.modelId }
        let byModel = Dictionary(grouping: rows, by: modelKey)
        let modelAvg: [String: Double] = byModel.mapValues { rows in
            rows.map(\.passAt1).reduce(0, +) / Double(rows.count)
        }
        let modelLang: [String: [String: Double]] = byModel.mapValues { rows in
            Dictionary(grouping: rows, by: \.language).mapValues { langRows in
                langRows.map(\.passAt1).reduce(0, +) / Double(langRows.count)
            }
        }
        let sortedModels: [String] = if let lang = selectedLanguageSortKey {
            Array(modelLang.keys).sorted {
                (modelLang[$0]?[lang] ?? 0) > (modelLang[$1]?[lang] ?? 0)
            }
        } else {
            Array(modelAvg.keys).sorted { modelAvg[$0]! > modelAvg[$1]! }
        }
        let allLanguages = Set(rows.map(\.language)).sorted()
        let points: [LangModelPoint] = allLanguages.flatMap { lang in
            sortedModels.enumerated().compactMap { idx, model in
                guard let val = modelLang[model]?[lang] else { return nil }
                return LangModelPoint(id: "\(lang)-\(model)", model: model, modelOrder: idx, language: lang, passAt1: val)
            }
        }
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pass@1 by model and language")
                    .font(.headline)
                Spacer()
                Picker("Sort by", selection: $selectedLanguageSortKey) {
                    Text("Overall average").tag(String?.none)
                    ForEach(allLanguages, id: \.self) { lang in
                        Text(lang).tag(Optional(lang))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            if points.isEmpty {
                Text("No data for selected grouping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { pt in
                    LineMark(
                        x: .value("Model", pt.model),
                        y: .value("Pass@1 %", pt.passAt1 * 100)
                    )
                    .foregroundStyle(by: .value("Language", pt.language))
                    .symbol(by: .value("Language", pt.language))
                    PointMark(
                        x: .value("Model", pt.model),
                        y: .value("Pass@1 %", pt.passAt1 * 100)
                    )
                    .foregroundStyle(by: .value("Language", pt.language))
                    .symbol(by: .value("Language", pt.language))
                }
                .chartXAxis {
                    AxisMarks(values: sortedModels) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartXAxisLabel("Model")
                .chartYAxisLabel("Pass@1 %")
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
        .frame(maxWidth: .infinity, minHeight: 400)
    }
    
    // MARK: - Pass@1 by Provider (category or individual)
    private var passAt1ByProviderCard: some View {
        let categoryLabel: (ProviderCategory) -> String = { cat in
            switch cat {
            case .proprietary: return "Proprietary"
            case .openWeight: return "Open-weight"
            case .mixed: return "Mixed"
            }
        }
        let providerCategory: (ResultsStore.ResultRow) -> ProviderCategory = { row in
            guard let provider = state.providers.first(where: { $0.id == row.providerId }) else { return .mixed }
            return provider.kind.category
        }
        let byCategory: [ProviderCategory: [Double]] = Dictionary(grouping: state.resultsTable, by: providerCategory)
            .mapValues { $0.map(\.passAt1) }
        let categorySeries: [(name: String, avg: Double)] = byCategory.map { (name: categoryLabel($0.key), avg: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.name < $1.name }
        
        let byProvider: [String: [Double]] = Dictionary(grouping: state.resultsTable, by: { row in
            guard let p = state.providers.first(where: { $0.id == row.providerId }) else { return "Other" }
            return p.name
        }).mapValues { $0.map(\.passAt1) }
        let providerSeries: [(name: String, avg: Double)] = byProvider.map { (name: $0.key, avg: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.name < $1.name }
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pass@1 by provider")
                    .font(.headline)
                Toggle("By category", isOn: $providerChartByCategory)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Spacer()
                Text(providerChartByCategory ? "Category" : "Provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                if providerChartByCategory {
                    Chart(categorySeries, id: \.name) { item in
                        BarMark(
                            x: .value("Category", item.name),
                            y: .value("Pass@1 %", item.avg * 100)
                        )
                    }
                    .chartXAxisLabel("Category")
                } else {
                    Chart(providerSeries, id: \.name) { item in
                        BarMark(
                            x: .value("Provider", item.name),
                            y: .value("Pass@1 %", item.avg * 100)
                        )
                    }
                    .chartXAxisLabel("Provider")
                }
            }
            .chartYAxisLabel("Pass@1 %")
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }
    
    // MARK: - Pass@1 over time
    private var passAt1OverTimeCard: some View {
        let points: [(date: String, passAt1: Double)] = state.resultsTable
            .map { (date: $0.createdAt.prefix(10).description, passAt1: $0.passAt1) }
        let grouped: [String: [Double]] = Dictionary(grouping: points, by: { $0.date })
            .mapValues { $0.map(\.passAt1) }
        let series: [(date: String, avg: Double)] = grouped.map { (date: $0.key, avg: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.date < $1.date }
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Pass@1 over time")
                .font(.headline)
            Chart(series, id: \.date) { item in
                BarMark(
                    x: .value("Date", item.date),
                    y: .value("Pass@1", item.avg * 100)
                )
            }
            .chartYAxisLabel("Pass@1 %")
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }
    
    // MARK: - Pass@1 by language (existing horizontal)
    private var passAt1ByLanguageCard: some View {
        let byLang: [String: [Double]] = Dictionary(grouping: state.resultsTable, by: { $0.language })
            .mapValues { $0.map(\.passAt1) }
        let series: [(lang: String, avg: Double)] = byLang.map { (lang: $0.key, avg: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.lang < $1.lang }
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Pass@1 by language")
                .font(.headline)
            Chart(series, id: \.lang) { item in
                BarMark(
                    x: .value("Pass@1", item.avg * 100),
                    y: .value("Language", item.lang)
                )
            }
            .chartXAxisLabel("Pass@1 %")
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }
    
    // MARK: - Run timing (time to complete, sorted lowest to highest)
    private var runTimingCard: some View {
        struct TimingPoint: Identifiable {
            let id: String
            let label: String
            let model: String
            let totalSeconds: Double
        }
        let points: [TimingPoint] = state.timingStats.map { stat in
            TimingPoint(
                id: stat.id,
                label: "\(stat.modelDisplayName) · \(stat.language)",
                model: stat.modelDisplayName,
                totalSeconds: Double(stat.totalTimeMs) / 1000
            )
        }
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Time to complete run")
                .font(.headline)
            if points.isEmpty {
                Text("No timing data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { item in
                    BarMark(
                        x: .value("Model · Language", item.label),
                        y: .value("Time (s)", item.totalSeconds)
                    )
                    .foregroundStyle(by: .value("Model", item.model))
                }
                .chartForegroundStyleScale(domain: state.modelColorScale.domain, range: state.modelColorScale.range)
                .chartXAxisLabel("Model · Language")
                .chartYAxisLabel("Time (seconds)")
            }
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }
    
    // MARK: - Token efficiency (tokens per problem by model)
    private var tokenEfficiencyCard: some View {
        let byModel: [String: [Int]] = Dictionary(grouping: state.timingStats, by: { $0.modelDisplayName })
            .mapValues { $0.map(\.tokensPerProblem).filter { $0 > 0 } }
        let series: [(model: String, avgTokens: Double)] = byModel.compactMap { model, values in
            guard !values.isEmpty else { return nil }
            let avg = Double(values.reduce(0, +)) / Double(values.count)
            return (model: model, avgTokens: avg)
        }.sorted { $0.model < $1.model }
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Tokens per problem by model")
                .font(.headline)
            if series.isEmpty {
                Text("No token data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(series, id: \.model) { item in
                    BarMark(
                        x: .value("Model", item.model),
                        y: .value("Tokens", item.avgTokens)
                    )
                    .foregroundStyle(by: .value("Model", item.model))
                }
                .chartForegroundStyleScale(domain: state.modelColorScale.domain, range: state.modelColorScale.range)
                .chartXAxisLabel("Model")
                .chartYAxisLabel("Tokens per problem")
            }
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }
    
    // MARK: - Inference speed (avg ms per problem by model)
    private var inferenceSpeedCard: some View {
        let byModel: [String: [Int]] = Dictionary(grouping: state.timingStats, by: { $0.modelDisplayName })
            .mapValues { $0.map(\.avgInferenceMsPerProblem) }
        let series: [(model: String, avgMs: Double)] = byModel.map { (model: $0.key, avgMs: $0.value.isEmpty ? 0 : Double($0.value.reduce(0, +)) / Double($0.value.count)) }
            .sorted { $0.model < $1.model }
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Inference speed (avg ms per problem)")
                .font(.headline)
            if state.timingStats.isEmpty {
                Text("No timing data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(series, id: \.model) { item in
                    BarMark(
                        x: .value("Model", item.model),
                        y: .value("ms", item.avgMs)
                    )
                    .foregroundStyle(by: .value("Model", item.model))
                }
                .chartForegroundStyleScale(domain: state.modelColorScale.domain, range: state.modelColorScale.range)
                .chartXAxisLabel("Model")
                .chartYAxisLabel("ms per problem")
            }
        }
        .padding(16)
        .glassCardStatic(cornerRadius: 12)
    }
}

#Preview("Empty") {
    DashboardView(state: .preview(empty: true))
}

#Preview("With data") {
    DashboardView(state: .previewWithData())
}
