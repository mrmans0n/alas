import Crypto
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasIntegrations

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

/// Groups of built-in tools an agent's settings can leave out of the MCP
/// tool list, for harnesses that cap how many MCP tools they load. Left-out
/// tools still run, and the agent reaches them with `alas tool call`. The raw
/// value is the tools' name prefix, as `alas mcp` reads it from
/// `ALAS_MCP_HIDDEN_TOOL_GROUPS`.
public enum BuiltInMCPToolGroup: String, CaseIterable, Codable, Sendable {
    case preview
    case computer
    case vm
    case device

    public var displayName: String {
        switch self {
        case .preview: "Browser preview"
        case .computer: "Computer use"
        case .vm: "Worktree VMs"
        case .device: "Simulators and devices"
        }
    }

    public var toolNames: [String] {
        ACPMCPPromptPreamble.builtInToolNames.filter { $0.hasPrefix("\(rawValue)_") }
    }

    /// The `ALAS_MCP_HIDDEN_TOOL_GROUPS` value, or nil when nothing is hidden.
    static func environmentValue(_ groups: Set<Self>) -> String? {
        groups.isEmpty ? nil : allCases.filter(groups.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// What the session manager knows when it asks for the built-in server.
public struct BuiltInMCPAttachmentContext: Sendable {
    public enum Location: Equatable, Sendable {
        /// `adapterSupportsACP`: the agent takes servers the app answers over
        /// the ACP connection (`mcpCapabilities.acp`).
        case local(adapterSupportsHTTP: Bool, adapterSupportsACP: Bool = false)
        /// The fence is the session's confirmed remote authority at attach.
        case ssh(host: String, fence: RemoteSessionFence)
    }

    public let worktreePath: String
    public let sessionId: String
    /// The session's agent, which picks the name the server is attached under.
    public let agentID: String
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
        agentID: String,
        injectionSupport: ACPMCPInjectionSupport,
        location: Location,
        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
        noteRegistered: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.worktreePath = worktreePath
        self.sessionId = sessionId
        self.agentID = agentID
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

    /// A local injection needs no resources beyond the agent's own process,
    /// or, served over ACP, the backend that answers its messages.
    @MainActor
    public static func local(
        _ injection: BuiltInAlasMCP.Injection?,
        acpBackend: ACPMCPMessageRouter.Backend? = nil
    ) -> BuiltInMCPAttachment {
        injection.map { .prepared(PreparedBuiltInMCPAttachment(injection: $0, acpBackend: acpBackend)) } ?? .omitted
    }
}

/// A built-in server entry plus the resources serving it. The session
/// manager invalidates it when the attachment that requested it ends.
@MainActor
public final class PreparedBuiltInMCPAttachment {
    public let injection: BuiltInAlasMCP.Injection
    /// Answers the agent's `mcp/message` when the injection is `.acp`.
    public let acpBackend: ACPMCPMessageRouter.Backend?
    private var cleanup: (@Sendable () async -> Void)?

    public init(
        injection: BuiltInAlasMCP.Injection,
        acpBackend: ACPMCPMessageRouter.Backend? = nil,
        cleanup: (@Sendable () async -> Void)? = nil
    ) {
        self.injection = injection
        self.acpBackend = acpBackend
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
    /// The default name the server is attached under.
    public static let serverName = "alas"
    public static let statusId = "builtin-alas"

    /// A user-chosen server name, or nil when `raw` is blank, not a name
    /// every agent accepts (letters, digits, `_` and `-`, at most 64), or the
    /// name of another server Alas attaches on its own (`git-gud`), which
    /// would put two servers under one name. Agents under a managed MCP
    /// allowlist only start servers whose name is on it, so the name has to
    /// be settable.
    public static func normalizedServerName(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...64).contains(name.utf8.count),
              name != GGMCPInjection.serverName,
              name.utf8.allSatisfy({ byte in
                  switch byte {
                  case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                       UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                      true
                  default:
                      false
                  }
              })
        else { return nil }
        return name
    }

    public struct Injection: Equatable, Sendable {
        public let server: ACPMCPServer
        public let status: MCPAttachmentServerStatus
        public let isDelegated: Bool
        /// The child was delegated from another Mac: its parent is a `peer:` sentinel.
        public let isPeerChild: Bool
        public let toolScope: BuiltInMCPToolScope
        /// Groups left out of the server's tool list; see `BuiltInMCPToolGroup`.
        public let hiddenToolGroups: Set<BuiltInMCPToolGroup>

        public init(
            server: ACPMCPServer, status: MCPAttachmentServerStatus, isDelegated: Bool, isPeerChild: Bool = false,
            toolScope: BuiltInMCPToolScope = .full, hiddenToolGroups: Set<BuiltInMCPToolGroup> = []
        ) {
            self.server = server
            self.status = status
            self.isDelegated = isDelegated
            self.isPeerChild = isPeerChild
            self.toolScope = toolScope
            self.hiddenToolGroups = hiddenToolGroups
        }
    }

    public enum Delivery: Equatable, Sendable {
        /// Agent-spawned `alas mcp`.
        case stdio
        /// The app's `alas mcp --http` process, which the agent connects to.
        case http
        /// The app's `alas mcp --http` process behind the ACP connection:
        /// the agent sends `mcp/message` and the app forwards it.
        case acp
    }

    /// How a local session gets the built-in server: the preferred transport
    /// when the agent supports it, falling back from ACP to HTTP to stdio.
    public static func delivery(
        preference: AlasMCPTransport,
        adapterSupportsHTTP: Bool,
        adapterSupportsACP: Bool
    ) -> Delivery {
        switch preference {
        case .acp where adapterSupportsACP: .acp
        case .acp, .http: adapterSupportsHTTP ? .http : .stdio
        case .stdio: .stdio
        }
    }

    /// The registration id a session's server is served over ACP under. It
    /// stays the same across attaches: an agent adopted from its broker keeps
    /// the configuration it started with and goes on naming this id.
    public static func acpServerId(sessionId: String) -> String {
        "alas-\(sessionId)"
    }

    /// The stdio env entries that identify the server an agent runs.
    private static let agentIdentityEnv: Set<String> = ["ALAS_SOCKET_PATH", "ALAS_CLI_BUILD"]

    /// Identifies how an agent reaches the built-in server, so an attach that
    /// adopts a surviving agent can tell whether it still reaches the server
    /// this attach configures. The name the agent knows the server by, then
    /// HTTP: the URL and headers the agent connects with, which carry its
    /// credentials and the CLI build serving it.
    /// stdio: the agent runs the server itself, so only the command, the app
    /// socket it reports to and the CLI build it runs matter; the scoping env
    /// (worktree, workspace members) cannot strand it. Either way the build
    /// makes an app update count as another server, so an agent adopted
    /// across the update is restarted with the new tools.
    /// ACP: the app answers every message itself, with whichever build is
    /// running, so only the name and the registration identify it.
    public static func agentFingerprint(of server: ACPMCPServer) -> String {
        let identity: [String]
        switch server {
        case let .http(name, url, headers), let .sse(name, url, headers):
            let kind = if case .http = server { "http" } else { "sse" }
            identity = [name, kind, url] + headers.flatMap { [$0.name, $0.value] }
        case let .stdio(name, command, args, env):
            identity = [name, "stdio", command] + args
                + env.filter { agentIdentityEnv.contains($0.name) }.map(\.value)
        case let .acp(name, serverId):
            identity = [name, "acp", serverId]
        }
        return SHA256.hash(data: Data(identity.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// What an agent's MCP allowlist matches the server on, stable across
    /// sessions: the name with the command and its arguments, or with the
    /// transport for a URL, whose port is picked per session. Unlike
    /// `agentFingerprint`, it leaves out the per-session socket.
    public static func policyIdentity(of server: ACPMCPServer) -> String {
        let identity: [String]
        switch server {
        case let .http(name, _, _): identity = [name, "http"]
        case let .sse(name, _, _): identity = [name, "sse"]
        case let .stdio(name, command, args, _): identity = [name, "stdio", command] + args
        case let .acp(name, _): identity = [name, "acp"]
        }
        return identity.joined(separator: "\u{0}")
    }

    /// The status row for a built-in server that was requested but cannot be
    /// served, e.g. an SSH host whose helper cannot relay it.
    public static func unavailableStatus(
        _ reason: String, serverName: String = BuiltInAlasMCP.serverName
    ) -> MCPAttachmentServerStatus {
        .init(id: statusId, name: serverName, transport: .stdio,
              disposition: .skipped(.remoteRelayUnavailable(reason)))
    }

    /// The entry for an SSH session: the remote helper's stdio proxy, which
    /// relays the scope's tools back to this Mac. It carries no local command,
    /// socket, credential, or session id; the descriptor names only the
    /// helper binary, its state directory, and the stable remote record.
    public static func remoteVisualInjection(
        descriptor: RemoteMCPRouteDescriptor,
        toolScope: BuiltInMCPToolScope,
        serverName: String = BuiltInAlasMCP.serverName
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
                             binaryPath: String?, socketPath: String?,
                             serverName: String = BuiltInAlasMCP.serverName) -> Bool {
        guard enabled, binaryPath != nil, socketPath != nil else { return false }
        return !isOverridden(by: configuredServers, serverName: serverName)
    }

    /// Whether an SSH session should request the relayed visual tool. An
    /// `.external` adapter (Pi) ignores ACP MCP config, so the relay would
    /// never be reached; its own status reports that limitation.
    public static func injectsRemoteVisual(enabled: Bool, configuredServers: [ProjectMCPServer],
                                           injectionSupport: ACPMCPInjectionSupport,
                                           serverName: String = BuiltInAlasMCP.serverName) -> Bool {
        guard enabled, injectionSupport == .sessionNew else { return false }
        return !isOverridden(by: configuredServers, serverName: serverName)
    }

    /// A configured server named "alas" is an intentional user override, and
    /// one named like the server's chosen name would collide with it.
    private static func isOverridden(by configuredServers: [ProjectMCPServer], serverName: String) -> Bool {
        configuredServers.contains {
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name == BuiltInAlasMCP.serverName || name == serverName
        }
    }

    /// The wire entry + status row for the built-in server, or nil when it
    /// must not be injected: globally disabled, the managed binary or app
    /// socket is unavailable, or the project already configures a server
    /// named "alas" or `serverName` (an intentional user override, e.g. a
    /// dev binary).
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
        deviceTools: Bool = true,
        hiddenToolGroups: Set<BuiltInMCPToolGroup> = [],
        cliBuild: String? = nil,
        serverName: String = BuiltInAlasMCP.serverName,
        acpServerId: String? = nil
    ) -> Injection? {
        guard shouldInject(
            enabled: enabled,
            configuredServers: configuredServers,
            binaryPath: binaryPath,
            socketPath: socketPath,
            serverName: serverName
        ), let binaryPath, let socketPath else { return nil }

        let server: ACPMCPServer
        let transport: MCPTransportKind
        if let acpServerId {
            // The app answers each message itself, so the agent needs no address.
            server = .acp(name: serverName, serverId: acpServerId)
            transport = .acp
        } else if let httpEndpoint {
            server = .http(
                name: serverName,
                url: httpEndpoint.url,
                headers: [.init(name: "Authorization", value: "Bearer \(httpEndpoint.token)")]
                    // Unread by the server; it makes an update a new server in the agent fingerprint.
                    + (cliBuild.map { [.init(name: "X-Alas-CLI-Build", value: $0)] } ?? [])
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
                    + (deviceTools ? [] : [.init(name: "ALAS_MCP_DEVICES", value: "0")])
                    + (BuiltInMCPToolGroup.environmentValue(hiddenToolGroups).map {
                        [.init(name: "ALAS_MCP_HIDDEN_TOOL_GROUPS", value: $0)]
                    } ?? [])
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
            isPeerChild: parentSessionId.flatMap(ACPPeerParent.serverId(from:)) != nil,
            hiddenToolGroups: hiddenToolGroups
        )
    }
}
