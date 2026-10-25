import CryptoKit
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Which built-in tools an attachment exposes. SSH sessions get a subset,
/// relayed back to this Mac by the remote helper.
public enum BuiltInMCPToolScope: Equatable, Sendable {
    case full
    /// `visual_show` only: an SSH session behind a helper without
    /// `remoteMCPTools`, whose relay gives up before `pr_create` can finish.
    case visualOnly
    /// `visual_show`, `pr_create`, and `pr_status`: an SSH session.
    case remote

    /// The `alas mcp` flag for an SSH relay backend serving this scope.
    public var relayBackendFlag: String? {
        switch self {
        case .full: nil
        case .visualOnly: "--visual-only"
        case .remote: "--remote"
        }
    }
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
        public let toolScope: BuiltInMCPToolScope

        public init(server: ACPMCPServer, status: MCPAttachmentServerStatus, isDelegated: Bool, toolScope: BuiltInMCPToolScope = .full) {
            self.server = server
            self.status = status
            self.isDelegated = isDelegated
            self.toolScope = toolScope
        }
    }

    /// The stdio env entries that identify the server an agent runs.
    private static let agentIdentityEnv: Set<String> = ["ALAS_SOCKET_PATH", "ALAS_CLI_BUILD"]

    /// Identifies how an agent reaches the built-in server, so an attach that
    /// adopts a surviving agent can tell whether it still reaches the server
    /// this attach configures. HTTP: the URL and credentials the agent
    /// connects to. stdio: the agent runs the server itself, so only the
    /// command, the app socket it reports to and the CLI build it runs
    /// matter; the scoping env (worktree, workspace members) cannot strand
    /// it. The build makes an app update count as another server, so an
    /// agent adopted across the update is restarted with the new tools.
    public static func agentFingerprint(of server: ACPMCPServer) -> String {
        let identity: [String]
        switch server {
        case let .http(_, url, headers), let .sse(_, url, headers):
            let kind = if case .http = server { "http" } else { "sse" }
            identity = [kind, url] + headers.flatMap { [$0.name, $0.value] }
        case let .stdio(_, command, args, env):
            identity = ["stdio", command] + args
                + env.filter { agentIdentityEnv.contains($0.name) }.map(\.value)
        }
        return SHA256.hash(data: Data(identity.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The status row for a built-in server that was requested but cannot be
    /// served, e.g. an SSH host whose helper cannot relay it.
    public static func unavailableStatus(_ reason: String) -> MCPAttachmentServerStatus {
        .init(id: statusId, name: serverName, transport: .stdio,
              disposition: .skipped(.remoteRelayUnavailable(reason)))
    }

    /// The entry for an SSH session: the remote helper's stdio proxy, which
    /// relays the scope's tools back to this Mac. It carries no local command,
    /// socket, credential, or session id; the descriptor names only the
    /// helper binary, its state directory, and the stable remote record.
    public static func remoteVisualInjection(
        descriptor: RemoteMCPRouteDescriptor,
        toolScope: BuiltInMCPToolScope
    ) -> Injection {
        Injection(
            server: .stdio(name: serverName, command: descriptor.proxyCommand, args: descriptor.proxyArgs, env: []),
            status: .init(id: statusId, name: serverName, transport: .stdio, disposition: .requested),
            isDelegated: false,
            toolScope: toolScope
        )
    }

    /// An HTTP endpoint for the built-in server. When provided, `injection`
    /// emits an `.http` wire entry (with a bearer auth header) instead of the
    /// default `.stdio` entry.
    public struct HTTPEndpoint: Equatable, Sendable {
        public let url: String
        public let token: String

        public init(url: String, token: String) {
            self.url = url
            self.token = token
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
        workspaceContext: WorkspaceContext? = nil,
        headless: Bool = false,
        cliBuild: String? = nil
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
                ] + (cliBuild.map { [.init(name: "ALAS_CLI_BUILD", value: $0)] } ?? [])
                    + (parentSessionId.map { [.init(name: "ALAS_PARENT_SESSION_ID", value: $0)] } ?? [])
                    + workspaceEnvironment
                    + (headless ? [.init(name: "ALAS_MCP_HEADLESS", value: "1")] : [])
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
