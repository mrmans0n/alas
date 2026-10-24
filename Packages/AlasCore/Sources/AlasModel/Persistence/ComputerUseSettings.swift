import Foundation

/// User-controlled switch for agent computer use (screen capture and input).
public struct ComputerUseSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// Bundle ids of apps the user chose "Always allow" for. Renamed from
    /// `alwaysAllowedBundleIDs` so see-only grants do not carry over to acting.
    public var alwaysAllowedApps: [String] = []

    public init(enabled: Bool = false, alwaysAllowedApps: [String] = []) {
        self.enabled = enabled
        self.alwaysAllowedApps = alwaysAllowedApps
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, alwaysAllowedApps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        alwaysAllowedApps = try container.decodeIfPresent([String].self, forKey: .alwaysAllowedApps) ?? []
    }
}
