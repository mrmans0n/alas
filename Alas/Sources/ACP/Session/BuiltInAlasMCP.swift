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
        let isDelegated: Bool
    }

    /// An HTTP endpoint for the built-in server. When provided, `injection`
    /// emits an `.http` wire entry (with a bearer auth header) instead of the
    /// default `.stdio` entry.
    struct HTTPEndpoint: Equatable {
        let url: String
        let token: String
    }

    /// The only Workspace data given to the built-in MCP process. Its Codable
    /// shape is intentionally allow-listed: no scripts, server definitions,
    /// resolved environment values, or credentials can enter this payload.
    struct WorkspaceContext: Codable, Equatable, Sendable {
        struct Member: Codable, Equatable, Sendable {
            let id: UUID
            let availability: WorkspaceCheckoutMemberAvailability
        }

        let checkoutID: UUID
        let rootPath: String
        let members: [Member]
    }

    /// Whether the built-in server should be injected at all, independent of
    /// transport. Mirrors the guards in `injection`; used by the HTTP path to
    /// avoid spawning a supervised process for a server that will be suppressed.
    static func shouldInject(enabled: Bool, configuredServers: [ProjectMCPServer],
                             binaryPath: String?, socketPath: String?) -> Bool {
        guard enabled, binaryPath != nil, socketPath != nil else { return false }
        return !configuredServers.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == serverName
        }
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
        worktreePath: String,
        sessionId: String,
        parentSessionId: String? = nil,
        httpEndpoint: HTTPEndpoint? = nil,
        workspaceContext: WorkspaceContext? = nil
    ) -> Injection? {
        guard shouldInject(
            enabled: enabled,
            configuredServers: configuredServers,
            binaryPath: binaryPath,
            socketPath: socketPath
        ), let binaryPath, let socketPath else { return nil }

        let server: ACPMCPServer
        let transport: MCPTransportKind
        if let httpEndpoint {
            server = .http(
                name: serverName,
                url: httpEndpoint.url,
                headers: [.init(name: "Authorization", value: "Bearer \(httpEndpoint.token)")]
            )
            transport = .http
        } else {
            let workspaceEnvironment: [ACPMCPKeyValue]
            if let workspaceContext,
               let data = try? JSONEncoder().encode(workspaceContext),
               let value = String(data: data, encoding: .utf8) {
                workspaceEnvironment = [.init(name: "ALAS_WORKSPACE_CONTEXT", value: value)]
            } else {
                workspaceEnvironment = []
            }
            server = .stdio(
                name: serverName,
                command: binaryPath,
                args: ["mcp"],
                env: [
                    .init(name: "ALAS_SOCKET_PATH", value: socketPath),
                    .init(name: "ALAS_WORKTREE_DIR", value: worktreePath),
                    .init(name: "ALAS_SESSION_ID", value: sessionId),
                ] + (parentSessionId.map { [.init(name: "ALAS_PARENT_SESSION_ID", value: $0)] } ?? [])
                    + workspaceEnvironment
            )
            transport = .stdio
        }

        return Injection(
            server: server,
            status: .init(
                id: statusId,
                name: serverName,
                transport: transport,
                disposition: .requested
            ),
            isDelegated: parentSessionId != nil
        )
    }
}
