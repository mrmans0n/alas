import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Guards the fix for the macOS 26 menu crash: SwiftUI rebuilds a system menu
/// from scratch, while it is open, whenever AppKit has slipped its own items
/// into it. The app opts out of those insertions and declares its own
/// replacements, so none of AppKit's items may appear in the built menus.
@MainActor
struct SystemMenuItemsTests {
    // `AlasApp.init` calls `applyOptOut()` unconditionally, but it only
    // enforces the opt-out (and the replacement commands only appear) when
    // `AppKitMenuInjection.isAffectedOS` is true; these four tests assert
    // what that produces on the real host, so they need the same
    // availability constraint macOS 26 implies.
    @available(macOS 26, *)
    @Test func appOptsOutOfEveryAutomaticMenuInsertion() {
        let defaults = UserDefaults.standard
        #expect(defaults.object(forKey: "NSFullScreenMenuItemEverywhere") as? Bool == false)
        #expect(defaults.object(forKey: "NSDisabledDictationMenuItem") as? Bool == true)
        #expect(defaults.object(forKey: "NSDisabledCharacterPaletteMenuItem") as? Bool == true)
        #expect(defaults.object(forKey: "NSMenuDoesNotAutomaticallyInsertWritingToolsItems") as? Bool == true)
        #expect(defaults.object(forKey: "NSAutoFillSystemInsertMenuEnabled") as? Bool == false)
        #expect(Set(AppKitMenuInjection.optOutDefaults.keys) == [
            "NSFullScreenMenuItemEverywhere",
            "NSDisabledDictationMenuItem",
            "NSDisabledCharacterPaletteMenuItem",
            "NSMenuDoesNotAutomaticallyInsertWritingToolsItems",
            "NSAutoFillSystemInsertMenuEnabled",
        ])
    }

    /// `register(defaults:)` is a no-op when the key already has a value in a
    /// higher-priority domain (the app's own, or the shared `NSGlobalDomain`
    /// some of these keys are documented to live in). `applyOptOut` must set
    /// the values directly so a pre-existing opposite value can't leave the
    /// crash-causing insertion enabled. Passing `isAffectedOS` explicitly
    /// keeps this independent of the real host's macOS version.
    @Test func applyOptOutOverridesAnExistingOppositeValueOnAnAffectedOS() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for key in AppKitMenuInjection.optOutDefaults.keys {
            defaults.set(true, forKey: key)
        }
        defaults.set(false, forKey: "NSDisabledDictationMenuItem")

        AppKitMenuInjection.applyOptOut(isAffectedOS: true, in: defaults)

        for (key, expected) in AppKitMenuInjection.optOutDefaults {
            #expect(defaults.object(forKey: key) as? Bool == expected as? Bool, "key: \(key)")
        }
    }

    /// A prior launch on an affected OS can persist these keys into the
    /// app's own preferences domain. `#available` alone would only stop
    /// *reapplying* them on an unaffected system (e.g. after a downgrade, or
    /// a preferences restore onto an older Mac); the values would otherwise
    /// survive and keep suppressing AppKit's native items even though the
    /// replacement commands are also gone. `applyOptOut` must actively clean
    /// them up instead.
    @Test func applyOptOutRemovesAnyPersistedValueOnAnUnaffectedOS() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for (key, value) in AppKitMenuInjection.optOutDefaults {
            defaults.set(value, forKey: key)
        }

        AppKitMenuInjection.applyOptOut(isAffectedOS: false, in: defaults)

        for key in AppKitMenuInjection.optOutDefaults.keys {
            #expect(defaults.object(forKey: key) == nil, "key: \(key)")
        }
    }

    private func isolatedDefaults(function: String = #function) throws -> (UserDefaults, suiteName: String) {
        let suiteName = "io.nlopez.alas.tests.SystemMenuItemsTests.\(function)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @available(macOS 26, *)
    @Test func editMenuCarriesOnlySwiftUIOwnedItems() throws {
        let titles = try #require(mainMenu(titled: "Edit")).items.map(\.title)
        #expect(!titles.contains("Start Dictation…"))
        #expect(!titles.contains("AutoFill"))
        #expect(!titles.contains("Writing Tools"))
        #expect(titles.filter { $0 == SystemMenuItems.emojiAndSymbolsTitle }.count == 1)
    }

    @available(macOS 26, *)
    @Test func viewMenuOwnsItsFullScreenItem() throws {
        let items = try #require(mainMenu(titled: "View")).items.filter { $0.title.hasSuffix("Full Screen") }
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.keyEquivalent == "f")
        #expect(item.keyEquivalentModifierMask == [.control, .command])
    }

    @Test func fullScreenTitleFollowsTheWindowState() {
        #expect(SystemMenuItems.fullScreenTitle(isFullScreen: false) == "Enter Full Screen")
        #expect(SystemMenuItems.fullScreenTitle(isFullScreen: true) == "Exit Full Screen")
    }

    private func mainMenu(titled title: String) -> NSMenu? {
        NSApplication.shared.mainMenu?.items.first { $0.title == title }?.submenu
    }
}
