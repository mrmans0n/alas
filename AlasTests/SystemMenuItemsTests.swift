import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Guards the fix for the macOS 26 menu crash: SwiftUI rebuilds a system menu
/// from scratch, while it is open, whenever AppKit has slipped its own items
/// into it. The app opts out of those insertions and declares its own
/// replacements, so none of AppKit's items may appear in the built menus.
///
/// `.serialized`: several tests below mutate `UserDefaults.argumentDomain`,
/// which — unlike every other UserDefaults domain — is process-global rather
/// than per-instance (confirmed empirically: overriding it through one
/// `UserDefaults(suiteName:)` instance is visible through every other
/// instance, `.standard` included). Running them concurrently would race.
@MainActor
@Suite(.serialized)
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

    /// A plain `set(forKey:)` into the app's own domain would be a no-op
    /// against a value already present in a higher-priority domain (the
    /// app's own persisted value, or the shared `NSGlobalDomain` some of
    /// these keys are documented to live in). `applyOptOut` overrides
    /// `UserDefaults.argumentDomain` instead, which outranks both, so a
    /// pre-existing opposite value can never leave the crash-causing
    /// insertion enabled. Passing `isAffectedOS` explicitly keeps this
    /// independent of the real host's macOS version.
    @Test func applyOptOutOverridesAnExistingOppositeValueOnAnAffectedOS() throws {
        try withRestoredArgumentDomain {
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
    }

    /// The override must win for readers without destroying what it's
    /// overriding: it lands in the non-persistent `UserDefaults.argumentDomain`,
    /// so the pre-existing persisted value underneath — whether Alas wrote it
    /// on a prior affected-OS launch, a user set it explicitly, or an MDM
    /// profile did — survives on disk exactly as it was.
    @Test func applyOptOutNeverTouchesThePersistedValueUnderneath() throws {
        try withRestoredArgumentDomain {
            let (defaults, suiteName) = try isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(true, forKey: "NSFullScreenMenuItemEverywhere")

            AppKitMenuInjection.applyOptOut(isAffectedOS: true, in: defaults)

            #expect(defaults.object(forKey: "NSFullScreenMenuItemEverywhere") as? Bool == false)
            #expect(defaults.persistentDomain(forName: suiteName)?["NSFullScreenMenuItemEverywhere"] as? Bool == true)
        }
    }

    /// On an unaffected OS `applyOptOut` must be a strict no-op: it must not
    /// touch, remove, or shadow a pre-existing value for any of these keys,
    /// whatever its origin. This test host is itself the real Alas app, so
    /// on an actual macOS 26 machine `AlasApp.init`'s own launch-time
    /// `applyOptOut()` call has already installed the real, unrelated
    /// override globally before this test runs; clear it first so "no
    /// override present" is genuinely being exercised.
    @Test func applyOptOutDoesNothingOnAnUnaffectedOS() throws {
        try withRestoredArgumentDomain {
            UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            let (defaults, suiteName) = try isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(true, forKey: "NSFullScreenMenuItemEverywhere")

            AppKitMenuInjection.applyOptOut(isAffectedOS: false, in: defaults)

            #expect(defaults.object(forKey: "NSFullScreenMenuItemEverywhere") as? Bool == true)
            for key in AppKitMenuInjection.optOutDefaults.keys where key != "NSFullScreenMenuItemEverywhere" {
                #expect(defaults.object(forKey: key) == nil, "key: \(key)")
            }
        }
    }

    private func isolatedDefaults(function: String = #function) throws -> (UserDefaults, suiteName: String) {
        let suiteName = "io.nlopez.alas.tests.SystemMenuItemsTests.\(function)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    /// `UserDefaults.argumentDomain` is process-global — shared by every
    /// `UserDefaults` instance, `.standard` included — and, on an actual
    /// macOS 26 test host, already carries the real app's own launch-time
    /// override. Snapshot and restore it around any test that needs to
    /// mutate it, so tests neither race each other nor leak state into the
    /// rest of this process's test run.
    private func withRestoredArgumentDomain<T>(_ body: () throws -> T) rethrows -> T {
        let snapshot = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(snapshot, forName: UserDefaults.argumentDomain) }
        return try body()
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
