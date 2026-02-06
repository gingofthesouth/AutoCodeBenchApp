import Foundation

/// Anthropic Claude API.
public struct AnthropicProvider: InferenceProvider, Sendable {
    public let id: String
    public let name: String
    private let apiKey: String
    private let modelId: String

    /// Session with long timeouts for inference (5 min request, 10 min resource).
    private static let inferenceSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    public init(id: String, name: String, apiKey: String, modelId: String = "claude-sonnet-4-20250514") {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.modelId = modelId
    }

    public func complete(systemPrompt: String, userPrompt: String, temperature: Double? = nil, maxTokens: Int? = nil) async throws -> InferenceResult {
        let start = Date()
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicAPI.version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let maxTokensValue = maxTokens ?? 8192
        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokensValue,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]]
        ]
        if let t = temperature, t >= 0, t <= 1 {
            body["temperature"] = t
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.inferenceSession.data(for: request)
        let duration = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(http.statusCode)"
            throw ProviderError.apiError(statusCode: http.statusCode, message: msg)
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else { throw ProviderError.emptyContent }
        let usage: TokenUsage? = decoded.usage.map { TokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) }
        return InferenceResult(text: text, usage: usage, duration: duration)
    }
}

private struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
    let usage: AnthropicUsage?
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    struct AnthropicUsage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}
