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
public struct RunState: Codable, Sendable, Identifiable {
    public var id: String { runId }
    public let runId: String
    public let modelId: String
    public let providerId: String
    public let languages: [String]
    public var completedIndices: Set<Int>
    public var outputPath: String?
    public var status: RunStatus
    public let createdAt: Date
    public var updatedAt: Date
    public let temperature: Double?
    public let modelDisplayName: String?
    public let modelKind: String?
    public let quantization: String?
    public let maxOutputTokens: Int?

    public init(
        runId: String,
        modelId: String,
        providerId: String,
        languages: [String],
        completedIndices: Set<Int> = [],
        outputPath: String? = nil,
        status: RunStatus = .inProgress,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        temperature: Double? = nil,
        modelDisplayName: String? = nil,
        modelKind: String? = nil,
        quantization: String? = nil,
        maxOutputTokens: Int? = nil
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
        self.temperature = temperature
        self.modelDisplayName = modelDisplayName
        self.modelKind = modelKind
        self.quantization = quantization
        self.maxOutputTokens = maxOutputTokens
    }
}
