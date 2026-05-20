import Testing
import Foundation
@testable import Alas

struct GeminiInstallerTests {
    private func tmpSettingsURL() -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func installCreatesNestedHooksInEmptySettingsFile() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = GeminiInstaller(settingsURL: url)

        try await installer.install()

        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = installed["hooks"] as! [String: Any]
        #expect(Set(hooks.keys) == Set(["SessionStart", "SessionEnd", "BeforeAgent", "AfterTool", "AfterAgent"]))

        for event in ["SessionStart", "SessionEnd", "BeforeAgent", "AfterTool", "AfterAgent"] {
            let groups = hooks[event] as! [[String: Any]]
            #expect(groups.count == 1)
            let innerHooks = groups[0]["hooks"] as! [[String: Any]]
            #expect(innerHooks.count == 1)
            #expect(innerHooks[0]["type"] as? String == "command")
        }
    }

    @Test func hookCommandsAreManagedAndIncludeGeminiEventsAndStdoutResponse() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = GeminiInstaller(settingsURL: url)

        try await installer.install()

        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = installed["hooks"] as! [String: Any]
        let expectations: [String: String] = [
            "SessionStart": ActivityEvent.attached.rawValue,
            "SessionEnd": ActivityEvent.detached.rawValue,
            "BeforeAgent": ActivityEvent.busy.rawValue,
            "AfterTool": ActivityEvent.busy.rawValue,
            "AfterAgent": ActivityEvent.idle.rawValue,
        ]

        for (geminiEvent, alasEvent) in expectations {
            let groups = hooks[geminiEvent] as! [[String: Any]]
            let innerHooks = groups[0]["hooks"] as! [[String: Any]]
            let command = innerHooks[0]["command"] as! String
            #expect(command.hasSuffix(AlasHookCommand.ownershipSentinel))
            #expect(command.contains(#""agent":"gemini""#))
            #expect(command.contains(#""event":"\#(alasEvent)""#))
            #expect(command.contains(#"printf '%s\n' '{}'"#))
        }
    }

    @Test func installStateInstalledForFreshCanonicalConfig() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = GeminiInstaller(settingsURL: url)

        try await installer.install()

        #expect(installer.installState() == .installed)
    }

    @Test func installStateOutdatedWhenCanonicalPlacementMissing() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = GeminiInstaller(settingsURL: url)
        try await installer.install()

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "AfterTool")
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        #expect(installer.installState() == .outdated)
    }

    @Test func installStateOutdatedWhenCanonicalPlacementStale() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = GeminiInstaller(settingsURL: url)
        try await installer.install()

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        var groups = hooks["AfterAgent"] as! [[String: Any]]
        var innerHooks = groups[0]["hooks"] as! [[String: Any]]
        innerHooks[0]["command"] = "old-command # alas-managed-hook"
        groups[0]["hooks"] = innerHooks
        hooks["AfterAgent"] = groups
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: url)

        #expect(installer.installState() == .outdated)
    }

    @Test func uninstallRemovesManagedHooksAndPreservesUnmanagedHooksAndSettings() async throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let installer = GeminiInstaller(settingsURL: url)

        let seed: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "AfterAgent": [
                    [
                        "hooks": [
                            ["type": "command", "command": "/usr/local/bin/user-after-agent"],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: seed, options: .prettyPrinted).write(to: url)
        try await installer.install()

        try installer.uninstall()

        let final = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(final["theme"] as? String == "dark")
        let hooks = final["hooks"] as! [String: Any]
        let afterAgent = hooks["AfterAgent"] as! [[String: Any]]
        let innerHooks = afterAgent[0]["hooks"] as! [[String: Any]]
        #expect(innerHooks.count == 1)
        #expect(innerHooks[0]["command"] as? String == "/usr/local/bin/user-after-agent")
    }
}
