import Foundation

/// Which built-in tools an attachment exposes. SSH sessions only get
/// `visual_show`, relayed back to this Mac by the remote helper.
public enum BuiltInMCPToolScope: Equatable, Sendable {
    case full
    case visualOnly
}

/// What the session manager knows when it asks for the built-in server.
public struct BuiltInMCPAttachmentContext: Sendable {
    public enum Location: Equatable, Sendable {
        case local(adapterSupportsHTTP: Bool)
        /// The fence is the session's confirmed remote authority at attach.
        case ssh(host: String, fence: RemoteSessionFence)
    }

    public let worktreePath: String
    public let sessionId: String
    public let injectionSupport: ACPMCPInjectionSupport
    public let location: Location
    /// Whether the attach that requested the server still owns the session
    /// and, over SSH, the fence it was prepared under.
    public let isCurrent: @MainActor @Sendable () -> Bool
    /// Records genuine agent traffic as proof the agent registered the
    /// server on this attach. Ignored once the attach is no longer current.
    public let noteRegistered: @MainActor @Sendable () -> Void

    public init(
        worktreePath: String,
        sessionId: String,
        injectionSupport: ACPMCPInjectionSupport,
        location: Location,
        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
        noteRegistered: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.worktreePath = worktreePath
        self.sessionId = sessionId
        self.injectionSupport = injectionSupport
        self.location = location
        self.isCurrent = isCurrent
        self.noteRegistered = noteRegistered
    }
}

public enum BuiltInMCPAttachment {
    /// Not requested: disabled, overridden by a configured "alas" server, or
    /// unreachable through this adapter's MCP configuration.
    case omitted
    /// Requested but unavailable; the status row says why.
    case skipped(MCPAttachmentServerStatus)
    case prepared(PreparedBuiltInMCPAttachment)

    /// A local injection needs no resources beyond the agent's own process.
    @MainActor
    public static func local(_ injection: BuiltInAlasMCP.Injection?) -> BuiltInMCPAttachment {
        injection.map { .prepared(PreparedBuiltInMCPAttachment(injection: $0)) } ?? .omitted
    }
}

/// A built-in server entry plus the resources serving it. The session
/// manager invalidates it when the attachment that requested it ends.
@MainActor
public final class PreparedBuiltInMCPAttachment {
    public let injection: BuiltInAlasMCP.Injection
    private var cleanup: (@Sendable () async -> Void)?

    public init(injection: BuiltInAlasMCP.Injection, cleanup: (@Sendable () async -> Void)? = nil) {
        self.injection = injection
        self.cleanup = cleanup
    }

    /// Idempotent. Stops accepting relayed calls before it returns.
    public func invalidate() async {
        guard let cleanup else { return }
        self.cleanup = nil
        await cleanup()
    }
}

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
        public let toolScope: BuiltInMCPToolScope

        public init(server: ACPMCPServer, status: MCPAttachmentServerStatus, isDelegated: Bool, reusesRunningServer: Bool, toolScope: BuiltInMCPToolScope = .full) {
            self.server = server
            self.status = status
            self.isDelegated = isDelegated
            self.reusesRunningServer = reusesRunningServer
            self.toolScope = toolScope
        }
    }

    /// The status row for a built-in server that was requested but cannot be
    /// served, e.g. an SSH host whose helper cannot relay it.
    public static func unavailableStatus(_ reason: String) -> MCPAttachmentServerStatus {
        .init(id: statusId, name: serverName, transport: .stdio,
              disposition: .skipped(.remoteRelayUnavailable(reason)))
    }

    /// The entry for an SSH session: the remote helper's stdio proxy, which
    /// relays `visual_show` back to this Mac. It carries no local command,
    /// socket, credential, or session id; the descriptor names only the
    /// helper binary, its state directory, and the stable remote record.
    public static func remoteVisualInjection(descriptor: RemoteMCPRouteDescriptor) -> Injection {
        Injection(
            server: .stdio(name: serverName, command: descriptor.proxyCommand, args: descriptor.proxyArgs, env: []),
            status: .init(id: statusId, name: serverName, transport: .stdio, disposition: .requested),
            isDelegated: false,
            reusesRunningServer: false,
            toolScope: .visualOnly
        )
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
        return !isOverridden(by: configuredServers)
    }

    /// Whether an SSH session should request the relayed visual tool. An
    /// `.external` adapter (Pi) ignores ACP MCP config, so the relay would
    /// never be reached; its own status reports that limitation.
    public static func injectsRemoteVisual(enabled: Bool, configuredServers: [ProjectMCPServer],
                                           injectionSupport: ACPMCPInjectionSupport) -> Bool {
        guard enabled, injectionSupport == .sessionNew else { return false }
        return !isOverridden(by: configuredServers)
    }

    /// A configured server named "alas" is an intentional user override.
    private static func isOverridden(by configuredServers: [ProjectMCPServer]) -> Bool {
        configuredServers.contains {
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
