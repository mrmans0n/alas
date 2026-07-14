import Foundation

/// The app-provided MCP server exposing Alas CLI actions (open files,
/// worktrees, review) to ACP agents. Composed alongside — never inside —
/// `MCPAttachmentPlanner`, so the planner stays a pure function of user
/// configuration and the built-in entry never affects the configuration
/// fingerprint.
enum BuiltInAlasMCP {
    static let serverName = "alas"
    static let statusId = "builtin-alas"

    struct Injection: Equatable {
        let server: ACPMCPServer
        let status: MCPAttachmentServerStatus
    }

    /// The wire entry + status row for the built-in server, or nil when it
    /// must not be injected: globally disabled, the managed binary or app
    /// socket is unavailable, or the project already configures a server
    /// named "alas" (an intentional user override, e.g. a dev binary).
    static func injection(
        enabled: Bool,
        configuredServers: [ProjectMCPServer],
        binaryPath: String?,
        socketPath: String?,
        worktreePath: String
    ) -> Injection? {
        guard enabled, let binaryPath, let socketPath else { return nil }
        let userOverride = configuredServers.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == serverName
        }
        guard !userOverride else { return nil }
        return Injection(
            server: .stdio(
                name: serverName,
                command: binaryPath,
                args: ["mcp"],
                env: [
                    .init(name: "ALAS_SOCKET_PATH", value: socketPath),
                    .init(name: "ALAS_WORKTREE_DIR", value: worktreePath),
                ]
            ),
            status: .init(
                id: statusId,
                name: serverName,
                transport: .stdio,
                disposition: .requested
            )
        )
    }
}
