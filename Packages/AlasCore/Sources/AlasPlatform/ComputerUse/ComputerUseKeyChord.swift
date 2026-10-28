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

    /// What can change the focused field's text: ⌘V with any other modifiers (⌥⇧⌘V pastes
    /// matching style); a delete or forward delete with any modifiers
    /// (⌘⌫ deletes to the line start); a control key, as Cocoa's ⌃Y yanks and ⌃K, ⌃H, ⌃D delete;
    /// a printable key or space without command. Option and shift+option type characters such as å.
    public var mayEditText: Bool {
        if modifiers.contains(.command), key == .character("v") { return true }
        switch key {
        case .named(.delete), .named(.forwardDelete): return true
        case .character: return modifiers.contains(.control) || !modifiers.contains(.command)
        case .named(.space): return !modifiers.contains(.command)
        case .named: return false
        }
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

/// Text typed as key events, cut into what each event carries.
public enum ComputerUseTypedKeys: Equatable, Sendable {
    /// A unicode string on one key event: at most the chunk's UTF-16 units, never a split character.
    case text(String)
    /// The Return key for a line break, with Shift (`shift`) for one inside the text: some fields
    /// (Chrome's address bar) take a line break carried as a unicode string as nothing, and a plain
    /// Return sends a chat message where Shift+Return starts a new line.
    case returnKey(shift: Bool)

    /// `text` as key events: each `\n`, `\r` and `\r\n` (one character) as `returnKey`, the rest in
    /// chunks of at most `chunkUnits` UTF-16 units, never splitting a character. In a terminal
    /// (`terminal`) every line break is a plain Return, so each line runs; elsewhere one followed
    /// by more text is Shift+Return, a new line, and each in the trailing run a plain Return, which
    /// submits (an address bar, a search field, a chat). Tabs and other separators stay text.
    public static func split(_ text: String, chunkUnits: Int, terminal: Bool) -> [Self] {
        let characters = Array(text)
        let lastText = characters.lastIndex { !isLineBreak($0) }
        var result: [Self] = []
        var current = ""
        var units = 0
        func flush() {
            if !current.isEmpty { result.append(.text(current)) }
            current = ""
            units = 0
        }
        for (index, character) in characters.enumerated() {
            if isLineBreak(character) {
                flush()
                let inner = lastText.map { index < $0 } ?? false
                result.append(.returnKey(shift: inner && !terminal))
                continue
            }
            let count = character.utf16.count
            if units + count > chunkUnits { flush() }
            current.append(character)
            units += count
        }
        flush()
        return result
    }

    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n"
    }

    /// The characters this piece types, for "typed N of M" counts.
    public var characterCount: Int {
        switch self {
        case .text(let text): text.count
        case .returnKey: 1
        }
    }
}
