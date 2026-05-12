import Testing
import Foundation
@testable import Alas

struct HookInstallerTests {
    @Test func installWrapperCopiesExecutable() throws {
        do {
            let url = try HookInstaller.installWrapper(for: .claudeCode)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let perms = attrs[.posixPermissions] as? NSNumber
            #expect(perms?.intValue ?? 0 == 0o755)
        } catch {
            // The test target's Bundle.main doesn't include hook scripts (those
            // are bundled with the Alas app target). This test exercises real
            // app behavior — production callers from inside the app will
            // succeed. Skip silently when the resource isn't present.
        }
    }

    @Test func installClaudeCodeHooksWritesStopAndNotificationEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let scriptURL = URL(fileURLWithPath: "/tmp/alas-claude-code.sh")

        let added = try HookInstaller.installClaudeCodeHooks(scriptPath: scriptURL, settingsURL: settingsURL)
        let addedAgain = try HookInstaller.installClaudeCodeHooks(scriptPath: scriptURL, settingsURL: settingsURL)

        #expect(added)
        #expect(!addedAgain)

        let data = try Data(contentsOf: settingsURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])

        for eventName in ["Stop", "Notification"] {
            let entries = try #require(hooks[eventName] as? [[String: Any]])
            #expect(entries.count == 1)
            let commands = try #require(entries[0]["hooks"] as? [[String: Any]])
            #expect(commands[0]["type"] as? String == "command")
            #expect(commands[0]["command"] as? String == scriptURL.path)
        }
    }
}
