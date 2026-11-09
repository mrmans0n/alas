import Foundation

/// Where the composer's next-prompt suggestion comes from.
public enum NextPromptSource: String, Codable, CaseIterable, Sendable {
    /// The agent's own prediction when its adapter offers one, the local model otherwise.
    case automatic
    /// The local model on this Mac.
    case onDevice
    /// The agent's own prediction, from an adapter that offers one.
    case agent

    /// The engine that answers a session's turn: never `.automatic`.
    public func resolved(agentPredicts: Bool) -> NextPromptSource {
        guard self == .automatic else { return self }
        return agentPredicts ? .agent : .onDevice
    }
}
