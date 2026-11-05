public struct DeviceTextInputError: Error, Equatable, Sendable {
    /// The first character the US layout cannot type.
    public let character: Character

    public init(character: Character) {
        self.character = character
    }
}

/// Turns ASCII text into USB HID key presses on a US keyboard layout, with
/// Shift where the character needs it.
public enum DeviceTextInput {
    public struct Press: Equatable, Sendable {
        public let usage: UInt32
        public let shift: Bool

        public init(usage: UInt32, shift: Bool) {
            self.usage = usage
            self.shift = shift
        }
    }

    public static func presses(for text: String) -> Result<[Press], DeviceTextInputError> {
        var presses: [Press] = []
        for character in text {
            guard let press = press(for: character) else { return .failure(DeviceTextInputError(character: character)) }
            presses.append(press)
        }
        return .success(presses)
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
