import Foundation

/// Peer names are set by people and go into prompts, directly and through
/// notices and errors.
public enum ACPPeerName {
    /// In unicode scalars: stacked marks would count as one character.
    static let maxLength = 64

    /// Control characters keep only letters, digits, marks, spaces and
    /// `-._'()`. Everything else (format, bidi, zero-width and tag characters,
    /// quotes, backticks, brackets) is dropped, whitespace is collapsed, the
    /// result is capped, and nil is what remains of a name with nothing left.
    public static func sanitized(_ name: String) -> String? {
        var cleaned = ""
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .nonspacingMark, .spacingMark, .enclosingMark:
                cleaned.unicodeScalars.append(scalar)
            default:
                if "-._'()".unicodeScalars.contains(scalar) {
                    cleaned.unicodeScalars.append(scalar)
                } else if scalar == "\t" || scalar == "\n" || scalar == "\r"
                            || scalar.properties.generalCategory == .spaceSeparator
                            || scalar.properties.generalCategory == .lineSeparator
                            || scalar.properties.generalCategory == .paragraphSeparator {
                    cleaned.unicodeScalars.append(" ")
                }
            }
        }
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let capped = String(String.UnicodeScalarView(collapsed.unicodeScalars.prefix(maxLength)))
            .trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }
}
