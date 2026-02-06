import Foundation

/// Token usage for one inference call (when reported by the API).
public struct TokenUsage: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Result of a single inference call: text, optional usage, and wall-clock duration.
public struct InferenceResult: Sendable {
    public let text: String
    public let usage: TokenUsage?
    public let duration: TimeInterval
    public init(text: String, usage: TokenUsage? = nil, duration: TimeInterval = 0) {
        self.text = text
        self.usage = usage
        self.duration = duration
    }
}

/// Protocol for inference backends (Anthropic, OpenAI, LMStudio, etc.).
public protocol InferenceProvider: Sendable {
    var id: String { get }
    var name: String { get }

    /// Send a single prompt and return the model's text response with optional usage and duration.
    /// - Parameters:
    ///   - temperature: Optional sampling temperature (e.g. 0.0–1.0); nil uses provider default.
    ///   - maxTokens: Optional max output tokens; nil uses provider default (e.g. 8192).
    func complete(systemPrompt: String, userPrompt: String, temperature: Double?, maxTokens: Int?) async throws -> InferenceResult
}
