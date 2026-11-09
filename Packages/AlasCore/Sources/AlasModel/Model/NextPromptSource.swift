import Foundation

/// Where the composer's next-prompt suggestion comes from.
public enum NextPromptSource: String, Codable, CaseIterable, Sendable {
    /// The local model on this Mac.
    case onDevice
    /// The agent's own prediction, from an adapter that offers one.
    case agent
}
