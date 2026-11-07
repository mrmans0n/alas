import Foundation

/// A simulator screen's size in points and its corner radius, read from the
/// device type's bundle and its DeviceKit chrome.
public struct DeviceScreenShape: Equatable, Sendable {
    public let widthPoints: Double
    public let heightPoints: Double
    /// 0 when the device type has no chrome: square corners.
    public let cornerRadiusPoints: Double

    public init(widthPoints: Double, heightPoints: Double, cornerRadiusPoints: Double) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.cornerRadiusPoints = cornerRadiusPoints
    }

    /// The corner radius once the screen is drawn `width` points wide.
    public func cornerRadius(forFittedWidth width: Double) -> Double {
        guard widthPoints > 0 else { return 0 }
        return cornerRadiusPoints * width / widthPoints
    }

    /// The chrome's outer radius minus its bezel width: 80 − 18 = 62 on an iPhone 17 Pro.
    public static func screenCornerRadius(chromeJSON: Data) -> Double? {
        guard let root = (try? JSONSerialization.jsonObject(with: chromeJSON)) as? [String: Any],
              let border = (root["paths"] as? [String: Any])?["simpleOutsideBorder"] as? [String: Any],
              let outer = (border["cornerRadiusX"] as? NSNumber)?.doubleValue,
              let sizing = (root["images"] as? [String: Any])?["sizing"] as? [String: Any],
              let bezel = (sizing["leftWidth"] as? NSNumber)?.doubleValue
        else { return nil }
        let radius = outer - bezel
        return radius > 0 ? radius : nil
    }

    /// `com.apple.dt.devicekit.chrome.phone11` is `<root>/phone11.devicechrome/…/chrome.json`.
    public static func chromeURL(profilePlist: Data, root: URL) -> URL? {
        guard let profile = (try? PropertyListSerialization.propertyList(from: profilePlist, format: nil)) as? [String: Any],
              let identifier = profile["chromeIdentifier"] as? String,
              let name = identifier.split(separator: ".").last, !name.isEmpty
        else { return nil }
        return root.appendingPathComponent("\(name).devicechrome/Contents/Resources/chrome.json")
    }

    /// The main screen in points, from `capabilities.plist`.
    public static func screenSize(capabilitiesPlist: Data) -> (width: Double, height: Double)? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: capabilitiesPlist, format: nil)) as? [String: Any],
              let screen = (plist["capabilities"] as? [String: Any])?["ScreenDimensionsCapability"] as? [String: Any],
              let width = (screen["main-screen-width"] as? NSNumber)?.doubleValue,
              let height = (screen["main-screen-height"] as? NSNumber)?.doubleValue,
              let scale = (screen["main-screen-scale"] as? NSNumber)?.doubleValue, scale > 0
        else { return nil }
        return (width / scale, height / scale)
    }

    /// Reads a `.simdevicetype` bundle; nil without a screen size.
    public static func load(
        bundle: URL, chromeRoot: URL = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome")
    ) -> DeviceScreenShape? {
        let resources = bundle.appendingPathComponent("Contents/Resources")
        guard let capabilities = try? Data(contentsOf: resources.appendingPathComponent("capabilities.plist")),
              let size = screenSize(capabilitiesPlist: capabilities)
        else { return nil }
        let radius = (try? Data(contentsOf: resources.appendingPathComponent("profile.plist")))
            .flatMap { chromeURL(profilePlist: $0, root: chromeRoot) }
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(screenCornerRadius(chromeJSON:)) ?? 0
        return DeviceScreenShape(widthPoints: size.width, heightPoints: size.height, cornerRadiusPoints: radius)
    }
}
