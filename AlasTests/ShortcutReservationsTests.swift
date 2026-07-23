import AppKit
import Testing
@testable import Alas

@MainActor
struct ShortcutReservationsTests {
    // Tests use `snapshot(from:)` (pure) so they don't depend on or pollute
    // the global registry — Swift Testing runs suites in parallel and the
    // production `update(from:)` path is shared with other suites.

    @Test func defaultsIncludeActionDefaults() {
        let reserved = ShortcutReservations.defaultReserved
        #expect(reserved.contains(ShortcutAction.searchFiles.defaultBinding))
        #expect(reserved.contains(ShortcutAction.newTerminalTab.defaultBinding))
        #expect(reserved.contains(ShortcutAction.resetFontSize.defaultBinding))
    }

    @Test func cmdRIsReservedForRunScript() {
        #expect(ShortcutReservations.defaultReserved.contains(.init(key: "r", modifiers: [.command])))
    }

    @Test func defaultsIncludeStandardsAndTabSwitchers() {
        let reserved = ShortcutReservations.defaultReserved
        // ⌘W (Close Tab) and ⌘1..⌘9 stay reserved regardless of rebinds.
        #expect(reserved.contains(ShortcutBinding(key: "w", modifiers: [.command])))
        #expect(reserved.contains(ShortcutBinding(key: "1", modifiers: [.command])))
        #expect(reserved.contains(ShortcutBinding(key: "9", modifiers: [.command])))
    }

    @Test func defaultsExcludeCodeEditorAndComposerScopedActions() {
        // These actions have no responder when the terminal is focused, so
        // reserving them would swallow the keystroke. Pass through to the
        // shell instead.
        let reserved = ShortcutReservations.defaultReserved
        #expect(!reserved.contains(ShortcutAction.splitSelectionIntoLines.defaultBinding))
        #expect(!reserved.contains(ShortcutAction.toggleMarkdownPreview.defaultBinding))
        #expect(!reserved.contains(ShortcutAction.commitInComposer.defaultBinding))
        #expect(!reserved.contains(ShortcutAction.findAndReplace.defaultBinding))
    }

    @Test func snapshotKeepsScopedActionsOutEvenWhenOverridden() {
        // Rebinding a code-editor-scoped action to a new combo must NOT add
        // that combo to the reserved set — the terminal still wants it.
        var config = AppConfig.defaults
        config.shortcutOverrides[ShortcutAction.toggleMarkdownPreview.rawValue] =
            .some(ShortcutBinding(key: "j", modifiers: [.command, .shift]))

        let reserved = ShortcutReservations.snapshot(from: config)
        #expect(!reserved.contains(ShortcutBinding(key: "j", modifiers: [.command, .shift])))
    }

    @Test func snapshotMovesReservationWhenOverridden() {
        // Rebind Search Files: ⌘P → ⌘O. The terminal should reserve ⌘O and
        // free ⌘P.
        var config = AppConfig.defaults
        config.shortcutOverrides[ShortcutAction.searchFiles.rawValue] =
            .some(ShortcutBinding(key: "o", modifiers: [.command]))

        let reserved = ShortcutReservations.snapshot(from: config)
        #expect(reserved.contains(ShortcutBinding(key: "o", modifiers: [.command])))
        #expect(!reserved.contains(ShortcutBinding(key: "p", modifiers: [.command])))
    }

    @Test func snapshotDropsExplicitUnbinds() {
        // Explicit unbind: ⌘P no longer reserved.
        var config = AppConfig.defaults
        config.shortcutOverrides[ShortcutAction.searchFiles.rawValue] = .some(nil)

        let reserved = ShortcutReservations.snapshot(from: config)
        #expect(!reserved.contains(ShortcutBinding(key: "p", modifiers: [.command])))
        // Other defaults still reserved.
        #expect(reserved.contains(ShortcutAction.newTerminalTab.defaultBinding))
    }

    @Test func surfaceViewHonorsDynamicReservation() throws {
        // The explicit-set overload lets us prove integration without
        // touching the global registry.
        var config = AppConfig.defaults
        config.shortcutOverrides[ShortcutAction.searchFiles.rawValue] =
            .some(ShortcutBinding(key: "o", modifiers: [.command]))
        let reserved = ShortcutReservations.snapshot(from: config)

        let cmdO = try keyEvent(characters: "o", ignoringModifiers: "o",
                                modifiers: .command, keyCode: 31)
        let cmdP = try keyEvent(characters: "p", ignoringModifiers: "p",
                                modifiers: .command, keyCode: 35)

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(cmdO, in: reserved))
        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(cmdP, in: reserved))
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        characters: String,
        ignoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
        return try #require(event)
    }
}
