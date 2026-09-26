import Foundation

/// Finds `#N` / `!N` references in prose. Pure UTF-16 scanning so ranges
/// line up with `NSAttributedString` storage.
enum ACPUpstreamReferenceDetector {
    struct Match: Equatable {
        let range: NSRange
        let reference: CodeHostReference
    }

    private static let backtick: unichar = 0x60
    // Includes the backtick itself: an *unclosed* backtick run is literal
    // CommonMark text (see `codeRanges`), so it must still act as a boundary
    // for a reference that immediately follows it, e.g. "`#12".
    private static let leadingPunctuation = Set("([{\"'`".utf16)
    private static let trailingPunctuation = Set(".,;:!?)]}\"'`".utf16)

    static func references(
        in text: String,
        host: CodeHostKind,
        precededBy: unichar? = nil,
        followedBy: unichar? = nil
    ) -> [Match] {
        let string = text as NSString
        let length = string.length
        let code = codeRanges(in: string, unclosedRunsExtendToEnd: false)
        var matches: [Match] = []
        var index = 0
        while index < length {
            guard let sigil = sigil(for: string.character(at: index), host: host) else {
                index += 1
                continue
            }
            let before: unichar? = index > 0 ? string.character(at: index - 1) : precededBy
            var end = index + 1
            while end < length, isASCIIDigit(string.character(at: end)) { end += 1 }
            let digitCount = end - index - 1
            let after: unichar? = end < length ? string.character(at: end) : followedBy
            if isLeadingBoundary(before),
               (1...9).contains(digitCount),
               string.character(at: index + 1) != 0x30, // no leading zero
               isTrailingBoundary(after),
               !code.contains(where: { NSLocationInRange(index, $0) }),
               let number = Int(string.substring(with: NSRange(location: index + 1, length: digitCount))) {
                matches.append(Match(
                    range: NSRange(location: index, length: end - index),
                    reference: CodeHostReference(sigil: sigil, number: number)
                ))
            }
            index = max(end, index + 1)
        }
        return matches
    }

    /// The token a single typed whitespace character completes. Chips form
    /// on whitespace only: intercepting punctuation would bypass the text
    /// view's delimiter pairing (a typed `)` skipping over an auto-inserted
    /// one). Punctuation typed between the digits and the caret is instead
    /// carried inside `replaceRange`, so the caller re-inserts it after the
    /// chip.
    static func chipTarget(
        completingWith insertedText: String,
        at range: NSRange,
        in text: String,
        host: CodeHostKind
    ) -> (match: Match, replaceRange: NSRange)? {
        guard range.length == 0,
              insertedText.utf16.count == 1,
              let typed = insertedText.utf16.first,
              isWhitespace(typed)
        else { return nil }
        let string = text as NSString
        guard range.location <= string.length else { return nil }
        var tokenEnd = range.location
        while tokenEnd > 0, trailingPunctuation.contains(string.character(at: tokenEnd - 1)) { tokenEnd -= 1 }
        var digitsStart = tokenEnd
        while digitsStart > 0, isASCIIDigit(string.character(at: digitsStart - 1)) { digitsStart -= 1 }
        guard digitsStart > 0, digitsStart < tokenEnd else { return nil }
        let sigilIndex = digitsStart - 1
        let token = string.substring(with: NSRange(location: sigilIndex, length: tokenEnd - sigilIndex))
        let before: unichar? = sigilIndex > 0 ? string.character(at: sigilIndex - 1) : nil
        let after: unichar = tokenEnd < range.location ? string.character(at: tokenEnd) : typed
        guard let local = references(in: token, host: host, precededBy: before, followedBy: after).first,
              local.range == NSRange(location: 0, length: (token as NSString).length)
        else { return nil }
        let prefix = string.substring(to: range.location) as NSString
        guard !codeRanges(in: prefix, unclosedRunsExtendToEnd: true)
            .contains(where: { NSLocationInRange(sigilIndex, $0) })
        else { return nil }
        return (
            Match(range: NSRange(location: sigilIndex, length: local.range.length), reference: local.reference),
            NSRange(location: sigilIndex, length: range.location - sigilIndex)
        )
    }

    /// Ranges enclosed by matching backtick runs. This covers inline code
    /// and fenced blocks alike, since a fence is a run of three closed by
    /// another run of three. An unclosed run is literal text in CommonMark,
    /// so it opens nothing, unless `unclosedRunsExtendToEnd`. The keystroke
    /// path sets that so a code span still being typed doesn't chip.
    static func codeRanges(in text: NSString, unclosedRunsExtendToEnd: Bool) -> [NSRange] {
        let length = text.length
        var ranges: [NSRange] = []
        var index = 0
        while index < length {
            guard text.character(at: index) == backtick else {
                index += 1
                continue
            }
            let runEnd = endOfRun(in: text, from: index)
            let runLength = runEnd - index
            var probe = runEnd
            var closeEnd: Int?
            while probe < length {
                guard text.character(at: probe) == backtick else {
                    probe += 1
                    continue
                }
                let candidateEnd = endOfRun(in: text, from: probe)
                if candidateEnd - probe == runLength {
                    closeEnd = candidateEnd
                    break
                }
                probe = candidateEnd
            }
            if let closeEnd {
                ranges.append(NSRange(location: index, length: closeEnd - index))
                index = closeEnd
            } else if unclosedRunsExtendToEnd {
                ranges.append(NSRange(location: index, length: length - index))
                break
            } else {
                index = runEnd
            }
        }
        return ranges
    }

    private static func endOfRun(in text: NSString, from start: Int) -> Int {
        var end = start
        while end < text.length, text.character(at: end) == backtick { end += 1 }
        return end
    }

    private static func sigil(for character: unichar, host: CodeHostKind) -> CodeHostReference.Sigil? {
        switch character {
        case 0x23: return .hash // "#"
        case 0x21: return host == .gitlab ? .bang : nil // "!"
        default: return nil
        }
    }

    private static func isASCIIDigit(_ character: unichar) -> Bool {
        (0x30...0x39).contains(character)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isLeadingBoundary(_ character: unichar?) -> Bool {
        guard let character else { return true }
        return isWhitespace(character) || leadingPunctuation.contains(character)
    }

    private static func isTrailingBoundary(_ character: unichar?) -> Bool {
        guard let character else { return true }
        return isWhitespace(character) || trailingPunctuation.contains(character)
    }
}
