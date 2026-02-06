import Foundation

/// Classifies an OpenAI model by which API endpoint it supports (chat completions vs Responses API only vs legacy completions).
public enum OpenAIModelCapability: Sendable {
    /// Supports v1/chat/completions (gpt-4*, gpt-3.5-turbo, o1*, o3*, gpt-5 non-Codex).
    case chat
    /// Supports v1/responses only (e.g. GPT-5.x-Codex); not chat/completions.
    case responsesOnly
    /// Legacy completion-only (v1/completions); not supported by this app.
    case legacyCompletions
}

/// Fetches available models from each inference provider's API.
public struct ModelListingService: Sendable {

    public init() {}

    /// Classifies an OpenAI model ID so callers can choose the correct endpoint or exclude legacy models.
    public static func openAIModelCapability(id: String) -> OpenAIModelCapability {
        let id = id.lowercased()
        // Legacy completion-only: exclude from list and fail fast if selected.
        if id.hasPrefix("text-davinci") || id == "davinci" || id == "babbage" || id == "ada" || id == "curie" {
            return .legacyCompletions
        }
        if id.contains("gpt-3.5-turbo-instruct") {
            return .legacyCompletions
        }
        // Responses API only (e.g. GPT-5.3-Codex, gpt-5.2-codex, codex-mini-latest).
        if (id.hasPrefix("gpt-5") && id.contains("codex")) || id.hasPrefix("codex-") {
            return .responsesOnly
        }
        // Chat-capable: gpt-4*, gpt-3.5-turbo (non-instruct), o1*, o3*, and gpt-5* (non-Codex).
        if id.hasPrefix("gpt-4") { return .chat }
        if id.hasPrefix("o1") || id.hasPrefix("o3") { return .chat }
        if id.hasPrefix("gpt-3.5-turbo") { return .chat }
        if id.hasPrefix("gpt-5") { return .chat }
        return .legacyCompletions
    }

    /// True if the model is supported (chat or responses-only); used for listing.
    public static func isOpenAISupportedModel(id: String) -> Bool {
        switch openAIModelCapability(id: id) {
        case .chat, .responsesOnly: return true
        case .legacyCompletions: return false
        }
    }

    /// List models for the given provider config (uses provider's list endpoint).
    public func listModels(config: ProviderConfig) async throws -> [ProviderModel] {
        switch config.kind {
        case .anthropic:
            return try await listAnthropicModels(providerId: config.id, apiKey: config.apiKey)
        case .openai:
            let base = (config.baseURL?.trimmingCharacters(in: .whitespaces).isEmpty == false)
                ? normalizedBaseURL(config.baseURL!)
                : "https://api.openai.com"
            return try await listOpenAIModels(providerId: config.id, apiKey: config.apiKey, baseURL: base)
        case .openRouter:
            return try await listOpenRouterModels(providerId: config.id, apiKey: config.apiKey)
        case .lmStudio:
            let base = normalizedBaseURL(config.baseURL ?? "http://127.0.0.1:1234")
            return try await listLMStudioModels(providerId: config.id, apiKey: config.apiKey, baseURL: base)
        case .ollama:
            let base = normalizedBaseURL(config.baseURL ?? "http://localhost:11434")
            return try await listOllamaModels(providerId: config.id, baseURL: base)
        case .custom:
            let base = normalizedBaseURL(config.baseURL ?? "http://localhost:1234")
            return try await listOpenAICompatibleModels(providerId: config.id, apiKey: config.apiKey, baseURL: base)
        }
    }

