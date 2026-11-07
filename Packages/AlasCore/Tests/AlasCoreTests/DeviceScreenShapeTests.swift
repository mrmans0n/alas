import Foundation
import Testing
import AlasCore

struct DeviceScreenShapeTests {
    static func chrome(outer: Int?, bezel: Int?) -> Data {
        var paths: [String: Any] = [:]
        if let outer { paths["simpleOutsideBorder"] = ["cornerRadiusX": outer, "cornerRadiusY": outer] }
        var images: [String: Any] = ["screen": "Screen"]
        if let bezel { images["sizing"] = ["leftWidth": bezel, "rightWidth": bezel] }
        return try! JSONSerialization.data(withJSONObject: ["paths": paths, "images": images])
    }

    static func plist(_ object: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    static let phoneCapabilities = plist(["capabilities": ["ScreenDimensionsCapability": [
        "main-screen-width": 1206, "main-screen-height": 2622, "main-screen-scale": 3,
    ]]])

    @Test(arguments: [
        (chrome(outer: 80, bezel: 18), 62.0 as Double?),   // phone11
        (chrome(outer: 81, bezel: 59), 22.0),              // tablet4
        (chrome(outer: nil, bezel: 18), nil),
        (chrome(outer: 10, bezel: 18), nil),
        (Data("not json".utf8), nil),
    ] as [(Data, Double?)])
    func cornerRadiusComesFromTheChrome(json: Data, radius: Double?) {
        #expect(DeviceScreenShape.screenCornerRadius(chromeJSON: json) == radius)
    }

    @Test func chromeURLUsesTheLastComponentOfTheIdentifier() {
        let root = URL(fileURLWithPath: "/K")
        let named = Self.plist(["chromeIdentifier": "com.apple.dt.devicekit.chrome.phone11"])
        #expect(DeviceScreenShape.chromeURL(profilePlist: named, root: root)?.path
            == "/K/phone11.devicechrome/Contents/Resources/chrome.json")
        #expect(DeviceScreenShape.chromeURL(profilePlist: Self.plist([:]), root: root) == nil)
    }

    @Test func screenSizeIsInPoints() throws {
        let size = try #require(DeviceScreenShape.screenSize(capabilitiesPlist: Self.phoneCapabilities))
        #expect(size.width == 402 && size.height == 874)
    }

    @Test func screenShapeScalesItsCornersWithTheFittedWidth() {
        #expect(DeviceScreenShape(widthPoints: 402, heightPoints: 874, cornerRadiusPoints: 62)
            .cornerRadius(forFittedWidth: 201) == 31)
        #expect(DeviceScreenShape(widthPoints: 402, heightPoints: 874, cornerRadiusPoints: 0)
            .cornerRadius(forFittedWidth: 201) == 0)
    }

    @Test(arguments: [true, false])
    func loadReadsADeviceTypeBundle(hasChrome: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-shape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Phone.simdevicetype/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Self.plist(["chromeIdentifier": "x.phone11"]).write(to: resources.appendingPathComponent("profile.plist"))
        try Self.phoneCapabilities.write(to: resources.appendingPathComponent("capabilities.plist"))
        if hasChrome {
            let chrome = root.appendingPathComponent("Chrome/phone11.devicechrome/Contents/Resources")
            try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
            try Self.chrome(outer: 80, bezel: 18).write(to: chrome.appendingPathComponent("chrome.json"))
        }
        let shape = DeviceScreenShape.load(
            bundle: root.appendingPathComponent("Phone.simdevicetype"), chromeRoot: root.appendingPathComponent("Chrome"))
        #expect(shape == DeviceScreenShape(widthPoints: 402, heightPoints: 874, cornerRadiusPoints: hasChrome ? 62 : 0))
    }
}
