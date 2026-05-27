import Foundation

enum ACPPermissionDecision: String, Codable, Equatable {
    case allow
    case deny
}

enum ACPPermissionScopeKind: String, Codable, Equatable {
    case session
    case project
}
