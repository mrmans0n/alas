import Foundation
import SwiftUI

struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    var key: String          // "p", "return", "leftArrow", "="
    var modifiers: [Modifier]

    enum Modifier: String, Codable, CaseIterable, Sendable {
        case control, option, shift, command
    }

    var displayString: String {
        // Order: control, option, shift, command — Apple HIG.
        // Symbols are space-separated so chips read clearly: "⌘ P", "⇧ ⌘ L".
        let order: [Modifier] = [.control, .option, .shift, .command]
        let symbols = order.filter { modifiers.contains($0) }.map(symbol(for:))
        return (symbols + [keySymbol]).joined(separator: " ")
    }

    private func symbol(for m: Modifier) -> String {
        switch m {
        case .control: return "⌃"
        case .option:  return "⌥"
        case .shift:   return "⇧"
        case .command: return "⌘"
        }
    }

    private var keySymbol: String {
        switch key {
        case "return":     return "↩"
        case "leftArrow":  return "←"
        case "rightArrow": return "→"
        case "upArrow":    return "↑"
        case "downArrow":  return "↓"
        case "delete":     return "⌫"
        case "escape":     return "⎋"
        case "tab":        return "⇥"
        case "space":      return "␣"
        default:           return key.uppercased()
        }
    }

    var hasSupportedKey: Bool {
        keyEquivalent != nil
    }

    func togglingShift() -> Self {
        var toggledModifiers = modifiers
        if let shiftIndex = toggledModifiers.firstIndex(of: .shift) {
            toggledModifiers.remove(at: shiftIndex)
        } else {
            toggledModifiers.append(.shift)
        }
        return Self(key: key, modifiers: toggledModifiers)
    }

    func asKeyboardShortcut() -> KeyboardShortcut? {
        guard let keyEquivalent else { return nil }
        return KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    static func isSupportedLiteralKey(_ key: String) -> Bool {
        guard key.count == 1, let first = key.first else { return false }
        return first.isLetter || first.isNumber || "0123456789-=,.;'/[]\\`".contains(first)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "return":     return .return
        case "leftArrow":  return .leftArrow
        case "rightArrow": return .rightArrow
        case "upArrow":    return .upArrow
        case "downArrow":  return .downArrow
        case "delete":     return .delete
        case "escape":     return .escape
        case "tab":        return .tab
        case "space":      return .space
        default:
            guard Self.isSupportedLiteralKey(key), let first = key.first else { return nil }
            return KeyEquivalent(first)
        }
    }

    private var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift)   { m.insert(.shift) }
        if modifiers.contains(.option)  { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return m
    }
}
