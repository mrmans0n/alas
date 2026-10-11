import Foundation

public struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    public var key: String          // "p", "return", "leftArrow", "="
    public var modifiers: [Modifier]

    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case control, option, shift, command
    }

    public var displayString: String {
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

    /// Keys stored by name rather than as their literal character.
    public static let namedKeys: Set<String> = [
        "return", "leftArrow", "rightArrow", "upArrow", "downArrow", "delete", "escape", "tab", "space",
    ]

    public var hasSupportedKey: Bool {
        Self.namedKeys.contains(key) || Self.isSupportedLiteralKey(key)
    }

    public func togglingShift() -> Self {
        var toggledModifiers = modifiers
        if let shiftIndex = toggledModifiers.firstIndex(of: .shift) {
            toggledModifiers.remove(at: shiftIndex)
        } else {
            toggledModifiers.append(.shift)
        }
        return Self(key: key, modifiers: toggledModifiers)
    }

    public static func isSupportedLiteralKey(_ key: String) -> Bool {
        guard key.count == 1, let first = key.first else { return false }
        return first.isLetter || first.isNumber || "0123456789-=,.;'/[]\\`".contains(first)
    }

    public init(key: String, modifiers: [Modifier]) {
        self.key = key
        self.modifiers = modifiers
    }
}
