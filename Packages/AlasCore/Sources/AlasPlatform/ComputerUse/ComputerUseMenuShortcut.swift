import Foundation

/// Matching a key chord against a menu item's shortcut as Accessibility reports it.
public enum ComputerUseMenuShortcut {
    /// The modifiers an `AXMenuItemCmdModifiers` mask stands for: 0 is command alone;
    /// bits 0-2 add shift, option and control; bit 3 drops command.
    public static func modifiers(mask: Int) -> Set<ComputerUseKeyChord.Modifier> {
        var modifiers: Set<ComputerUseKeyChord.Modifier> = mask & (1 << 3) == 0 ? [.command] : []
        if mask & (1 << 0) != 0 { modifiers.insert(.shift) }
        if mask & (1 << 1) != 0 { modifiers.insert(.option) }
        if mask & (1 << 2) != 0 { modifiers.insert(.control) }
        return modifiers
    }

    /// Only chords with command, control or option can be menu shortcuts; fn has no mask bit.
    public static func applies(to chord: ComputerUseKeyChord) -> Bool {
        !chord.modifiers.contains(.function) && !chord.modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// Agents may not quit apps: ⌘Q with any other modifiers.
    public static func isQuit(_ chord: ComputerUseKeyChord) -> Bool {
        chord.modifiers.contains(.command) && chord.key == .character("q")
    }

    /// Characters AppKit reports as the shortcut of an item bound to a named key.
    private static let namedKeyCharacters: [ComputerUseKeyChord.NamedKey: Set<String>] = [
        .return: ["\r", "\n"], .tab: ["\t"], .space: [" "], .escape: ["\u{1B}"], .delete: ["\u{8}", "\u{7F}"],
    ]

    /// Whether an item with this shortcut (`cmdChar`, `virtualKey`, `mask` as read) is the chord.
    /// `chordVirtualKey` is the chord key's code; a named key reported as a control or
    /// private-use character (function keys, arrows) is matched by its virtual key instead.
    public static func matches(
        _ chord: ComputerUseKeyChord, cmdChar: String?, virtualKey: Int?, mask: Int, chordVirtualKey: Int?
    ) -> Bool {
        guard applies(to: chord), modifiers(mask: mask) == chord.modifiers else { return false }
        switch chord.key {
        case .character(let character):
            return cmdChar?.lowercased() == String(character).lowercased()
        case .named(let named):
            if let cmdChar, namedKeyCharacters[named]?.contains(cmdChar) == true { return true }
            if let cmdChar, !isKeyPlaceholder(cmdChar) { return false }
            guard let chordVirtualKey, let virtualKey else { return false }
            return virtualKey == chordVirtualKey
        }
    }

    /// Control and private-use characters stand for keys rather than print.
    private static func isKeyPlaceholder(_ string: String) -> Bool {
        string.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .privateUse
        }
    }
}
