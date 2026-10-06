import Foundation

/// Identifies the machine that owns an ACP adapter installation.
enum ACPAdapterTarget: Hashable, Sendable {
    case local
    case ssh(host: String)
}

/// Stable identity for update state belonging to one adapter on one target.
struct ACPAdapterUpdateKey: Hashable, Sendable {
    let target: ACPAdapterTarget
    let agentID: String

    var storageKey: String {
        switch target {
        case .local:
            "v2|local|\(Self.field(agentID))"
        case .ssh(let host):
            "v2|ssh|\(Self.field(host))|\(Self.field(agentID))"
        }
    }

    /// Update state for a detected agent CLI itself rather than its ACP
    /// adapter, so pi's adapter and CLI updates are cached and dismissed
    /// independently. Agent ids never contain `:`.
    static func detectedCLI(agentID: String) -> Self {
        .init(target: .local, agentID: "cli:\(agentID)")
    }

    private static func field(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}
