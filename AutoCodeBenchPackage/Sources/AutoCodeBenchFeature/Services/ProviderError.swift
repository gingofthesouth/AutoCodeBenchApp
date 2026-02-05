import Foundation

public enum ProviderError: Error, Sendable {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case emptyContent
}
