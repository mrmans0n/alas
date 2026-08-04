import AppKit
import Testing
@testable import Alas

@MainActor
struct SurfaceViewShortcutTests {
    // Tests pass `ShortcutReservations.defaultReserved` explicitly so they
    // don't depend on the global registry (other suites mutate it under
    // parallel test execution).

    @Test func commandTIsReservedForAppCommand() throws {
        let event = try keyEvent(
            characters: "t",
            ignoringModifiers: "t",
            modifiers: .command,
            keyCode: 17
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandTAllowsCapsLock() throws {
        let event = try keyEvent(
            characters: "T",
            ignoringModifiers: "t",
            modifiers: [.command, .capsLock],
            keyCode: 17
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandShiftTIsReservedForReopenClosedTab() throws {
        let event = try keyEvent(
            characters: "T",
            ignoringModifiers: "t",
            modifiers: [.command, .shift],
            keyCode: 17
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandDigitOneIsReservedForAppCommand() throws {
        let event = try keyEvent(
            characters: "1",
            ignoringModifiers: "1",
            modifiers: .command,
            keyCode: 18
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandDigitNineIsReservedForAppCommand() throws {
        let event = try keyEvent(
            characters: "9",
            ignoringModifiers: "9",
            modifiers: .command,
            keyCode: 25
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandDigitAllowsCapsLock() throws {
        let event = try keyEvent(
            characters: "1",
            ignoringModifiers: "1",
            modifiers: [.command, .capsLock],
            keyCode: 18
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func modifiedCommandDigitIsNotReserved() throws {
        let event = try keyEvent(
            characters: "!",
            ignoringModifiers: "1",
            modifiers: [.command, .shift],
            keyCode: 18
        )

        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandZeroIsReservedForFontReset() throws {
        // ⌘0 is the default binding for Reset Font Size — when the terminal
        // pane is focused, the menu's action handler routes through the
        // FontSizeResponder chain and resets the surface's font size.
        let event = try keyEvent(
            characters: "0",
            ignoringModifiers: "0",
            modifiers: .command,
            keyCode: 29
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func otherCommandKeysAreNotReserved() throws {
        // Cmd+E is not reserved by Alas, so libghostty should still see it.
        let event = try keyEvent(
            characters: "e",
            ignoringModifiers: "e",
            modifiers: .command,
            keyCode: 14
        )

        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func controlTIsNotReserved() throws {
        let event = try keyEvent(
            characters: "\u{14}",
            ignoringModifiers: "t",
            modifiers: .control,
            keyCode: 17
        )

        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func keyUpIsNotReserved() throws {
        let event = try keyEvent(
            type: .keyUp,
            characters: "t",
            ignoringModifiers: "t",
            modifiers: .command,
            keyCode: 17
        )

        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandDIsReserved() throws {
        let event = try keyEvent(
            characters: "d", ignoringModifiers: "d",
            modifiers: .command, keyCode: 2
        )
        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandShiftDIsReserved() throws {
        let event = try keyEvent(
            characters: "D", ignoringModifiers: "d",
            modifiers: [.command, .shift], keyCode: 2
        )
        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandWIsReserved() throws {
        let event = try keyEvent(
            characters: "w", ignoringModifiers: "w",
            modifiers: .command, keyCode: 13
        )
        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandOptionLeftArrowIsReserved() throws {
        let event = try keyEvent(
            characters: "\u{F702}", ignoringModifiers: "\u{F702}",
            modifiers: [.command, .option], keyCode: 123
        )
        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func commandCtrlRightArrowIsReserved() throws {
        let event = try keyEvent(
            characters: "\u{F703}", ignoringModifiers: "\u{F703}",
            modifiers: [.command, .control], keyCode: 124
        )
        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
    }

    @Test func plainArrowIsNotReserved() throws {
        let event = try keyEvent(
            characters: "\u{F702}", ignoringModifiers: "\u{F702}",
            modifiers: [], keyCode: 123
        )
        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event, in: ShortcutReservations.defaultReserved))
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
