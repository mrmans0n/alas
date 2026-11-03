import Foundation

/// Decodes the C-quoted path names that git and the ACP adapters write in diff headers.
public enum GitQuotedPath {
    /// Decodes the C-quoted name starting at `index` (which must be `"`), advancing past the closing quote.
    /// Runs of octal escapes decode as UTF-8 bytes; \a \b \t \n \v \f \r \" \\ map to their characters;
    /// raw non-ASCII passes through (Codex). Nil when `text[index] != "\""` or the quote is unterminated.
    /// `index` is left unchanged when decoding fails.
    public static func decode(in text: String, index: inout String.Index) -> String? {
        let scalars = text.unicodeScalars
        guard index < scalars.endIndex, scalars[index] == "\"" else { return nil }

        var cursor = scalars.index(after: index)
        var value = String.UnicodeScalarView()
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            if scalar == "\"" {
                index = scalars.index(after: cursor)
                return String(value)
            }
            if scalar == "\\" {
                if let bytes = decodeOctalByteSequence(in: scalars, index: &cursor) {
                    value.append(contentsOf: bytes.unicodeScalars)
                    continue
                }
                guard let escaped = decodeEscapedScalar(in: scalars, index: &cursor) else { return nil }
                value.append(escaped)
            } else {
                value.append(scalar)
                cursor = scalars.index(after: cursor)
            }
        }
        return nil
    }

    /// Decodes a run of `\NNN` escapes as one UTF-8 byte sequence, as git writes non-ASCII names.
    private static func decodeOctalByteSequence(
        in scalars: String.UnicodeScalarView,
        index: inout String.Index
    ) -> String? {
        var cursor = index
        var bytes: [UInt8] = []

        while cursor < scalars.endIndex, scalars[cursor] == "\\" {
            let escapedIndex = scalars.index(after: cursor)
            guard escapedIndex < scalars.endIndex, isOctalDigit(scalars[escapedIndex]) else { break }

            var digitCursor = escapedIndex
            var digits = ""
            while digitCursor < scalars.endIndex, digits.count < 3, isOctalDigit(scalars[digitCursor]) {
                digits.unicodeScalars.append(scalars[digitCursor])
                digitCursor = scalars.index(after: digitCursor)
            }

            guard let value = UInt8(digits, radix: 8) else { return nil }
            bytes.append(value)
            cursor = digitCursor
        }

        guard !bytes.isEmpty else { return nil }
        index = cursor
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeEscapedScalar(
        in scalars: String.UnicodeScalarView,
        index: inout String.Index
    ) -> Unicode.Scalar? {
        let escapedIndex = scalars.index(after: index)
        guard escapedIndex < scalars.endIndex else { return nil }

        let escaped = scalars[escapedIndex]
        let decoded: Unicode.Scalar
        switch escaped {
        case "a": decoded = "\u{07}"
        case "b": decoded = "\u{08}"
        case "t": decoded = "\t"
        case "n": decoded = "\n"
        case "v": decoded = "\u{0B}"
        case "f": decoded = "\u{0C}"
        case "r": decoded = "\r"
        case "\"", "\\": decoded = escaped
        default:
            if let octal = decodeOctalEscape(in: scalars, index: escapedIndex) {
                index = octal.nextIndex
                return octal.scalar
            }
            decoded = escaped
        }
        index = scalars.index(after: escapedIndex)
        return decoded
    }

    /// Decodes a single octal escape whose value does not fit a byte, such as `\777`.
    private static func decodeOctalEscape(
        in scalars: String.UnicodeScalarView,
        index: String.Index
    ) -> (scalar: Unicode.Scalar, nextIndex: String.Index)? {
        var cursor = index
        var digits = ""

        while cursor < scalars.endIndex, digits.count < 3, isOctalDigit(scalars[cursor]) {
            digits.unicodeScalars.append(scalars[cursor])
            cursor = scalars.index(after: cursor)
        }

        guard !digits.isEmpty,
              let value = UInt32(digits, radix: 8),
              let scalar = Unicode.Scalar(value)
        else { return nil }

        return (scalar, cursor)
    }

    private static func isOctalDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 55
    }
}
