import Foundation

/// Snapshot of how MCP reaches an `.external` adapter (one that ignores ACP
/// `session/new` MCP config) for the most recent attach. Runtime-only —
/// recomputed every attach, never persisted.
public struct ACPMCPExternalStatus: Equatable, Sendable {
    /// Availability of the project's MCP servers through the external
    /// adapter, distinguishing *why* they may not be reachable.
    public enum AdapterServerAvailability: Equatable, Sendable {
        /// Alas wrote/maintains a managed `.pi/mcp.json` with the servers.
        case available
        /// pi-mcp-adapter extension absent.
        case notInstalled
        /// Installed, but Alas could not write `.pi/mcp.json`.
        case syncFailed
        /// Installed, but an unmanaged `.pi/mcp.json` exists — Alas did not
        /// write the project's servers into it.
        case userManaged
        /// Installed, but there is nothing to provide.
        case noServers
    }

    public let cliActive: Bool
    public let adapterState: PiMCPAdapterInspector.State
    public let configOutcome: PiMCPConfigWriter.Outcome?
    public let hint: String
    /// The project's `.external`-plan (all-transports) MCP server names,
    /// resolved regardless of adapter/config state so the preamble can name
    /// them even when they are not (yet) reachable.
    public let userServerNames: [String]
    /// Project MCP servers skipped by the external adapter's own planning pass.
    public let skippedServerStatuses: [MCPAttachmentServerStatus]
    /// Project MCP servers the plan requested, including approved repo-defined
    /// ones. Lets the status control show and disable them under `.external`
    /// injection too, where the attachment rows are replaced wholesale.
    public let requestedServerStatuses: [MCPAttachmentServerStatus]
    /// True when the current host can run the local remediation action for a
    /// missing adapter. Remote worktrees must not offer the local install button.
    public let canInstallAdapterLocally: Bool

    public init(
        cliActive: Bool,
        adapterState: PiMCPAdapterInspector.State,
        configOutcome: PiMCPConfigWriter.Outcome?,
        hint: String,
        userServerNames: [String],
        skippedServerStatuses: [MCPAttachmentServerStatus] = [],
        requestedServerStatuses: [MCPAttachmentServerStatus] = [],
        canInstallAdapterLocally: Bool = true
    ) {
        self.cliActive = cliActive
        self.adapterState = adapterState
        self.configOutcome = configOutcome
        self.hint = hint
        self.userServerNames = userServerNames
        self.skippedServerStatuses = skippedServerStatuses
        self.requestedServerStatuses = requestedServerStatuses
        self.canInstallAdapterLocally = canInstallAdapterLocally
    }

    public var adapterInstalled: Bool { adapterState == .installed }

    /// Precise reason the project's MCP servers are (or are not) reachable
    /// through the external adapter.
    public var adapterServerAvailability: AdapterServerAvailability {
        if userServerNames.isEmpty || configOutcome == .noServers || configOutcome == .removedManaged {
            return .noServers
        }
        guard adapterState == .installed else { return .notInstalled }
        switch configOutcome {
        case .wrote?, .unchanged?: return .available
        case .failed?: return .syncFailed
        case .refusedUnmanaged?: return .userManaged
        case .removedManaged?, .noServers?, nil: return .noServers
        }
    }

    /// True only when the adapter is installed AND Alas actually wrote (or
    /// confirmed unchanged) the managed `.pi/mcp.json` — i.e. the project's
    /// servers are genuinely reachable through pi-mcp-adapter.
    public var adapterServersAvailable: Bool { adapterServerAvailability == .available }
}
