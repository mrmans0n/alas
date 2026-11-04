import Foundation

/// One iOS simulator from `xcrun simctl list devices --json`.
public struct SimulatorDevice: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case booted, booting, shutdown, shuttingDown
        case other(String)

        init(simctl value: String) {
            switch value {
            case "Booted": self = .booted
            case "Booting": self = .booting
            case "Shutdown": self = .shutdown
            case "Shutting Down": self = .shuttingDown
            default: self = .other(value)
            }
        }
    }

    public let udid: String
    public let name: String
    /// For example "iOS 26.5".
    public let runtimeName: String
    public let state: State
    public var id: String { udid }

    public init(udid: String, name: String, runtimeName: String, state: State) {
        self.udid = udid
        self.name = name
        self.runtimeName = runtimeName
        self.state = state
    }
}

public enum SimulatorDeviceList {
    private struct Listing: Decodable {
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
        }
        let devices: [String: [Device]]
    }

    /// The available iOS simulators in simctl's JSON: booted first, then the
    /// newest runtime, then by name.
    public static func parse(_ json: Data) throws -> [SimulatorDevice] {
        let listing = try JSONDecoder().decode(Listing.self, from: json)
        var rows: [(version: [Int], device: SimulatorDevice)] = []
        for (runtime, devices) in listing.devices {
            guard let parts = runtimeParts(runtime), parts.platform == "iOS" else { continue }
            let runtimeName = "iOS " + parts.version.map(String.init).joined(separator: ".")
            for device in devices where device.isAvailable == true {
                rows.append((parts.version, SimulatorDevice(
                    udid: device.udid, name: device.name, runtimeName: runtimeName,
                    state: .init(simctl: device.state)
                )))
            }
        }
        rows.sort { a, b in
            let aBooted = a.device.state == .booted
            let bBooted = b.device.state == .booted
            if aBooted != bBooted { return aBooted }
            if a.version != b.version { return b.version.lexicographicallyPrecedes(a.version) }
            if a.device.name != b.device.name { return a.device.name < b.device.name }
            return a.device.udid < b.device.udid
        }
        return rows.map(\.device)
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` is `("iOS", [26, 5])`.
    static func runtimeParts(_ identifier: String) -> (platform: String, version: [Int])? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        let version = parts.dropFirst().compactMap { Int($0) }
        guard version.count == parts.count - 1 else { return nil }
        return (String(parts[0]), version)
    }
}
