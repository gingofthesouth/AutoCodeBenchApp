import Foundation

/// Live progress for a single run (inference and optional evaluation), keyed by runId.
public struct LiveRunProgress: Sendable {
    public var inferenceCompleted: Int
    public var inferenceTotal: Int
    public var evaluationPassed: Int?
    public var evaluationTotal: Int?

    public init(
        inferenceCompleted: Int = 0,
        inferenceTotal: Int = 0,
        evaluationPassed: Int? = nil,
        evaluationTotal: Int? = nil
    ) {
        self.inferenceCompleted = inferenceCompleted
        self.inferenceTotal = inferenceTotal
        self.evaluationPassed = evaluationPassed
        self.evaluationTotal = evaluationTotal
    }
}
