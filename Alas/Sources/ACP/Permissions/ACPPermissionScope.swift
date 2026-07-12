import Foundation

enum ACPPermissionDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

enum ACPPermissionScopeKind: String, Codable, Equatable, Sendable {
    case session
    case project
}
