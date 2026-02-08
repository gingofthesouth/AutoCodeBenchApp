import Foundation

/// OpenAI-compatible API (OpenAI, OpenRouter, LMStudio, Ollama with OpenAI compatibility).
public struct OpenAIProvider: InferenceProvider, Sendable {
    public let id: String
    public let name: String
    private let apiKey: String
    private let baseURL: String
    private let modelId: String
    private let providerKind: ProviderKind?
    private let preferredCapability: OpenAIModelCapability?

    /// Session for cloud endpoints (5 min request, 10 min resource).
    private static let cloudSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Session for local/thinking models (15 min request, 30 min resource) to allow long thinking time.
    private static let localSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config)
    }()

    private static func session(for baseURL: String) -> URLSession {
        let lower = baseURL.lowercased()
        if lower.contains("localhost") || lower.contains("127.0.0.1") {
            return localSession
        }
        return cloudSession
    }

    public init(id: String, name: String, apiKey: String, baseURL: String, modelId: String, providerKind: ProviderKind? = nil, preferredCapability: OpenAIModelCapability? = nil) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.modelId = modelId
        self.providerKind = providerKind
        self.preferredCapability = preferredCapability
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

    public func complete(systemPrompt: String, userPrompt: String, temperature: Double? = nil, maxTokens: Int? = nil) async throws -> InferenceResult {
        let capability = preferredCapability ?? ModelListingService.openAIModelCapability(id: modelId, providerKind: providerKind)
        switch capability {
        case .legacyCompletions:
            throw ProviderError.apiError(
                statusCode: -1,
                message: "The model \"\(modelId)\" is a legacy completion-only model and is not supported. Choose a chat or Responses API model (e.g. gpt-4o, gpt-3.5-turbo, gpt-5.2-codex) from the model list."
            )
        case .responsesOnly:
            return try await completeViaResponsesAPI(systemPrompt: systemPrompt, userPrompt: userPrompt, temperature: temperature, maxTokens: maxTokens)
        case .chat:
            return try await completeViaChatCompletions(systemPrompt: systemPrompt, userPrompt: userPrompt, temperature: temperature, maxTokens: maxTokens)
        }
    }

    /// v1/responses for GPT-5.x-Codex and other Responses-only models.
    private func completeViaResponsesAPI(systemPrompt: String, userPrompt: String, temperature: Double? = nil, maxTokens: Int? = nil) async throws -> InferenceResult {
        let start = Date()
        let path = "\(baseURL)/v1/responses"
        guard let url = URL(string: path), url.scheme != nil, url.host != nil else {
            throw ProviderError.apiError(statusCode: -1, message: "Invalid base URL for inference. Use e.g. https://api.openai.com")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let maxTokensValue = maxTokens ?? 8192
        // Responses API: instructions = system, input = user message(s).
        var body: [String: Any] = [
            "model": modelId,
            "input": [
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": userPrompt]]]
            ],
            "max_output_tokens": maxTokensValue
        ]
        if !systemPrompt.isEmpty {
            body["instructions"] = systemPrompt
        }
        if let t = temperature, t >= 0, t <= 2 {
            body["temperature"] = t
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = Self.session(for: baseURL)
        let (data, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(http.statusCode)"
            let hint = " If you selected a Codex model, ensure your API key has access to the Responses API."
            throw ProviderError.apiError(statusCode: http.statusCode, message: msg + hint)
        }

        let decoded = try JSONDecoder().decode(OpenAIResponsesAPIResponse.self, from: data)
        let text = decoded.outputText
        guard !text.isEmpty else { throw ProviderError.emptyContent }
        let usage: TokenUsage? = decoded.usage.map { TokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) }
        return InferenceResult(text: text, usage: usage, duration: duration)
    }

    /// v1/chat/completions for gpt-4, gpt-3.5-turbo, o1, o3, gpt-5 non-Codex.
    private func completeViaChatCompletions(systemPrompt: String, userPrompt: String, temperature: Double? = nil, maxTokens: Int? = nil) async throws -> InferenceResult {
        let start = Date()
        let path = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: path), url.scheme != nil, url.host != nil else {
            throw ProviderError.apiError(statusCode: -1, message: "Invalid base URL for inference. Use e.g. http://127.0.0.1:9191")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let maxTokensValue = maxTokens ?? 8192
        var body: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": maxTokensValue
        ]
        if let t = temperature, t >= 0, t <= 2 {
            body["temperature"] = t
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = Self.session(for: baseURL)
        let (data, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(http.statusCode)"
            throw ProviderError.apiError(statusCode: http.statusCode, message: msg)
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else { throw ProviderError.emptyContent }
        let usage: TokenUsage? = decoded.usage.map { TokenUsage(inputTokens: $0.promptTokens, outputTokens: $0.completionTokens) }
        return InferenceResult(text: content, usage: usage, duration: duration)
    }
}

private struct OpenAIResponse: Decodable {
    let choices: [Choice]
    let usage: OpenAIUsage?
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable {
            let content: String?
        }
    }
    struct OpenAIUsage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

/// v1/responses response: output array of items; we aggregate output_text from message items.
private struct OpenAIResponsesAPIResponse: Decodable {
    let output: [ResponsesOutputItem]
    let usage: ResponsesUsage?

    var outputText: String {
        output.compactMap { item in
            guard item.type == "message" else { return nil }
            return item.content?.compactMap { $0.text }.joined() ?? ""
        }.joined()
    }

    struct ResponsesOutputItem: Decodable {
        let type: String
        let content: [ResponsesContentBlock]?
    }

    struct ResponsesContentBlock: Decodable {
        let type: String?
        let text: String?
    }
}

private struct ResponsesUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}
