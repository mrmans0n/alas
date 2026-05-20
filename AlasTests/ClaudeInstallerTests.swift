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

        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let installedHooks = installed["hooks"] as! [String: Any]
        #expect(installedHooks["SessionStart"] != nil)
        #expect(installedHooks["SessionEnd"] != nil)
        #expect(installedHooks["PermissionRequest"] != nil)

        // Third-party entry survives
        var json = installed
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

    @Test func installState_missingLifecyclePlacement_outdated() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = ClaudeInstaller(settingsURL: url)
        try await installer.install()

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "SessionStart")
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        #expect(installer.installState() == .outdated)
    }

    /// Codex review (#102): Claude reuses the same `busy` command across
    /// UserPromptSubmit/PreToolUse/PostToolUse. A flat Set<String> compare
    /// would falsely report `.installed` when one of those placements is
    /// missing because the same command still exists elsewhere.
    @Test func installState_missingPlacement_outdated() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = ClaudeInstaller(settingsURL: url)
        try await installer.install()

        // Drop PostToolUse. `busy` still lives under UserPromptSubmit and
        // PreToolUse, so a set-based check would not notice. Per-event
        // compare must catch this.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "PostToolUse")
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        #expect(installer.installState() == .outdated)
    }

    /// Codex review (#102): a stale managed hook with the same command but
    /// an outdated matcher (e.g. an old empty Notification matcher that fires
    /// on every notification type) must report `.outdated` so the settings UI
    /// shows "Update" instead of "Reinstall".
    @Test func installState_outdatedMatcher_outdated() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = ClaudeInstaller(settingsURL: url)
        try await installer.install()

        // Tamper Notification's matcher to "" — simulating a pre-fix install.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        var notif = hooks["Notification"] as! [[String: Any]]
        notif[0]["matcher"] = ""
        hooks["Notification"] = notif
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        #expect(installer.installState() == .outdated)
    }

    /// Codex review (#102): if a Claude hook group contains both an Alas
    /// command and a user's own command in the same `hooks` array, uninstall
    /// must strip only the Alas entry — not drop the entire group.
    @Test func uninstall_preservesSiblingHookInSameGroup() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = ClaudeInstaller(settingsURL: url)
        try await installer.install()

        // Splice a user's third-party command into the SAME inner hooks
        // array Alas wrote for Stop.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        var stopEntries = hooks["Stop"] as! [[String: Any]]
        var inner = stopEntries[0]["hooks"] as! [[String: Any]]
        inner.append(["type": "command", "command": "/usr/local/bin/my-stop-hook"])
        stopEntries[0]["hooks"] = inner
        hooks["Stop"] = stopEntries
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        try installer.uninstall()

        let final = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let finalHooks = final["hooks"] as! [String: Any]
        let finalStop = finalHooks["Stop"] as! [[String: Any]]
        #expect(finalStop.count == 1)
        let cmds = finalStop[0]["hooks"] as! [[String: Any]]
        #expect(cmds.count == 1)
        #expect(cmds[0]["command"] as? String == "/usr/local/bin/my-stop-hook")
    }
}
