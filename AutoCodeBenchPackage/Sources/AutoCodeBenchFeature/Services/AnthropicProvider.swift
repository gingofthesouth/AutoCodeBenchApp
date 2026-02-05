import Foundation

/// Anthropic Claude API.
public struct AnthropicProvider: InferenceProvider, Sendable {
    public let id: String
    public let name: String
    private let apiKey: String
    private let modelId: String

    /// Session with long timeouts for inference (model can take minutes per request).
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

    public func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("anthropic-version-2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": modelId,
            "max_tokens": 8192,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.inferenceSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(http.statusCode)"
            throw ProviderError.apiError(statusCode: http.statusCode, message: msg)
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else { throw ProviderError.emptyContent }
        return text
    }
}

private struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}
