import Foundation

/// OpenAI-compatible API (OpenAI, OpenRouter, LMStudio, Ollama with OpenAI compatibility).
public struct OpenAIProvider: InferenceProvider, Sendable {
    public let id: String
    public let name: String
    private let apiKey: String
    private let baseURL: String
    private let modelId: String

    /// Session with long timeouts for inference (model can take minutes per request).
    private static let inferenceSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    public init(id: String, name: String, apiKey: String, baseURL: String, modelId: String) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.modelId = modelId
    }

    /// Ensures base URL has a scheme so URL(string:) succeeds (e.g. "127.0.0.1:9191" → "http://127.0.0.1:9191").
    private static func normalizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "http://localhost:1234" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        return "http://\(trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)"
    }

    public func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        let path = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: path), url.scheme != nil, url.host != nil else {
            throw ProviderError.apiError(statusCode: -1, message: "Invalid base URL for inference. Use e.g. http://127.0.0.1:9191")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": 8192
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.inferenceSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(http.statusCode)"
            throw ProviderError.apiError(statusCode: http.statusCode, message: msg)
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else { throw ProviderError.emptyContent }
        return content
    }
}

private struct OpenAIResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable {
            let content: String?
        }
    }
}
