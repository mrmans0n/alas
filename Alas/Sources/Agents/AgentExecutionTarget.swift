import Foundation

enum AgentExecutionTarget: Hashable, Sendable {
    case local
    case ssh(host: String)

    static func resolve(worktreePath: URL, remoteHost: String? = nil) -> Self {
        resolve(
            worktreePath: worktreePath,
            pinnedTarget: remoteHost.map { .ssh(host: $0) }
        )
    }

    static func resolve(worktreePath: URL, pinnedTarget: Self?) -> Self {
        if let pinnedTarget {
            return pinnedTarget
        }
        if let host = RemoteHostRegistry.shared.host(forPath: worktreePath.path) {
            return .ssh(host: host)
        }
        return .local
    }
}

extension ExecutionLocation {
    var agentExecutionTarget: AgentExecutionTarget {
        switch normalized {
        case .local:
            .local
        case .ssh(let host):
            .ssh(host: host)
        }
    }
}
