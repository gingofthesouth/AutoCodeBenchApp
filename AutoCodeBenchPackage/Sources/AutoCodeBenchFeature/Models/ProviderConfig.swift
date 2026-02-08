import Foundation

/// High-level category for comparing open-weight vs proprietary models.
public enum ProviderCategory: String, Codable, Sendable, CaseIterable {
    case proprietary
    case openWeight
    case mixed
}

/// Known inference provider types.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case openRouter
    case lmStudio
    case ollama
    case custom

    /// Category for dashboard breakdown (open-weight vs proprietary).
    public var category: ProviderCategory {
        switch self {
        case .anthropic, .openai: return .proprietary
        case .lmStudio, .ollama: return .openWeight
        case .openRouter, .custom: return .mixed
        }
    }
}

/// Configuration for one inference provider (API key, base URL).
public struct ProviderConfig: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: ProviderKind
    public var name: String
    public var apiKey: String
    public var baseURL: String?
    public var isDefault: Bool

    public init(
        id: String = UUID().uuidString,
        kind: ProviderKind,
        name: String,
        apiKey: String = "",
        baseURL: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.isDefault = isDefault
    }
}

/// Persistent color assignment for a model variant (provider + model + quantization) used in dashboard charts.
public struct ModelColorAssignment: Codable, Sendable, Identifiable {
    public var id: String
    public var providerId: String
    public var modelId: String
    public var modelDisplayName: String
    public var quantization: String?
    public var colorHex: String

    public init(id: String, providerId: String, modelId: String, modelDisplayName: String, quantization: String?, colorHex: String) {
        self.id = id
        self.providerId = providerId
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.quantization = quantization
        self.colorHex = colorHex
    }

    public static func makeId(providerId: String, modelId: String, quantization: String?) -> String {
        var key = "\(providerId)::\(modelId)"
        if let q = quantization, !q.isEmpty { key += "::\(q)" }
        return key
    }
}

/// A model offered by a provider (e.g. claude-sonnet-4, gpt-4o).
public struct ProviderModel: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let providerId: String
    public let modelKind: String?
    public let quantization: String?
    /// When set (e.g. from OpenRouter API metadata), used to pick chat vs responses endpoint instead of ID heuristics.
    public let openAICapability: OpenAIModelCapability?

    public init(id: String, displayName: String, providerId: String, modelKind: String? = nil, quantization: String? = nil, openAICapability: OpenAIModelCapability? = nil) {
        self.id = id
        self.displayName = displayName
        self.providerId = providerId
        self.modelKind = modelKind
        self.quantization = quantization
        self.openAICapability = openAICapability
    }
}
