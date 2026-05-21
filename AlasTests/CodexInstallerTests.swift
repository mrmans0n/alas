import Testing
import Foundation
@testable import Alas

struct CodexInstallerTests {
    private func tmpDir() -> (dir: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func installState_noFile_notInstalled() {
        let installer = CodexInstaller(
            hooksURL: URL(fileURLWithPath: "/nonexistent/hooks.json"),
            configURL: URL(fileURLWithPath: "/nonexistent/config.toml"),
            runEnableHooks: { .init(status: 0, stderr: "") }
        )
        #expect(installer.installState() == .notInstalled)
    }

    @Test func installRoundTrip() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        let configURL = dir.appendingPathComponent("config.toml")
        try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)

        var enableCalled = false
        let installer = CodexInstaller(
            hooksURL: hooksURL, configURL: configURL,
            runEnableHooks: { enableCalled = true
            return .init(status: 0, stderr: "") }
        )

        try await installer.install()
        #expect(enableCalled)
        #expect(installer.installState() == .installed)

        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        let installedHooks = installed["hooks"] as! [String: Any]
        #expect(installedHooks["SessionStart"] != nil)
        #expect(installedHooks["SessionEnd"] != nil)

        try installer.uninstall()
        #expect(installer.installState() == .notInstalled)
    }

    @Test func installState_missingLifecyclePlacement_outdated() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        let configURL = dir.appendingPathComponent("config.toml")
        try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)

        let installer = CodexInstaller(
            hooksURL: hooksURL, configURL: configURL,
            runEnableHooks: { .init(status: 0, stderr: "") }
        )
        try await installer.install()

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "SessionEnd")
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: hooksURL)

        #expect(installer.installState() == .outdated)
    }

    /// Codex review (#102): a stale install with the right managed commands
    /// under the wrong event keys (e.g. Stop's command sitting under
    /// UserPromptSubmit) must report `.outdated` so the user can fix it.
    @Test func installState_commandsUnderWrongEventKeys_outdated() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        let configURL = dir.appendingPathComponent("config.toml")
        try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)

        let installer = CodexInstaller(
            hooksURL: hooksURL, configURL: configURL,
            runEnableHooks: { .init(status: 0, stderr: "") }
        )
        try await installer.install()

        // Swap: move Stop's command alongside UserPromptSubmit, drop Stop.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        var prompt = hooks["UserPromptSubmit"] as! [[String: Any]]
        prompt.append(contentsOf: stop)
        hooks["UserPromptSubmit"] = prompt
        hooks.removeValue(forKey: "Stop")
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: hooksURL)

        #expect(installer.installState() == .outdated)
    }

    /// Codex review (#102): `hasFeaturesFlag` must match only the top-level
    /// `[features]` table, not `[profile.features]` or `[features_experimental]`.
    /// Otherwise an install seems "installed" without the real flag, and
    /// uninstall would delete the flag from an unrelated table.
    @Test func installState_unrelatedFeaturesTable_outdated() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        let configURL = dir.appendingPathComponent("config.toml")
        // The real [features] table is absent; only an unrelated table sets
        // hooks = true. Without strict matching this would pass the flag check.
        try """
        [profile.features]
        hooks = true
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let installer = CodexInstaller(
            hooksURL: hooksURL, configURL: configURL,
            runEnableHooks: { .init(status: 0, stderr: "") }
        )
        try await installer.install()
        // hooksByEvent now lives in hooks.json, but no [features].hooks flag
        // → installState should report .outdated rather than .installed.
        #expect(installer.installState() == .outdated)
    }

    @Test func uninstall_preservesUnrelatedFeaturesTable() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        let configURL = dir.appendingPathComponent("config.toml")
        let original = """
        [features]
        hooks = true

        [features_experimental]
        hooks = true
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let installer = CodexInstaller(
            hooksURL: hooksURL, configURL: configURL,
            runEnableHooks: { .init(status: 0, stderr: "") }
        )
        try await installer.install()
        try installer.uninstall()

        let after = try String(contentsOf: configURL, encoding: .utf8)
        #expect(!after.contains("[features]\nhooks = true"))
        #expect(after.contains("[features_experimental]"))
        #expect(after.range(of: #"\[features_experimental\]\s*\nhooks = true"#, options: .regularExpression) != nil)
    }

    @Test func install_codexUnavailable_throws() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let installer = CodexInstaller(
            hooksURL: dir.appendingPathComponent("hooks.json"),
            configURL: dir.appendingPathComponent("config.toml"),
            runEnableHooks: { .init(status: 127, stderr: "") }
        )

        await #expect(throws: CodexInstallerError.self) {
            try await installer.install()
        }
    }
}
