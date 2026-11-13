/// Turns text into USB HID key presses on a US keyboard layout, with Shift
/// where the character needs it, and marks what the layout lacks for pasting.
public enum DeviceTextInput {
    public struct Press: Equatable, Sendable {
        public let usage: UInt32
        public let shift: Bool

        public init(usage: UInt32, shift: Bool) {
            self.usage = usage
            self.shift = shift
        }
    }

    /// A stretch of text typed as keys, or pasted because the US layout lacks it.
    public enum Run: Equatable, Sendable {
        case keys([Press])
        case paste(String)

        public var characterCount: Int {
            switch self {
            case .keys(let presses): presses.count
            case .paste(let text): text.count
            }
        }
    }

    /// Splits text into key runs and paste runs. A word with any character the
    /// layout lacks is pasted whole: iOS's smart insert puts a space between
    /// a pasted word and letters typed right before it ("Caf é"). A space
    /// between two pasted words joins them into one paste.
    public static func runs(for text: String) -> [Run] {
        let characters = Array(text)
        let pasted = pastedCharacters(characters)
        var runs: [Run] = []
        var index = 0
        while index < characters.count {
            var end = index
            while end < characters.count, pasted[end] == pasted[index] { end += 1 }
            let stretch = characters[index..<end]
            runs.append(pasted[index] ? .paste(String(stretch)) : .keys(stretch.compactMap(press(for:))))
            index = end
        }
        return runs
    }

    private static func pastedCharacters(_ characters: [Character]) -> [Bool] {
        var pasted = characters.map { press(for: $0) == nil }
        // Whole words.
        var start = 0
        while start < characters.count {
            guard !characters[start].isWhitespace else {
                start += 1
                continue
            }
            var end = start
            while end < characters.count, !characters[end].isWhitespace { end += 1 }
            if pasted[start..<end].contains(true) {
                for index in start..<end { pasted[index] = true }
            }
            start = end
        }
        // Spaces between two pasted words.
        for (index, character) in characters.enumerated() where character == " " {
            guard let before = characters[..<index].lastIndex(where: { $0 != " " }),
                  let after = characters[(index + 1)...].firstIndex(where: { $0 != " " })
            else { continue }
            if pasted[before] && pasted[after] { pasted[index] = true }
        }
        return pasted
    }

    private static func press(for character: Character) -> Press? {
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 {
            switch scalar.value {
            case 0x61...0x7A: return Press(usage: 0x04 + scalar.value - 0x61, shift: false) // a-z
            case 0x41...0x5A: return Press(usage: 0x04 + scalar.value - 0x41, shift: true)  // A-Z
            case 0x31...0x39: return Press(usage: 0x1E + scalar.value - 0x31, shift: false) // 1-9
            default: break
            }
        }
        if let usage = unshifted[character] { return Press(usage: usage, shift: false) }
        if let usage = shifted[character] { return Press(usage: usage, shift: true) }
        return nil
    }

    private static let unshifted: [Character: UInt32] = [
        "0": 0x27, "\n": 0x28, "\r\n": 0x28, "\r": 0x28, "\t": 0x2B, " ": 0x2C,
        "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35,
        ",": 0x36, ".": 0x37, "/": 0x38,
    ]

    private static let shifted: [Character: UInt32] = [
        "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27,
        "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31, ":": 0x33, "\"": 0x34, "~": 0x35,
        "<": 0x36, ">": 0x37, "?": 0x38,
    ]
}
