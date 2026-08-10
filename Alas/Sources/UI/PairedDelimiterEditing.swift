import Foundation

enum PairedDelimiterEditAction: Equatable {
    case wrap(opening: Character, closing: Character)
    case insertPair(opening: Character, closing: Character)
    case stepOver
    case native
}

enum PairedDelimiterEditing {
    static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
    ]

    static func resolve(
        insertedText: String,
        in text: String,
        selectedRange: NSRange
    ) -> PairedDelimiterEditAction {
        let nsString = text as NSString
        guard isValid(selectedRange, in: nsString), insertedText.count == 1,
              let insertedCharacter = insertedText.first else {
            return .native
        }

        if let closing = pairs[insertedCharacter] {
            if selectedRange.length > 0 {
                return .wrap(opening: insertedCharacter, closing: closing)
            }

            if insertedCharacter == closing,
               character(at: selectedRange.location, in: nsString) == insertedCharacter {
                return .stepOver
            }

            if insertedCharacter != closing || shouldInsertSymmetricPair(at: selectedRange.location, in: nsString) {
                return .insertPair(opening: insertedCharacter, closing: closing)
            }

            return .native
        }

        if pairs.values.contains(insertedCharacter), selectedRange.length == 0,
           character(at: selectedRange.location, in: nsString) == insertedCharacter {
            return .stepOver
        }

        return .native
    }

    private static func isValid(_ range: NSRange, in string: NSString) -> Bool {
        range.location != NSNotFound && range.location <= string.length && range.length <= string.length - range.location
    }

    private static func shouldInsertSymmetricPair(at location: Int, in string: NSString) -> Bool {
        !isEscapedByBackslash(at: location, in: string)
            && !isIdentifierLike(character(before: location, in: string))
            && !isIdentifierLike(character(at: location, in: string))
    }

    private static func character(at location: Int, in string: NSString) -> Character? {
        guard location >= 0, location < string.length else { return nil }
        return Character(string.substring(with: NSRange(location: location, length: 1)))
    }

    private static func character(before location: Int, in string: NSString) -> Character? {
        guard location > 0, location <= string.length else { return nil }
        return character(at: location - 1, in: string)
    }

    private static func isIdentifierLike(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    private static func isEscapedByBackslash(at location: Int, in string: NSString) -> Bool {
        var cursor = location
        var backslashCount = 0
        while character(before: cursor, in: string) == "\\" {
            backslashCount += 1
            cursor -= 1
        }
        return backslashCount % 2 == 1
    }
}
