import Foundation

/// Status of a benchmark run.
public enum RunStatus: String, Codable, Sendable {
    case inProgress
    case inferenceComplete
    case evaluating
    case done
    case failed
    case paused
}

/// Persisted state for a single run so we can resume.
public struct RunState: Codable, Sendable {
    public let runId: String
    public let modelId: String
    public let providerId: String
    public let languages: [String]
    public var completedIndices: Set<Int>
    public var outputPath: String?
    public var status: RunStatus
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        runId: String,
        modelId: String,
        providerId: String,
        languages: [String],
        completedIndices: Set<Int> = [],
        outputPath: String? = nil,
        status: RunStatus = .inProgress,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.runId = runId
        self.modelId = modelId
        self.providerId = providerId
        self.languages = languages
        self.completedIndices = completedIndices
        self.outputPath = outputPath
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
