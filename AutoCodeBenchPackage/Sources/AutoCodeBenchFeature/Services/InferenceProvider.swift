import Foundation

/// Protocol for inference backends (Anthropic, OpenAI, LMStudio, etc.).
public protocol InferenceProvider: Sendable {
    var id: String { get }
    var name: String { get }

    /// Send a single prompt and return the model's text response.
    func complete(systemPrompt: String, userPrompt: String) async throws -> String
}
