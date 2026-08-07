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

        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let installedHooks = installed["hooks"] as! [String: Any]
        #expect(installedHooks["sessionStart"] != nil)
        #expect(installedHooks["sessionEnd"] != nil)
        // Cursor's execution hooks fire for every shell command and MCP call;
        // they do not indicate that the agent is blocked on user approval.
        #expect(installedHooks["beforeShellExecution"] == nil)
        #expect(installedHooks["beforeMCPExecution"] == nil)

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

    /// Codex review (#102): a stale install with the right managed commands
    /// under the wrong event keys must report `.outdated`.
    @Test func installState_commandsUnderWrongEventKeys_outdated() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = CursorInstaller(settingsURL: url)
        try await installer.install()

        // Move `stop`'s command alongside `beforeSubmitPrompt`, drop `stop`.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        let stop = hooks["stop"] as! [[String: Any]]
        var before = hooks["beforeSubmitPrompt"] as! [[String: Any]]
        before.append(contentsOf: stop)
        hooks["beforeSubmitPrompt"] = before
        hooks.removeValue(forKey: "stop")
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        #expect(installer.installState() == .outdated)
    }

    @Test func installState_missingLifecyclePlacement_outdated() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = CursorInstaller(settingsURL: url)
        try await installer.install()

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "beforeSubmitPrompt")
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        #expect(installer.installState() == .outdated)
    }

    @Test func reinstall_removesLegacyExecutionHooks() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = CursorInstaller(settingsURL: url)
        try await installer.install()

        let legacyCommand = AlasHookCommand.compositeCommand(
            events: [.permissionRequest],
            agent: .cursor,
            forwardStdinAsBody: false,
            stdoutResponse: #"{"continue":true}"#
        )
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        let legacyEntry: [String: Any] = ["command": legacyCommand, "timeout": 10]
        hooks["beforeShellExecution"] = [legacyEntry]
        hooks["beforeMCPExecution"] = [legacyEntry]
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        #expect(installer.installState() == .outdated)

        try await installer.install()
        let reinstalled = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let reinstalledHooks = reinstalled["hooks"] as! [String: Any]
        #expect(reinstalledHooks["beforeShellExecution"] == nil)
        #expect(reinstalledHooks["beforeMCPExecution"] == nil)
        #expect(installer.installState() == .installed)
    }
}
