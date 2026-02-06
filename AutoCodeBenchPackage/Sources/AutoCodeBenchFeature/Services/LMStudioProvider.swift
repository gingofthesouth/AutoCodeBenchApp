import Foundation

/// LM Studio native v1 API (POST /api/v1/chat). Supports reasoning parameter and rich model list.
public struct LMStudioProvider: InferenceProvider, Sendable {
    public let id: String
    public let name: String
    private let apiKey: String
    private let baseURL: String
    private let modelId: String
    /// Run-level model type: "thinking", "instruct", or nil (default). Maps to LM Studio `reasoning` parameter.
    private let modelKind: String?

    /// Session for local inference (long timeouts for thinking models).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config)
    }()

    public init(id: String, name: String, apiKey: String, baseURL: String, modelId: String, modelKind: String? = nil) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.modelId = modelId
        self.modelKind = modelKind
    }

    private static func normalizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "http://127.0.0.1:1234" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        return "http://\(trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)"
    }

    public func complete(systemPrompt: String, userPrompt: String, temperature: Double? = nil, maxTokens: Int? = nil) async throws -> InferenceResult {
        let start = Date()
        let path = "\(baseURL)/api/v1/chat"
        guard let url = URL(string: path), url.scheme != nil, url.host != nil else {
            throw ProviderError.apiError(statusCode: -1, message: "Invalid LM Studio base URL. Use e.g. http://127.0.0.1:1234")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": modelId,
            "input": userPrompt,
            "stream": false
        ]
        if !systemPrompt.isEmpty {
            body["system_prompt"] = systemPrompt
        }
        if let t = temperature, t >= 0, t <= 1 {
            body["temperature"] = t
        }
        if let m = maxTokens, m > 0 {
            body["max_output_tokens"] = m
        }
        if modelKind?.lowercased() == "thinking" {
            body["reasoning"] = "on"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)
        let duration = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(http.statusCode)"
            throw ProviderError.apiError(statusCode: http.statusCode, message: msg)
        }

        let decoded = try JSONDecoder().decode(LMStudioChatResponse.self, from: data)
        let text = decoded.output
            .filter { $0.type == "message" }
            .compactMap { $0.content }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.emptyContent }
        let usage: TokenUsage? = decoded.stats.map { TokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.totalOutputTokens) }
        return InferenceResult(text: text, usage: usage, duration: duration)
    }
}

private struct LMStudioChatResponse: Decodable {
    let output: [LMStudioOutputItem]
    let stats: LMStudioStats?
}

private struct LMStudioOutputItem: Decodable {
    let type: String
    let content: String?
}

private struct LMStudioStats: Decodable {
    let inputTokens: Int
    let totalOutputTokens: Int
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case totalOutputTokens = "total_output_tokens"
    }
}
