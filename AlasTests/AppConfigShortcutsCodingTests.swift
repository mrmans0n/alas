import Testing
import Foundation
@testable import Alas

struct AppConfigShortcutsCodingTests {
    @Test func defaultsHaveEmptyOverrides() {
        #expect(AppConfig.defaults.shortcutOverrides.isEmpty)
    }

    @Test func oldConfigWithoutOverridesDecodesToEmpty() throws {
        let original = AppConfig.defaults
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)
        ) as! [String: Any]
        dict.removeValue(forKey: "shortcutOverrides")
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.shortcutOverrides.isEmpty)
    }

    @Test func roundTripWithOverrides() throws {
        var cfg = AppConfig.defaults
        cfg.shortcutOverrides = [
            ShortcutAction.searchFiles.rawValue: ShortcutBinding(key: "o", modifiers: [.command]),
            ShortcutAction.switchRepository.rawValue: nil,
        ]
        let data = try JSONEncoder().encode(cfg)
        // Verify the explicit-nil reaches JSON as `null` (not stripped).
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let overrides = json["shortcutOverrides"] as! [String: Any]
        #expect(overrides["switchRepository"] is NSNull,
                "explicit-nil override must serialize as JSON null, not be dropped")
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.shortcutOverrides[ShortcutAction.searchFiles.rawValue] ==
                .some(ShortcutBinding(key: "o", modifiers: [.command])))
        // explicit-nil round-trips as Optional<Binding>.none stored under the key
        #expect(decoded.shortcutOverrides.keys.contains(ShortcutAction.switchRepository.rawValue))
        #expect(decoded.shortcutOverrides[ShortcutAction.switchRepository.rawValue] == .some(nil))
    }

    @Test func migratesLegacyFindAndReplaceOverrideToReplaceAction() throws {
        var cfg = AppConfig.defaults
        let custom = ShortcutBinding(key: "j", modifiers: [.command, .option])
        cfg.shortcutOverrides = [
            ShortcutAction.findAndReplace.rawValue: custom
        ]

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.shortcutOverrides[ShortcutAction.replaceInEditor.rawValue] == .some(custom))
        #expect(decoded.shortcutOverrides[ShortcutAction.findAndReplace.rawValue] == nil)
    }

    @Test func dropsLegacyFindOverrideWhenItCollidesWithNewFindDefault() throws {
        var cfg = AppConfig.defaults
        cfg.shortcutOverrides = [
            ShortcutAction.findAndReplace.rawValue: ShortcutAction.findAndReplace.defaultBinding
        ]

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.shortcutOverrides[ShortcutAction.replaceInEditor.rawValue] == nil)
        #expect(decoded.shortcutOverrides[ShortcutAction.findAndReplace.rawValue] == nil)
    }

    @Test func preservesExplicitNewReplaceOverrideDuringFindMigration() throws {
        var cfg = AppConfig.defaults
        let legacy = ShortcutBinding(key: "j", modifiers: [.command, .option])
        let replacement = ShortcutBinding(key: "r", modifiers: [.command, .option])
        cfg.shortcutOverrides = [
            ShortcutAction.findAndReplace.rawValue: legacy,
            ShortcutAction.replaceInEditor.rawValue: replacement,
        ]

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.shortcutOverrides[ShortcutAction.replaceInEditor.rawValue] == .some(replacement))
        #expect(decoded.shortcutOverrides[ShortcutAction.findAndReplace.rawValue] == .some(legacy))
    }

    @Test func migratesLegacyFindAndReplaceUnbindToReplaceAction() throws {
        var cfg = AppConfig.defaults
        cfg.shortcutOverrides = [
            ShortcutAction.findAndReplace.rawValue: nil
        ]

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.shortcutOverrides.keys.contains(ShortcutAction.replaceInEditor.rawValue))
        #expect(decoded.shortcutOverrides[ShortcutAction.replaceInEditor.rawValue] == .some(nil))
        #expect(decoded.shortcutOverrides[ShortcutAction.findAndReplace.rawValue] == nil)
    }

    @Test func migratesLegacyAgentLauncherOverridesToSplitActions() throws {
        var cfg = AppConfig.defaults
        let legacyLauncher = ShortcutBinding(key: "j", modifiers: [.command, .option])
        let legacyChat = ShortcutBinding(key: "k", modifiers: [.command, .option, .shift])
        cfg.shortcutOverrides = [
            "launchAgentTerminal": legacyLauncher,
            "launchAgentChat": legacyChat,
        ]

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.shortcutOverrides[ShortcutAction.launchAgent.rawValue] == .some(legacyLauncher))
        #expect(decoded.shortcutOverrides[ShortcutAction.launchAgentInChat.rawValue] == .some(legacyChat))
        #expect(decoded.shortcutOverrides[ShortcutAction.launchAgentInTerminal.rawValue] == nil)
        #expect(decoded.shortcutOverrides["launchAgentTerminal"] == nil)
        #expect(decoded.shortcutOverrides["launchAgentChat"] == nil)
    }

    @Test func dropsLegacyAgentLauncherOverridesThatRestateOldDefaults() throws {
        var cfg = AppConfig.defaults
        cfg.shortcutOverrides = [
            "launchAgentTerminal": ShortcutBinding(key: "t", modifiers: [.command, .option]),
            "launchAgentChat": ShortcutBinding(key: "t", modifiers: [.command, .option, .shift]),
        ]

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.shortcutOverrides.isEmpty)
        #expect(ShortcutAction.launchAgentInChat.defaultBinding ==
                ShortcutBinding(key: "c", modifiers: [.command, .option, .shift]))
    }

    @Test func dropsOverridesThatCollideWithReservedBindingsOnDecode() throws {
        var cfg = AppConfig.defaults
        let preserved = ShortcutBinding(key: "j", modifiers: [.command, .option])
        cfg.shortcutOverrides = [
            ShortcutAction.searchFiles.rawValue: ShortcutBinding(key: "t", modifiers: [.command, .shift]),
            ShortcutAction.switchRepository.rawValue: nil,
            ShortcutAction.toggleRightPane.rawValue: preserved,
        ]

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.shortcutOverrides[ShortcutAction.searchFiles.rawValue] == nil)
        #expect(decoded.shortcutOverrides.keys.contains(ShortcutAction.switchRepository.rawValue))
        #expect(decoded.shortcutOverrides[ShortcutAction.switchRepository.rawValue] == .some(nil))
        #expect(decoded.shortcutOverrides[ShortcutAction.toggleRightPane.rawValue] == .some(preserved))
    }
}
