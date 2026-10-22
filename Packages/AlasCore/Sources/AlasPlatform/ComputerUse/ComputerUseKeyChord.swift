import Foundation

/// A keyboard shortcut such as `cmd+shift+s`, parsed from agent-supplied text.
public struct ComputerUseKeyChord: Equatable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable { case command, shift, option, control, function }
    public enum Key: Equatable, Sendable { case character(Character), named(NamedKey) }
    public enum NamedKey: String, CaseIterable, Sendable {
        case `return`, tab, space, delete, forwardDelete, escape, up, down, left, right,
             home, end, pageUp, pageDown, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    }

    public var modifiers: Set<Modifier>
    public var key: Key

    public init(modifiers: Set<Modifier>, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    private static let modifierAliases: [String: Modifier] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
        "fn": .function,
    ]

    private static let namedKeyAliases: [String: NamedKey] = {
        var table = Dictionary(uniqueKeysWithValues: NamedKey.allCases.map { ($0.rawValue.lowercased(), $0) })
        table["enter"] = .return
        table["esc"] = .escape
        table["backspace"] = .delete
        table["del"] = .forwardDelete
        table["pgup"] = .pageUp
        table["pgdn"] = .pageDown
        return table
    }()

    /// "cmd+shift+s", "Return", "ctrl+alt+delete", "f5". Case-insensitive.
    public static func parse(_ text: String) -> ComputerUseKeyChord? {
        let components = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.lowercased() }
        var modifiers = Set<Modifier>()
        var key: Key?
        for component in components {
            guard !component.isEmpty else { return nil }
            if let modifier = modifierAliases[component] {
                guard modifiers.insert(modifier).inserted else { return nil }
            } else if let named = namedKeyAliases[component] {
                guard key == nil else { return nil }
                key = .named(named)
            } else if component.count == 1, let character = component.first, isPrintable(character) {
                guard key == nil else { return nil }
                key = .character(character)
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        return ComputerUseKeyChord(modifiers: modifiers, key: key)
    }

    private static func isPrintable(_ character: Character) -> Bool {
        !character.isWhitespace && !character.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }
}
