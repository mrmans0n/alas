import Testing
import Foundation
@testable import Alas

struct CursorInstallerTests {
    private func tmpSettingsURL() -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hooks.json")
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func installState_noFile_notInstalled() {
        let installer = CursorInstaller(settingsURL: URL(fileURLWithPath: "/nonexistent/hooks.json"))
        #expect(installer.installState() == .notInstalled)
    }

    @Test func installRoundTrip() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = CursorInstaller(settingsURL: url)

        try await installer.install()
        #expect(installer.installState() == .installed)

        try installer.uninstall()
        #expect(installer.installState() == .notInstalled)
    }

    @Test func install_preservesThirdPartyEntries() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let existing: [String: Any] = [
            "version": 1,
            "hooks": [
                "stop": [["command": "/usr/local/bin/my-hook", "timeout": 5]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted).write(to: url)

        let installer = CursorInstaller(settingsURL: url)
        try await installer.install()

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let stopEntries = hooks["stop"] as! [[String: Any]]
        let thirdParty = stopEntries.filter { !AlasHookCommand.isManagedCommand($0["command"] as? String ?? "") }
        #expect(thirdParty.count == 1)
        #expect(thirdParty[0]["command"] as? String == "/usr/local/bin/my-hook")
    }
}
