import AppKit
import GhosttyKit
import Testing
@testable import Alas

/// Tests for the NSEvent keyboard-translation helpers that feed Ghostty.
/// These exercise the pure modifier/character logic without needing a live
/// Ghostty surface.
struct SurfaceViewKeyboardTests {
    // MARK: - Modifier translation

    @Test func noModifiersReturnsNone() {
        let mods = alasGhosttyMods([])
        #expect(mods == GHOSTTY_MODS_NONE)
    }

    @Test func shiftModifierReturnsShift() {
        let mods = alasGhosttyMods(.shift)
        #expect(mods == GHOSTTY_MODS_SHIFT)
    }

    @Test func controlModifierReturnsCtrl() {
        let mods = alasGhosttyMods(.control)
        #expect(mods == GHOSTTY_MODS_CTRL)
    }

    @Test func optionModifierReturnsAlt() {
        let mods = alasGhosttyMods(.option)
        #expect(mods == GHOSTTY_MODS_ALT)
    }

    @Test func commandModifierReturnsSuper() {
        let mods = alasGhosttyMods(.command)
        #expect(mods == GHOSTTY_MODS_SUPER)
    }

    @Test func capsLockModifierReturnsCaps() {
        let mods = alasGhosttyMods(.capsLock)
        #expect(mods == GHOSTTY_MODS_CAPS)
    }

    @Test func combinedModifiersReturnCombinedBits() {
        let mods = alasGhosttyMods([.shift, .control, .option])
        let expected = GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_ALT.rawValue
        #expect(mods.rawValue == expected)
    }

    // MARK: - Key event builder (consumed_mods from translation flags)

    @Test func keyEventUsesPhysicalModsAndTranslationConsumedMods() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.shift, .control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        let keyEv = event.alasGhosttyKeyEvent(
            GHOSTTY_ACTION_PRESS,
            translationFlags: .shift
        )

        #expect(keyEv.action == GHOSTTY_ACTION_PRESS)
        #expect(keyEv.mods == alasGhosttyMods([.shift, .control]))
        #expect(keyEv.consumed_mods == alasGhosttyMods(.shift))
    }

    @Test func keyEventWithNoTranslationFlagsUsesPhysicalFlagsMinusCtrlCmd() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.shift, .control, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        let keyEv = event.alasGhosttyKeyEvent(GHOSTTY_ACTION_PRESS)

        #expect(keyEv.consumed_mods == alasGhosttyMods(.shift))
    }

    // MARK: - Character extraction

    @Test func plainCharacterReturnsCharacters() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        #expect(event.alasGhosttyCharacters == "a")
    }

    @Test func puaFunctionKeyReturnsNil() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{F700}", // NSUpArrowFunctionKey
                charactersIgnoringModifiers: "\u{F700}",
                isARepeat: false,
                keyCode: 126
            )
        )

        #expect(event.alasGhosttyCharacters == nil)
    }

    @Test func ctrlPlusLetterReturnsLayoutCharacter() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .control,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{01}",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        #expect(event.alasGhosttyCharacters == "a")
    }

    @Test func shiftEnterReturnsNilForText() throws {
        // Enter keycode 0x24 with shift held produces \r (U+000D < 0x20).
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 0x24
            )
        )

        #expect(event.alasGhosttyCharacters == nil)
    }

    @Test func shiftEnterWithNoTextStillHasShiftInConsumedMods() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 0x24
            )
        )

        let keyEv = event.alasGhosttyKeyEvent(
            GHOSTTY_ACTION_PRESS,
            translationFlags: .shift
        )

        #expect(keyEv.mods == GHOSTTY_MODS_SHIFT)
        #expect(keyEv.consumed_mods == GHOSTTY_MODS_SHIFT)
    }
}
