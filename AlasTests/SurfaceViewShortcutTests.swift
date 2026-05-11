import AppKit
import Testing
@testable import Alas

@MainActor
struct SurfaceViewShortcutTests {
    @Test func commandTIsReservedForAppCommand() throws {
        let event = try keyEvent(
            characters: "t",
            ignoringModifiers: "t",
            modifiers: .command,
            keyCode: 17
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event))
    }

    @Test func commandTAllowsCapsLock() throws {
        let event = try keyEvent(
            characters: "T",
            ignoringModifiers: "t",
            modifiers: [.command, .capsLock],
            keyCode: 17
        )

        #expect(AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event))
    }

    @Test func modifiedCommandTIsNotReserved() throws {
        let event = try keyEvent(
            characters: "T",
            ignoringModifiers: "t",
            modifiers: [.command, .shift],
            keyCode: 17
        )

        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event))
    }

    @Test func otherCommandKeysAreNotReserved() throws {
        let event = try keyEvent(
            characters: "w",
            ignoringModifiers: "w",
            modifiers: .command,
            keyCode: 13
        )

        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event))
    }

    @Test func controlTIsNotReserved() throws {
        let event = try keyEvent(
            characters: "\u{14}",
            ignoringModifiers: "t",
            modifiers: .control,
            keyCode: 17
        )

        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event))
    }

    @Test func keyUpIsNotReserved() throws {
        let event = try keyEvent(
            type: .keyUp,
            characters: "t",
            ignoringModifiers: "t",
            modifiers: .command,
            keyCode: 17
        )

        #expect(!AlasGhostty.SurfaceView.isReservedAppKeyEquivalent(event))
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
