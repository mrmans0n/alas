import Testing
import Foundation
@testable import Alas

struct ClaudeInstallerTests {
    private func tmpSettingsURL() -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func installState_noFile_notInstalled() {
        let installer = ClaudeInstaller(settingsURL: URL(fileURLWithPath: "/nonexistent/settings.json"))
        #expect(installer.installState() == .notInstalled)
    }

    @Test func installState_emptyFile_notInstalled() throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        try Data("{}".utf8).write(to: url)
        let installer = ClaudeInstaller(settingsURL: url)
        #expect(installer.installState() == .notInstalled)
    }

    @Test func installRoundTrip() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = ClaudeInstaller(settingsURL: url)

        try await installer.install()
        #expect(installer.installState() == .installed)

        // Third-party entry survives
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        var stopEntries = hooks["Stop"] as! [[String: Any]]
        stopEntries.append(["hooks": [["type": "command", "command": "/usr/local/bin/my-hook"]]])
        hooks["Stop"] = stopEntries
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        try installer.uninstall()
        #expect(installer.installState() == .notInstalled)

        let final = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let finalHooks = final["hooks"] as! [String: Any]
        let finalStop = finalHooks["Stop"] as! [[String: Any]]
        #expect(finalStop.count == 1)
        let cmds = finalStop[0]["hooks"] as! [[String: Any]]
        #expect(cmds[0]["command"] as? String == "/usr/local/bin/my-hook")
    }

    @Test func installState_staleEntries_outdated() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = ClaudeInstaller(settingsURL: url)
        try await installer.install()

        // Tamper a command to simulate a version upgrade
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        if var stopEntries = hooks["Stop"] as? [[String: Any]],
           var innerHooks = stopEntries[0]["hooks"] as? [[String: Any]] {
            innerHooks[0]["command"] = "old-command # alas-managed-hook"
            stopEntries[0]["hooks"] = innerHooks
            hooks["Stop"] = stopEntries
            json["hooks"] = hooks
            try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)
        }

        #expect(installer.installState() == .outdated)
    }
}