    /// Ensures base URL has a scheme so URLSession accepts it; trims and defaults to http if missing.
    private func normalizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "http://localhost:1234" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        return "http://\(trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)"
    }

    private func modelsURL(fromBase baseURL: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = "\(base)/v1/models"
        guard let url = URL(string: path), url.scheme != nil, url.host != nil else {
            throw ProviderError.apiError(statusCode: -1, message: "Invalid base URL: \(baseURL)")
        }
        return url
    }

    private func listOpenAIModels(providerId: String, apiKey: String, baseURL: String) async throws -> [ProviderModel] {
        let url = try modelsURL(fromBase: baseURL)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: String(data: data, encoding: .utf8) ?? "Failed to list models")
        }
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data
            .filter { Self.isOpenAISupportedModel(id: $0.id) }
            .map { ProviderModel(id: $0.id, displayName: $0.id, providerId: providerId) }
    }

    private func listOpenRouterModels(providerId: String, apiKey: String) async throws -> [ProviderModel] {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: String(data: data, encoding: .utf8) ?? "Failed to list models")
        }
        let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        return decoded.data.map { model in
            let kind: String? = model.id.contains(":thinking") ? "thinking" : nil
            return ProviderModel(id: model.id, displayName: model.name ?? model.id, providerId: providerId, modelKind: kind, quantization: nil)
        }
    }

    private func listOpenAICompatibleModels(providerId: String, apiKey: String, baseURL: String) async throws -> [ProviderModel] {
        let url = try modelsURL(fromBase: baseURL)
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: String(data: data, encoding: .utf8) ?? "Failed to list models")
        }
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data.map { model in
            let kind = Self.inferredModelKind(modelId: model.id, displayName: model.id)
            return ProviderModel(id: model.id, displayName: model.id, providerId: providerId, modelKind: kind, quantization: nil)
        }
    }

    /// Best-effort heuristic: model id or name containing "think" or "r1" suggests thinking/reasoning capability.
    /// OpenRouter uses :thinking suffix (handled in listOpenRouterModels). Hugging Face would require model cards/Hub API for capability hints if added as a provider.
    private static func inferredModelKind(modelId: String, displayName: String) -> String? {
        let lower = (modelId + " " + displayName).lowercased()
        if lower.contains("think") || lower.contains("r1") { return "thinking" }
        return nil
    }

    /// LM Studio native v1 API: GET /api/v1/models returns rich model metadata (display_name, quantization, etc.).
    private func listLMStudioModels(providerId: String, apiKey: String, baseURL: String) async throws -> [ProviderModel] {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = "\(base)/api/v1/models"
        guard let url = URL(string: path), url.scheme != nil, url.host != nil else {
            throw ProviderError.apiError(statusCode: -1, message: "Invalid base URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: String(data: data, encoding: .utf8) ?? "Failed to list LM Studio models")
        }
        let decoded = try JSONDecoder().decode(LMStudioModelsResponse.self, from: data)
        return decoded.models
            .filter { $0.type == "llm" }
            .map { model in
                let displayName: String
                var parts: [String] = [model.displayName]
                if let p = model.paramsString, !p.isEmpty { parts.append(p) }
                if let q = model.quantization?.name, !q.isEmpty { parts.append(q) }
                displayName = parts.joined(separator: " · ")
                let kind = Self.inferredModelKind(modelId: model.key, displayName: model.displayName)
                return ProviderModel(
                    id: model.key,
                    displayName: displayName,
                    providerId: providerId,
                    modelKind: kind,
                    quantization: model.quantization?.name
                )
            }
    }

    /// Ollama GET /api/tags returns { "models": [ { "name", "details": { "parameter_size", "quantization_level" } } ] }.
    private func listOllamaModels(providerId: String, baseURL: String) async throws -> [ProviderModel] {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = "\(base)/api/tags"
        guard let url = URL(string: path), url.scheme != nil, url.host != nil else {
            throw ProviderError.apiError(statusCode: -1, message: "Invalid base URL: \(baseURL)")
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: String(data: data, encoding: .utf8) ?? "Failed to list Ollama models")
        }
        let decoded: OllamaTagsResponse
        do {
            decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        } catch {
            throw ProviderError.apiError(statusCode: http.statusCode, message: "Invalid Ollama response: \(error.localizedDescription)")
        }
        return decoded.models.map { model in
            let displayName: String
            if let param = model.details?.parameterSize, !param.isEmpty {
                displayName = "\(model.name) (\(param))"
            } else {
                displayName = model.name
            }
            let kind = Self.inferredModelKind(modelId: model.name, displayName: model.name)
            return ProviderModel(
                id: model.name,
                displayName: displayName,
                providerId: providerId,
                modelKind: kind,
                quantization: model.details?.quantizationLevel
            )
        }
    }

    /// Anthropic GET /v1/models with pagination (limit, after_id).
    private func listAnthropicModels(providerId: String, apiKey: String) async throws -> [ProviderModel] {
        let base = "https://api.anthropic.com"
        let limit = 100
        let maxPages = 10
        var allModels: [ProviderModel] = []
        var afterId: String? = nil
        var pageCount = 0
        repeat {
            var components = URLComponents(string: "\(base)/v1/models")!
            components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
            if let id = afterId {
                components.queryItems?.append(URLQueryItem(name: "after_id", value: id))
            }
            guard let url = components.url else {
                throw ProviderError.apiError(statusCode: -1, message: "Invalid Anthropic models URL")
            }
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicAPI.version, forHTTPHeaderField: "anthropic-version")
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                print("[AutoCodeBench] Anthropic models request failed (network): \(error)")
                throw error
            }
            guard let http = response as? HTTPURLResponse else {
                print("[AutoCodeBench] Anthropic models invalid response (not HTTP)")
                throw ProviderError.invalidResponse
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<nil>"
                print("[AutoCodeBench] Anthropic models API error: statusCode=\(http.statusCode) body=\(body)")
                throw ProviderError.apiError(statusCode: http.statusCode, message: body.isEmpty ? "Failed to list Anthropic models" : body)
            }
            let decoded: AnthropicModelsResponse
            do {
                decoded = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            } catch {
                let body = String(data: data, encoding: .utf8) ?? "<nil>"
                print("[AutoCodeBench] Anthropic models decode error: \(error). Raw body: \(body)")
                throw ProviderError.apiError(statusCode: http.statusCode, message: "Invalid Anthropic models response: \(error.localizedDescription)")
            }
            let page = decoded.data.map { model in
                ProviderModel(
                    id: model.id,
                    displayName: model.displayName ?? model.id,
                    providerId: providerId
                )
            }
            allModels.append(contentsOf: page)
            afterId = decoded.hasMore ? decoded.lastId : nil
            pageCount += 1
        } while afterId != nil && pageCount < maxPages
        return allModels
    }
}

