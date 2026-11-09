import Foundation

/// The parts of a built iOS `.app` that installing it on a simulator needs.
public struct SimulatorAppBundle: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable, LocalizedError {
        case notAnApp(path: String)
        case noBundleID(path: String)
        case builtForDevice(name: String)

        /// The error an agent's `device_install` gets; `udid` fills in the build hint.
        public func message(udid: String) -> String {
            switch self {
            case .notAnApp(let path): "device_app_invalid: \(path) is not an app bundle."
            case .noBundleID(let path): "device_app_invalid: \(path) has no bundle ID."
            case .builtForDevice(let name):
                "device_app_wrong_platform: \(name) was built for a device. Build it for the simulator, for example with -destination 'platform=iOS Simulator,id=\(udid)'."
            }
        }

        public var errorDescription: String? {
            switch self {
            case .notAnApp(let path): "\((path as NSString).lastPathComponent) is not an app."
            case .noBundleID(let path): "\((path as NSString).lastPathComponent) has no bundle ID."
            case .builtForDevice(let name): "\(name) was built for a device, not the simulator."
            }
        }
    }

    public let url: URL
    public let bundleID: String
    public let name: String

    public init(url: URL, bundleID: String, name: String) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
    }

    /// Reads `<app>/Info.plist`, which iOS apps keep at the bundle's root. An
    /// app built for a device is refused; one without `DTPlatformName` is left
    /// for `simctl install` to judge.
    public static func read(_ url: URL) throws -> SimulatorAppBundle {
        var isDirectory: ObjCBool = false
        guard url.pathExtension == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { throw Problem.notAnApp(path: url.path) }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw Problem.noBundleID(path: url.path)
        }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        if plist["DTPlatformName"] as? String == "iphoneos" { throw Problem.builtForDevice(name: name) }
        return SimulatorAppBundle(url: url, bundleID: bundleID, name: name)
    }
}
