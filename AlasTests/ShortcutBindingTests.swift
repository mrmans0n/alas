import Testing
import Foundation
import SwiftUI
@testable import Alas

struct ShortcutBindingTests {
    @Test func codableRoundTripCommandP() throws {
        let original = ShortcutBinding(key: "p", modifiers: [.command])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
        #expect(decoded == original)
    }

    @Test func codableRoundTripCommandShiftL() throws {
        let original = ShortcutBinding(key: "l", modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
        #expect(decoded == original)
    }

    @Test func displayStringForCommandP() {
        #expect(ShortcutBinding(key: "p", modifiers: [.command]).displayString == "⌘ P")
    }

    @Test func displayStringForCommandShiftL() {
        // Apple HIG order: control, option, shift, command — command is last.
        // Symbols are space-separated so chips read clearly.
        #expect(ShortcutBinding(key: "l", modifiers: [.command, .shift]).displayString == "⇧ ⌘ L")
    }

    @Test func displayStringSpecialKeys() {
        #expect(ShortcutBinding(key: "return", modifiers: [.command]).displayString == "⌘ ↩")
        #expect(ShortcutBinding(key: "leftArrow", modifiers: [.command, .option]).displayString == "⌥ ⌘ ←")
        #expect(ShortcutBinding(key: "=", modifiers: [.command]).displayString == "⌘ =")
    }

    @Test func displayStringModifierOrderIsStable() {
        // Order: control, option, shift, command (matches Apple HIG).
        let b = ShortcutBinding(key: "k", modifiers: [.shift, .command, .control])
        #expect(b.displayString == "⌃ ⇧ ⌘ K")
    }

    @Test func asKeyboardShortcutLetter() throws {
        let b = ShortcutBinding(key: "p", modifiers: [.command])
        let ks = try #require(b.asKeyboardShortcut())
        #expect(ks.key == KeyEquivalent("p"))
        #expect(ks.modifiers == .command)
    }

    @Test func asKeyboardShortcutReturn() throws {
        let b = ShortcutBinding(key: "return", modifiers: [.command])
        let ks = try #require(b.asKeyboardShortcut())
        #expect(ks.key == .return)
    }

    @Test func asKeyboardShortcutRejectsUnsupportedKeys() {
        #expect(ShortcutBinding(key: "", modifiers: [.command]).asKeyboardShortcut() == nil)
        #expect(ShortcutBinding(key: "ab", modifiers: [.command]).asKeyboardShortcut() == nil)
        #expect(ShortcutBinding(key: "f13", modifiers: [.command]).asKeyboardShortcut() == nil)
        #expect(ShortcutBinding(key: "🙂", modifiers: [.command]).asKeyboardShortcut() == nil)
    }

    @Test func shiftVariantAddsShift() {
        let base = ShortcutBinding(key: "return", modifiers: [.command])

        #expect(base.togglingShift() == .init(key: "return", modifiers: [.command, .shift]))
    }

    @Test func shiftVariantRemovesExistingShift() {
        let base = ShortcutBinding(key: "j", modifiers: [.command, .shift])

        #expect(base.togglingShift() == .init(key: "j", modifiers: [.command]))
    }

    @Test func keyboardShortcutConvertsToBinding() throws {
        let shortcut = KeyboardShortcut(.return, modifiers: [.command, .shift])

        #expect(try #require(ShortcutBinding(keyboardShortcut: shortcut)) == .init(
            key: "return",
            modifiers: [.shift, .command]
        ))
    }

    @Test func keyboardShortcutConversionPreservesUppercaseLiteralKey() throws {
        let shortcut = KeyboardShortcut("P", modifiers: [.command])
        let binding = try #require(ShortcutBinding(keyboardShortcut: shortcut))

        #expect(binding == .init(key: "P", modifiers: [.command]))
        #expect(binding.asKeyboardShortcut() == shortcut)
    }
}
