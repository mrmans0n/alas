import Foundation
import Testing
@testable import AlasCore

struct SimulatorAppBundleTests {
    enum Fixture: String, CaseIterable, Sendable {
        case simulator, noPlatform, device, noBundleID, notApp
    }

    private func make(_ fixture: Fixture) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-app-\(UUID().uuidString)")
        let app = root.appendingPathComponent(fixture == .notApp ? "Hello" : "Hello.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": "Hello", "CFBundleDisplayName": "Hello World"]
        if fixture != .noBundleID { plist["CFBundleIdentifier"] = "com.example.hello" }
        switch fixture {
        case .simulator: plist["DTPlatformName"] = "iphonesimulator"
        case .device: plist["DTPlatformName"] = "iphoneos"
        default: break
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        return app
    }

    @Test(arguments: Fixture.allCases)
    func readsSimulatorBuildsAndRefusesTheRest(_ fixture: Fixture) throws {
        let url = try make(fixture)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        switch fixture {
        case .simulator, .noPlatform:
            #expect(try SimulatorAppBundle.read(url)
                == SimulatorAppBundle(url: url, bundleID: "com.example.hello", name: "Hello World"))
        case .device:
            #expect(throws: SimulatorAppBundle.Problem.builtForDevice(name: "Hello World")) { try SimulatorAppBundle.read(url) }
        case .noBundleID:
            #expect(throws: SimulatorAppBundle.Problem.noBundleID(path: url.path)) { try SimulatorAppBundle.read(url) }
        case .notApp:
            #expect(throws: SimulatorAppBundle.Problem.notAnApp(path: url.path)) { try SimulatorAppBundle.read(url) }
        }
    }

    @Test(arguments: [
        ("com.example.hello: 4021\n", Int32(4021) as Int32?),
        ("com.example.other: 4021\n", nil),
        ("", nil),
    ])
    func launchOutputGivesThePID(stdout: String, pid: Int32?) {
        #expect(SimulatorControl.launchedPID(stdout, bundleID: "com.example.hello") == pid)
    }
}
