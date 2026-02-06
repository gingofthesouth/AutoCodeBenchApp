import Foundation

/// Item enqueued for evaluation when using "evaluate as each answer is ready" mode.
public struct EvaluationQueueItem: Sendable {
    public let runId: String
    public let problemIndex: Int
    public let row: BenchmarkRow
    public let totalProblems: Int

    public init(runId: String, problemIndex: Int, row: BenchmarkRow, totalProblems: Int) {
        self.runId = runId
        self.problemIndex = problemIndex
        self.row = row
        self.totalProblems = totalProblems
    }
}
