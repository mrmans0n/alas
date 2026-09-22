import AppKit
import Observation
import SwiftUI

/// AppKit inserts its own items into the system menus SwiftUI builds from
/// `Commands`: "Enter Full Screen" goes into View every time that menu opens,
/// and Dictation, Emoji & Symbols, AutoFill and Writing Tools go into Edit.
/// SwiftUI treats those foreign items as a reason to replace the menu's whole
/// item array with fresh `NSMenuItem`s on its next update, and updates happen
/// while a menu is open: focus-store changes and any observable read by the
/// commands body trigger one. On macOS 26 inserting into a live menu trips an
/// `NSRangeException` inside AppKit's table-backed menu (`NSContextMenuImpl`
/// keeps an item count and a row-height cache that go out of sync mid-insert),
/// and the app dies in `_crashOnException`.
///
/// Opting out of the automatic insertions keeps SwiftUI on its in-place diff
/// path. The items Alas still wants are declared in its commands instead; see
/// `SystemMenuItems`.
///
/// Only macOS 26 is known to hit this crash (`isAffectedOS`), so older
/// systems (`project.yml` supports back to macOS 15) keep AppKit's native
/// Dictation, AutoFill, and Writing Tools items rather than losing them for a
/// bug they can't hit.
enum AppKitMenuInjection {
    /// Computed rather than a stored constant: `[String: Any]` isn't `Sendable`,
    /// and a stored global would need to be, even though the value is fixed.
    static var optOutDefaults: [String: Any] {
        [
            // View: "Enter Full Screen", added by AppKit when the menu opens.
            "NSFullScreenMenuItemEverywhere": false,
            // Edit: added by AppKit at launch and again after every SwiftUI reset.
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
            "NSMenuDoesNotAutomaticallyInsertWritingToolsItems": true,
            "NSAutoFillSystemInsertMenuEnabled": false,
        ]
    }

    /// True only on the one OS known to crash on AppKit's automatic menu
    /// insertions; see the type-level doc comment.
    static var isAffectedOS: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    /// Must run before AppKit finishes launching; `AlasApp.init` is early
    /// enough. Safe and idempotent to call on every launch; a no-op on any
    /// OS other than the one known to be affected.
    ///
    /// Overrides `UserDefaults.argumentDomain` — the same domain command-line
    /// `-key value` arguments land in — rather than the app's own persistent
    /// domain. That domain outranks every other domain UserDefaults
    /// consults, including the app's own domain and the shared
    /// `NSGlobalDomain`, which `NSFullScreenMenuItemEverywhere` in
    /// particular is documented to be, as a systemwide toggle some users or
    /// MDM profiles set directly — so the opt-out always wins for readers.
    /// It is also purely in-memory for the current process, so nothing is
    /// ever written to disk: an existing app-domain or `NSGlobalDomain`
    /// value, however it got there, is left completely untouched underneath
    /// the override, and there is nothing to revert on an unaffected OS.
    static func applyOptOut(isAffectedOS: Bool = AppKitMenuInjection.isAffectedOS, in defaults: UserDefaults = .standard) {
        guard isAffectedOS else { return }
        var overrides = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for (key, value) in optOutDefaults {
            overrides[key] = value
        }
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
    }
}

/// SwiftUI-owned stand-ins for the AppKit items `AppKitMenuInjection` turns off.
enum SystemMenuItems {
    static let emojiAndSymbolsTitle = "Emoji & Symbols"
    static let emojiAndSymbolsShortcut = KeyboardShortcut(" ", modifiers: [.control, .command])
    static let fullScreenShortcut = KeyboardShortcut("f", modifiers: [.control, .command])

    static func fullScreenTitle(isFullScreen: Bool) -> String {
        isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
    }

    @MainActor
    static func showEmojiAndSymbols() {
        NSApplication.shared.orderFrontCharacterPalette(nil)
    }

    @MainActor
    static func toggleFullScreen() {
        NSApplication.shared.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
    }
}

/// Tracks whether the key window is in full screen so the View menu can offer
/// "Enter" or "Exit Full Screen" the way AppKit's automatic item did.
@MainActor
@Observable
final class FullScreenMenuState {
    private(set) var isKeyWindowFullScreen = false

    init(notificationCenter: NotificationCenter = .default) {
        let names: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        for name in names {
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        isKeyWindowFullScreen = NSApplication.shared.keyWindow?.styleMask.contains(.fullScreen) ?? false
    }
}
