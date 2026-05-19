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
        #expect(ShortcutBinding(key: "p", modifiers: [.command]).displayString == "⌘P")
    }

    @Test func displayStringForCommandShiftL() {
        // Apple HIG order: control, option, shift, command — command is last.
        #expect(ShortcutBinding(key: "l", modifiers: [.command, .shift]).displayString == "⇧⌘L")
    }

    @Test func displayStringSpecialKeys() {
        #expect(ShortcutBinding(key: "return", modifiers: [.command]).displayString == "⌘↩")
        #expect(ShortcutBinding(key: "leftArrow", modifiers: [.command, .option]).displayString == "⌥⌘←")
        #expect(ShortcutBinding(key: "=", modifiers: [.command]).displayString == "⌘=")
    }

    @Test func displayStringModifierOrderIsStable() {
        // Order: control, option, shift, command (matches Apple HIG).
        let b = ShortcutBinding(key: "k", modifiers: [.shift, .command, .control])
        #expect(b.displayString == "⌃⇧⌘K")
    }

    @Test func asKeyboardShortcutLetter() {
        let b = ShortcutBinding(key: "p", modifiers: [.command])
        let ks = b.asKeyboardShortcut()
        #expect(ks.key == KeyEquivalent("p"))
        #expect(ks.modifiers == .command)
    }

    @Test func asKeyboardShortcutReturn() {
        let b = ShortcutBinding(key: "return", modifiers: [.command])
        let ks = b.asKeyboardShortcut()
        #expect(ks.key == .return)
    }
}
