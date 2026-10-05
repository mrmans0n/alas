import Foundation

struct ACPManagedAdapterDescriptor: Equatable, Sendable {
    let agentID: String
    let packageName: String
    let binaryName: String
    let legacyPackageNames: [String]

    static let claude = ACPManagedAdapterDescriptor(
        agentID: "claude",
        packageName: "@alas-ide/claude-agent-acp",
        binaryName: "claude-agent-acp",
        legacyPackageNames: [
            "@agentclientprotocol/claude-agent-acp",
            "@zed-industries/claude-code-acp",
        ]
    )

    static let codex = ACPManagedAdapterDescriptor(
        agentID: "codex",
        packageName: "@alas-ide/codex-acp",
        binaryName: "codex-acp",
        legacyPackageNames: [
            "@agentclientprotocol/codex-acp",
            "@zed-industries/codex-acp",
        ]
    )

    static let pi = ACPManagedAdapterDescriptor(
        agentID: "pi",
        packageName: "pi-acp",
        binaryName: "pi-acp",
        legacyPackageNames: []
    )

    /// Exact identities whose native-delegation contract has been verified.
    var verifiedPackageNames: [String] {
        switch agentID {
        case "claude": [packageName, "@agentclientprotocol/claude-agent-acp"]
        case "codex": [packageName, "@agentclientprotocol/codex-acp"]
        default: [packageName]
        }
    }

    static func descriptor(for agentID: String) -> ACPManagedAdapterDescriptor? {
        switch agentID {
        case claude.agentID: claude
        case codex.agentID: codex
        case pi.agentID: pi
        default: nil
        }
    }
}
