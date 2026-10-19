import Testing
import Foundation
@testable import Alas

struct CodexInstallerTests {
    private func tmpDir() -> (dir: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    /// Stands in for `codex app-server`: records trust for every Alas handler
    /// at its current position, keyed the way Codex keys `hooks.state`.
    private static func recordTrust(configURL: URL) -> @Sendable (URL, Set<String>) async throws -> Void {
        { hooksURL, commands in
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
            let path = CodexHookTrust.canonicalPath(hooksURL)
            var toml = try String(contentsOf: configURL, encoding: .utf8)
            for (event, value) in json["hooks"] as! [String: Any] {
                let snake = event.reduce(into: "") { s, c in
                    if c.isUppercase, !s.isEmpty { s.append("_") }
                    s.append(c.lowercased())
                }
                for (g, group) in (value as! [[String: Any]]).enumerated() {
                    for (h, handler) in ((group["hooks"] as? [[String: Any]]) ?? []).enumerated()
                    where commands.contains(handler["command"] as? String ?? "") {
                        toml += "\n[hooks.state.\"\(path):\(snake):\(g):\(h)\"]\ntrusted_hash = \"sha256:x\"\n"
                    }
                }
            }
            try toml.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    private func makeInstaller(dir: URL) throws -> CodexInstaller {
        let configURL = dir.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        }
        return CodexInstaller(
            hooksURL: dir.appendingPathComponent("hooks.json"), configURL: configURL,
            runEnableHooks: { .init(status: 0, stderr: "") },
            trustHooks: Self.recordTrust(configURL: configURL)
        )
    }

    @Test func installState_noFile_notInstalled() {
        let installer = CodexInstaller(
            hooksURL: URL(fileURLWithPath: "/nonexistent/hooks.json"),
            configURL: URL(fileURLWithPath: "/nonexistent/config.toml"),
            runEnableHooks: { .init(status: 0, stderr: "") },
            trustHooks: { _, _ in }
        )
        #expect(installer.installState() == .notInstalled)
    }

    @Test func installRoundTrip() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        let configURL = dir.appendingPathComponent("config.toml")
        try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)

        let enableCalled = CodexInstallerCallFlag()
        let installer = CodexInstaller(
            hooksURL: hooksURL, configURL: configURL,
            runEnableHooks: { enableCalled.mark()
            return .init(status: 0, stderr: "") },
            trustHooks: Self.recordTrust(configURL: configURL)
        )

        try await installer.install()
        #expect(enableCalled.wasCalled)
        #expect(installer.installState() == .installed)

        // Codex only runs handlers nested in a matcher group's `hooks` array.
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        let installedHooks = installed["hooks"] as! [String: Any]
        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"] {
            let groups = try #require(installedHooks[event] as? [[String: Any]])
            let handlers = try #require(groups.first?["hooks"] as? [[String: Any]])
            #expect(handlers.first?["type"] as? String == "command")
        }

        try installer.uninstall()
        #expect(installer.installState() == .notInstalled)
    }

    /// Alas used to write handlers straight under the event key, which Codex
    /// parses as empty matcher groups and never runs. Such an install must
    /// read as outdated, and updating it must drop the dead entries while
    /// keeping other tools' hooks.
    @Test func install_replacesLegacyFlatEntries() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let installer = try makeInstaller(dir: dir)
        let legacyCommand = "true # alas-managed-hook"
        let thirdParty: [String: Any] = ["hooks": [["type": "command", "command": "third-party-notify"]]]
        let legacy: [String: Any] = ["hooks": [
            "UserPromptSubmit": [["command": legacyCommand, "timeout": 10], thirdParty],
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: installer.hooksURL)
        #expect(installer.installState() == .outdated)

        try await installer.install()

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.hooksURL)) as! [String: Any]
        let prompt = (json["hooks"] as! [String: Any])["UserPromptSubmit"] as! [[String: Any]]
        #expect(!prompt.contains { $0["command"] as? String == legacyCommand })
        #expect(prompt.contains { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == "third-party-notify" })
        #expect(installer.installState() == .installed)
    }

    enum TrustInvalidatingEdit: CaseIterable, Sendable {
        /// Codex keys trust by position, so a hook inserted ahead of Alas's
        /// moves it to a key nobody has trusted.
        case hookInsertedAhead
        /// Codex hashes the whole group, so a changed timeout or added
        /// matcher leaves the stored hash stale and the hook "modified".
        case timeoutChanged
        case matcherAdded
    }

    /// Each edit makes Codex skip the Alas hook, so Alas must offer an update.
    @Test(arguments: TrustInvalidatingEdit.allCases)
    func installState_trustInvalidatingEdit_outdated(_ edit: TrustInvalidatingEdit) async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let installer = try makeInstaller(dir: dir)
        try await installer.install()
        #expect(installer.installState() == .installed)

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.hooksURL)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        var prompt = hooks["UserPromptSubmit"] as! [[String: Any]]
        switch edit {
        case .hookInsertedAhead:
            prompt.insert(["hooks": [["type": "command", "command": "other"]]], at: 0)
        case .timeoutChanged:
            var handlers = prompt[0]["hooks"] as! [[String: Any]]
            handlers[0]["timeout"] = 30
            prompt[0]["hooks"] = handlers
        case .matcherAdded:
            prompt[0]["matcher"] = "*"
        }
        hooks["UserPromptSubmit"] = prompt
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json).write(to: installer.hooksURL)

        #expect(installer.installState() == .outdated)
    }

    @Test func untrustedManagedHooks_onlyAlasHooksFromUserFile() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        try Data("{}".utf8).write(to: hooksURL)
        let projectURL = dir.appendingPathComponent("project-hooks.json")
        try Data("{}".utf8).write(to: projectURL)
        let alas = "printf busy # alas-managed-hook"
        func hook(_ key: String, _ command: String, _ source: URL, _ status: String) -> CodexListedHook {
            CodexListedHook(key: key, command: command, sourcePath: source.path, currentHash: "h-\(key)", trustStatus: status)
        }

        let pending = CodexHookTrust.untrustedManagedHooks(
            in: [
                hook("pending", alas, hooksURL, "untrusted"),
                hook("modified", alas, hooksURL, "modified"),
                hook("done", alas, hooksURL, "trusted"),
                hook("foreign", "other # alas-managed-hook", hooksURL, "untrusted"),
                hook("project", alas, projectURL, "untrusted"),
            ],
            hooksURL: hooksURL, commands: [alas]
        )

        #expect(pending.map(\.key) == ["pending", "modified"])
    }

    @Test func installState_missingLifecyclePlacement_outdated() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        let configURL = dir.appendingPathComponent("config.toml")
        try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)

        let installer = CodexInstaller(
            hooksURL: hooksURL, configURL: configURL,
            runEnableHooks: { .init(status: 0, stderr: "") },
            trustHooks: { _, _ in }
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
            runEnableHooks: { .init(status: 0, stderr: "") },
            trustHooks: { _, _ in }
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
            runEnableHooks: { .init(status: 0, stderr: "") },
            trustHooks: { _, _ in }
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
            runEnableHooks: { .init(status: 0, stderr: "") },
            trustHooks: { _, _ in }
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
            runEnableHooks: { .init(status: 127, stderr: "") },
            trustHooks: { _, _ in }
        )

        await #expect(throws: CodexInstallerError.self) {
            try await installer.install()
        }
    }
}

/// Records whether a `@Sendable` installer callback fired. Lock-backed rather
/// than a captured `var` because the callback may run off the test's own task.
/// Invariant: `flag` is read and written only while `lock` is held.
private final class CodexInstallerCallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func mark() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
