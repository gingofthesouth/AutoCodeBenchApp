import Foundation

public struct SandboxStatus: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case unknown
        case brewMissing
        case dockerCLIMissing
        case dockerDaemonNotRunning
        case imageNotPresent
        case containerNotRunning
        case sandboxReachable
    }

    public let kind: Kind
    public let message: String
    public let suggestedCommand: String?

    public init(kind: Kind, message: String, suggestedCommand: String? = nil) {
        self.kind = kind
        self.message = message
        self.suggestedCommand = suggestedCommand
    }

    public var isHealthy: Bool { kind == .sandboxReachable }

    public var title: String {
        switch kind {
        case .unknown: return "Sandbox not checked"
        case .brewMissing: return "Homebrew not installed"
        case .dockerCLIMissing: return "Docker CLI not installed"
        case .dockerDaemonNotRunning: return "Docker daemon not running"
        case .imageNotPresent: return "Sandbox image missing"
        case .containerNotRunning: return "Sandbox container not running"
        case .sandboxReachable: return "Sandbox reachable"
        }
    }
}
