import Foundation

/// A device the `device_*` tools can drive, from either platform.
public struct AgentDevice: Equatable, Sendable {
    public enum Platform: String, Sendable { case ios, android }

    public let id: String
    public let name: String
    public let platform: Platform
    /// "iOS 26.5", "Android 16".
    public let runtime: String
    /// booted, booting, shutdown, shutting_down, unauthorized, offline.
    public let state: String

    public init(id: String, name: String, platform: Platform, runtime: String, state: String) {
        self.id = id
        self.name = name
        self.platform = platform
        self.runtime = runtime
        self.state = state
    }

    public var isBooted: Bool { state == "booted" }

    public var json: [String: Any] {
        ["udid": id, "name": name, "platform": platform.rawValue, "runtime": runtime, "state": state]
    }

    /// Simulators have UUIDs; Android serials and `avd:` ids never are.
    public static func isSimulatorID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }
}
