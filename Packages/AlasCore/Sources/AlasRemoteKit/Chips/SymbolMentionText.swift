import Foundation

/// Where the sent `@name` labels of symbol mentions appear in message text.
public enum SymbolMentionText {
    /// Each occurrence of a label that starts at a word boundary and ends
    /// before an identifier character or a `.member`, longest labels first
    /// so `@Type.member()` wins over `@Type` at the same spot, skipping
    /// overlaps and `excluded` ranges. Sorted by location.
    public static func labelRanges(
        _ labels: [String],
        in source: NSString,
        excluded: (NSRange) -> Bool = { _ in false }
    ) -> [(range: NSRange, label: String)] {
        var matches: [(range: NSRange, label: String)] = []
        for label in labels.sorted(by: { $0.count > $1.count }) {
            var searchStart = 0
            while searchStart < source.length {
                let range = source.range(
                    of: label, options: .literal,
                    range: NSRange(location: searchStart, length: source.length - searchStart))
                guard range.location != NSNotFound else { break }
                searchStart = NSMaxRange(range)
                guard isBoundary(before: range, in: source), isBoundary(after: range, in: source),
                      !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }),
                      !excluded(range)
                else { continue }
                matches.append((range, label))
            }
        }
        return matches.sorted { $0.range.location < $1.range.location }
    }

    /// The base scalar of the user-perceived character at `location`, so an
    /// emoji's surrogate pair or variation selector reads as the emoji itself.
    private static func baseScalar(at location: Int, in source: NSString) -> Unicode.Scalar? {
        source.substring(with: source.rangeOfComposedCharacterSequence(at: location)).unicodeScalars.first
    }

    private static func isIdentifier(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isBoundary(before range: NSRange, in source: NSString) -> Bool {
        guard range.location > 0 else { return true }
        let previous = baseScalar(at: range.location - 1, in: source)
        return !isIdentifier(previous) && previous != "@" && previous != "."
    }

    private static func isBoundary(after range: NSRange, in source: NSString) -> Bool {
        let end = NSMaxRange(range)
        guard end < source.length else { return true }
        let next = baseScalar(at: end, in: source)
        if isIdentifier(next) { return false }
        guard next == ".", end + 1 < source.length else { return true }
        return !isIdentifier(baseScalar(at: end + 1, in: source))
    }
}
