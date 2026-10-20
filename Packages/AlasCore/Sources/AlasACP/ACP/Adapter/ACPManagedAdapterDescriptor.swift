import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPManagedAdapterDescriptor: Equatable, Sendable {
    public let agentID: String
    public let packageName: String
    public let binaryName: String
    public let legacyPackageNames: [String]

    public static let claude = ACPManagedAdapterDescriptor(
        agentID: "claude",
        packageName: "@alas-ide/claude-agent-acp",
        binaryName: "claude-agent-acp",
        legacyPackageNames: [
            "@agentclientprotocol/claude-agent-acp",
            "@zed-industries/claude-code-acp",
        ]
    )

    public static let codex = ACPManagedAdapterDescriptor(
        agentID: "codex",
        packageName: "@alas-ide/codex-acp",
        binaryName: "codex-acp",
        legacyPackageNames: [
            "@agentclientprotocol/codex-acp",
            "@zed-industries/codex-acp",
        ]
    )

    public static let pi = ACPManagedAdapterDescriptor(
        agentID: "pi",
        packageName: "pi-acp",
        binaryName: "pi-acp",
        legacyPackageNames: []
    )

    /// Exact identities whose native-delegation contract has been verified.
    public var verifiedPackageNames: [String] {
        switch agentID {
        case "claude": [packageName, "@agentclientprotocol/claude-agent-acp"]
        case "codex": [packageName, "@agentclientprotocol/codex-acp"]
        default: [packageName]
        }
    }

    public static func descriptor(for agentID: String) -> ACPManagedAdapterDescriptor? {
        switch agentID {
        case claude.agentID: claude
        case codex.agentID: codex
        case pi.agentID: pi
        default: nil
        }
    }

    public init(agentID: String, packageName: String, binaryName: String, legacyPackageNames: [String]) {
        self.agentID = agentID
        self.packageName = packageName
        self.binaryName = binaryName
        self.legacyPackageNames = legacyPackageNames
    }
}
