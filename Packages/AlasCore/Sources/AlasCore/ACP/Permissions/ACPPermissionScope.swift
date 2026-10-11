import Foundation

public enum ACPPermissionDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

public enum ACPPermissionScopeKind: String, Codable, Equatable, Sendable {
    case session
    case project
}
