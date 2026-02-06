import Foundation

/// Anthropic API configuration.
///
/// Update `version` from the official versioning page when Anthropic releases a new API version:
/// https://docs.anthropic.com/en/api/versioning
enum AnthropicAPI {
    /// API version date (YYYY-MM-DD) for the `anthropic-version` header.
    /// Use the latest version listed at https://docs.anthropic.com/en/api/versioning
    static let version = "2023-06-01"
}
