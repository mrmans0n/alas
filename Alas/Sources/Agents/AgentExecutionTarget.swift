import Foundation

enum AgentExecutionTarget: Hashable, Sendable {
    case local
    case ssh(host: String)

    static func resolve(worktreePath: URL, remoteHost: String? = nil) -> Self {
        if let host = remoteHost ?? RemoteHostRegistry.shared.host(forPath: worktreePath.path) {
            return .ssh(host: host)
        }
        return .local
    }
}
