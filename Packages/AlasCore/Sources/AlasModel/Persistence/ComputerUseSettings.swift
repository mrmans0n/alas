import Foundation

/// User-controlled switch for agent computer use (screen capture and input).
public struct ComputerUseSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}
