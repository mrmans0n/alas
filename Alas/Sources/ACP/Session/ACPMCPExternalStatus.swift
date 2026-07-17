import Foundation

/// Snapshot of how MCP reaches an `.external` adapter (one that ignores ACP
/// `session/new` MCP config) for the most recent attach. Runtime-only —
/// recomputed every attach, never persisted.
struct ACPMCPExternalStatus: Equatable {
    let cliActive: Bool
    let adapterState: PiMCPAdapterInspector.State
    let configOutcome: PiMCPConfigWriter.Outcome?
    let hint: String

    var adapterInstalled: Bool { adapterState == .installed }

    /// True when the adapter is installed AND the last `.pi/mcp.json` sync
    /// actually succeeded — a failed write means user MCP servers are not
    /// reachable through pi-mcp-adapter even though the extension itself is
    /// present.
    var adapterServersAvailable: Bool { adapterState == .installed && configOutcome != .failed }
}
