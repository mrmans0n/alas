import Foundation

/// User-controlled switch for agent computer use (screen capture and input).
public struct ComputerUseSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// Bundle ids of apps the user chose "Always allow" for.
    public var alwaysAllowedBundleIDs: [String] = []

    public init(enabled: Bool = false, alwaysAllowedBundleIDs: [String] = []) {
        self.enabled = enabled
        self.alwaysAllowedBundleIDs = alwaysAllowedBundleIDs
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, alwaysAllowedBundleIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        alwaysAllowedBundleIDs = try container.decodeIfPresent([String].self, forKey: .alwaysAllowedBundleIDs) ?? []
    }
}
