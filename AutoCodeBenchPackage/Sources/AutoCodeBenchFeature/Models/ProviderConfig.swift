import Foundation

/// Known inference provider types.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case openRouter
    case lmStudio
    case ollama
    case custom
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

/// A model offered by a provider (e.g. claude-sonnet-4, gpt-4o).
public struct ProviderModel: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let providerId: String

    public init(id: String, displayName: String, providerId: String) {
        self.id = id
        self.displayName = displayName
        self.providerId = providerId
    }
}
