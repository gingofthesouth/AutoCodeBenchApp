import Foundation

/// Fetches available models from each inference provider's API.
public struct ModelListingService: Sendable {

    public init() {}

    /// List models for the given provider config (uses provider's list endpoint).
    public func listModels(config: ProviderConfig) async throws -> [ProviderModel] {
        switch config.kind {
        case .anthropic:
            return try await listAnthropicModels(providerId: config.id)
        case .openai:
            return try await listOpenAIModels(providerId: config.id, apiKey: config.apiKey, baseURL: "https://api.openai.com")
        case .openRouter:
            return try await listOpenRouterModels(providerId: config.id, apiKey: config.apiKey)
        case .lmStudio, .ollama, .custom:
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
        return decoded.data.map { ProviderModel(id: $0.id, displayName: $0.id, providerId: providerId) }
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
        return decoded.data.map { ProviderModel(id: $0.id, displayName: $0.name ?? $0.id, providerId: providerId) }
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
        return decoded.data.map { ProviderModel(id: $0.id, displayName: $0.id, providerId: providerId) }
    }

    /// Anthropic does not expose a public models list API; use a curated list of known model IDs.
    private func listAnthropicModels(providerId: String) async throws -> [ProviderModel] {
        let ids = [
            "claude-sonnet-4-20250514",
            "claude-3-5-sonnet-20241022",
            "claude-3-5-haiku-20241022",
            "claude-3-opus-20240229",
            "claude-3-sonnet-20240229",
            "claude-3-haiku-20240307",
        ]
        return ids.map { ProviderModel(id: $0, displayName: $0, providerId: providerId) }
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
