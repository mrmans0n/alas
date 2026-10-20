import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Auto-attached gg MCP server for ACP sessions in gg-gated worktrees.
/// Mirrors `BuiltInAlasMCP`: composed alongside — never inside —
/// `MCPAttachmentPlanner`, so the planner stays a pure function of user
/// configuration. A project-configured server named "git-gud" is an
/// intentional user override and suppresses the auto-attach.
public enum GGMCPInjection: Sendable {
    public static let serverName = "git-gud"
    public static let statusId = "builtin-gg-mcp"

    public struct Injection: Equatable, Sendable {
        public let server: ACPMCPServer
        public let status: MCPAttachmentServerStatus

        public init(server: ACPMCPServer, status: MCPAttachmentServerStatus) {
            self.server = server
            self.status = status
        }
    }

    /// The wire entry + status row for the built-in gg-mcp server, or nil
    /// when it must not be injected: the gg gate did not pass, the gg-mcp
    /// binary is unavailable, or the project already configures a server
    /// named "git-gud" (an intentional user override).
    public static func injection(
        gatePassed: Bool,
        binaryPath: String?,
        configuredServers: [ProjectMCPServer],
        worktreePath: String
    ) -> Injection? {
        guard gatePassed, let binaryPath else { return nil }
        let userOverride = configuredServers.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == serverName
        }
        guard !userOverride else { return nil }
        return Injection(
            server: .stdio(
                name: serverName,
                command: binaryPath,
                args: [],
                env: [.init(name: "GG_REPO_PATH", value: worktreePath)]
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
