import Foundation

struct ACPManagedAdapterDescriptor: Equatable, Sendable {
    let agentID: String
    let packageName: String
    let binaryName: String
    let legacyPackageNames: [String]

    static let claude = ACPManagedAdapterDescriptor(
        agentID: "claude",
        packageName: "@agentclientprotocol/claude-agent-acp",
        binaryName: "claude-agent-acp",
        legacyPackageNames: ["@zed-industries/claude-code-acp"]
    )

    static let codex = ACPManagedAdapterDescriptor(
        agentID: "codex",
        packageName: "@agentclientprotocol/codex-acp",
        binaryName: "codex-acp",
        legacyPackageNames: ["@zed-industries/codex-acp"]
    )

    static let pi = ACPManagedAdapterDescriptor(
        agentID: "pi",
        packageName: "pi-acp",
        binaryName: "pi-acp",
        legacyPackageNames: []
    )

    static func descriptor(for agentID: String) -> ACPManagedAdapterDescriptor? {
        switch agentID {
        case claude.agentID: claude
        case codex.agentID: codex
        case pi.agentID: pi
        default: nil
        }
    }
}
