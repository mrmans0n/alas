import Foundation

/// The app-provided MCP server exposing Alas CLI actions (open files,
/// worktrees, review) to ACP agents. Composed alongside — never inside —
/// `MCPAttachmentPlanner`, so the planner stays a pure function of user
/// configuration and the built-in entry never affects the configuration
/// fingerprint.
public enum BuiltInAlasMCP: Sendable {
    public static let serverName = "alas"
    public static let statusId = "builtin-alas"

    public struct Injection: Equatable, Sendable {
        public let server: ACPMCPServer
        public let status: MCPAttachmentServerStatus
        public let isDelegated: Bool
        /// The HTTP server is the process an earlier attach in this app run
        /// already got, not a fresh spawn. See `MCPRegistrationDecision`.
        public let reusesRunningServer: Bool

        public init(server: ACPMCPServer, status: MCPAttachmentServerStatus, isDelegated: Bool, reusesRunningServer: Bool) {
            self.server = server
            self.status = status
            self.isDelegated = isDelegated
            self.reusesRunningServer = reusesRunningServer
        }
    }

    /// An HTTP endpoint for the built-in server. When provided, `injection`
    /// emits an `.http` wire entry (with a bearer auth header) instead of the
    /// default `.stdio` entry.
    public struct HTTPEndpoint: Equatable, Sendable {
        public let url: String
        public let token: String
        /// The supervisor handed back its running process rather than
        /// spawning one.
        public var reused = false

        public init(url: String, token: String, reused: Bool = false) {
            self.url = url
            self.token = token
            self.reused = reused
        }
    }

    /// The only Workspace data given to the built-in MCP process. Its Codable
    /// shape is intentionally allow-listed: no scripts, server definitions,
    /// resolved environment values, or credentials can enter this payload.
    public struct WorkspaceContext: Codable, Equatable, Sendable {
        public struct Member: Codable, Equatable, Sendable {
            public let id: UUID
            public let availability: WorkspaceCheckoutMemberAvailability

            public init(id: UUID, availability: WorkspaceCheckoutMemberAvailability) {
                self.id = id
                self.availability = availability
            }
        }

        public let checkoutID: UUID
        public let rootPath: String
        public let members: [Member]

        public init(checkoutID: UUID, rootPath: String, members: [Member]) {
            self.checkoutID = checkoutID
            self.rootPath = rootPath
            self.members = members
        }
    }

    /// Whether the built-in server should be injected at all, independent of
    /// transport. Mirrors the guards in `injection`; used by the HTTP path to
    /// avoid spawning a supervised process for a server that will be suppressed.
    public static func shouldInject(enabled: Bool, configuredServers: [ProjectMCPServer],
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
    public static func injection(
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
                workspaceEnvironment = [
                    .init(name: "ALAS_WORKSPACE_CONTEXT", value: value),
                    .init(name: "ALAS_MCP_WORKSPACE_ONLY", value: "1"),
                ]
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
            isDelegated: parentSessionId != nil,
            reusesRunningServer: httpEndpoint?.reused == true
        )
    }
}