private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModelInfo]
    let hasMore: Bool
    let lastId: String?
    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastId = "last_id"
    }
}

private struct AnthropicModelInfo: Decodable {
    let id: String
    let displayName: String?
    let type: String?
    enum CodingKeys: String, CodingKey {
        case id, type
        case displayName = "display_name"
    }
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String
    let details: OllamaModelDetails?
}

private struct OllamaModelDetails: Decodable {
    let parameterSize: String?
    let quantizationLevel: String?
    enum CodingKeys: String, CodingKey {
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
    struct OpenAIModel: Decodable {
        let id: String
    }
}

private struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterModel]
    struct OpenRouterModel: Decodable {
        let id: String
        let name: String?
    }
}

private struct LMStudioModelsResponse: Decodable {
    let models: [LMStudioModel]
}

private struct LMStudioModel: Decodable {
    let type: String
    let key: String
    let displayName: String
    let quantization: LMStudioQuantization?
    let paramsString: String?
    let maxContextLength: Int?
    let capabilities: LMStudioCapabilities?
    enum CodingKeys: String, CodingKey {
        case type, key, quantization
        case displayName = "display_name"
        case paramsString = "params_string"
        case maxContextLength = "max_context_length"
        case capabilities
    }
}

private struct LMStudioQuantization: Decodable {
    let name: String?
    let bitsPerWeight: Double?
    enum CodingKeys: String, CodingKey {
        case name
        case bitsPerWeight = "bits_per_weight"
    }
}

private struct LMStudioCapabilities: Decodable {
    let vision: Bool?
    let trainedForToolUse: Bool?
    enum CodingKeys: String, CodingKey {
        case vision
        case trainedForToolUse = "trained_for_tool_use"
    }
}
