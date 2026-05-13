import Testing
import Foundation
@testable import Alas

struct LegacyHookSweepTests {
    private func tmpSettingsURL() -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func removesLegacyHookEntries() throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let home = "/Users/testuser"
        let legacy: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "\(home)/.alas/hooks/claude-code.sh"]]],
                    ["hooks": [["type": "command", "command": "/usr/local/bin/my-hook"]]],
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacy, options: .prettyPrinted).write(to: url)

        LegacyHookSweep.sweep(settingsURL: url, alasHooksPrefix: "\(home)/.alas/hooks/")

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        #expect(stop.count == 1)
        let cmds = stop[0]["hooks"] as! [[String: Any]]
        #expect(cmds[0]["command"] as? String == "/usr/local/bin/my-hook")
    }

    @Test func noopWhenNoLegacyEntries() throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-hook"]]]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted)
        try data.write(to: url)
        let before = try Data(contentsOf: url)

        LegacyHookSweep.sweep(settingsURL: url, alasHooksPrefix: "/Users/test/.alas/hooks/")

        let after = try Data(contentsOf: url)
        #expect(before == after)
    }

    /// Codex review (#102): a legacy command sharing a Claude-style `hooks`
    /// array with a user's own command must not take down the whole group on
    /// sweep — strip only the legacy entry.
    @Test func preservesUserHooksInSameGroupAsLegacyEntry() throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let home = "/Users/testuser"
        let mixed: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "\(home)/.alas/hooks/claude-code.sh"],
                            ["type": "command", "command": "/usr/local/bin/my-hook"],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: mixed, options: .prettyPrinted).write(to: url)

        LegacyHookSweep.sweep(settingsURL: url, alasHooksPrefix: "\(home)/.alas/hooks/")

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        #expect(stop.count == 1)
        let inner = stop[0]["hooks"] as! [[String: Any]]
        #expect(inner.count == 1)
        #expect(inner[0]["command"] as? String == "/usr/local/bin/my-hook")
    }

    /// Codex review (#102): the legacy prefix is the literal directory
    /// `~/.alas/hooks/` — a sibling path like `~/.alas/hooks-backup/...`
    /// must not be swept. With the old non-separator-aware hasPrefix check,
    /// the user's manual `hooks-backup` command would be deleted on launch.
    @Test func doesNotSweepSiblingDirectories() throws {
        let (url, cleanup) = tmpSettingsURL()
        defer { cleanup() }
        let home = "/Users/testuser"
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "\(home)/.alas/hooks-backup/my-hook"]]],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted)
        try data.write(to: url)
        let before = try Data(contentsOf: url)

        LegacyHookSweep.sweep(settingsURL: url, alasHooksPrefix: "\(home)/.alas/hooks/")

        let after = try Data(contentsOf: url)
        #expect(before == after)
    }

    @Test func noopWhenFileMissing() {
        LegacyHookSweep.sweep(
            settingsURL: URL(fileURLWithPath: "/nonexistent/settings.json"),
            alasHooksPrefix: "/Users/test/.alas/hooks/"
        )
        // No crash — that's the assertion.
    }
}
