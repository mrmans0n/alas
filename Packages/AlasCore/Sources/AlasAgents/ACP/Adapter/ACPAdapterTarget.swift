import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Identifies the machine that owns an ACP adapter installation.
public enum ACPAdapterTarget: Hashable, Sendable {
    case local
    case ssh(host: String)
}

/// Stable identity for update state belonging to one adapter on one target.
public struct ACPAdapterUpdateKey: Hashable, Sendable {
    public let target: ACPAdapterTarget
    public let agentID: String

    public var storageKey: String {
        switch target {
        case .local:
            "v2|local|\(Self.field(agentID))"
        case .ssh(let host):
            "v2|ssh|\(Self.field(host))|\(Self.field(agentID))"
        }
    }

    /// Update state for a detected agent CLI itself rather than its ACP
    /// adapter, so pi's adapter and CLI updates are cached and dismissed
    /// independently. Keyed by the owning install too, so switching to
    /// another install never reuses its state. Agent ids never contain `:`.
    public static func detectedCLI(agentID: String, owner: ACPDetectedAgentOwner) -> Self {
        .init(target: .local, agentID: "cli:\(agentID):\(owner.cacheIdentity)")
    }

    private static func field(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    public init(target: ACPAdapterTarget, agentID: String) {
        self.target = target
        self.agentID = agentID
    }
}
