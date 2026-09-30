import Foundation

/// Finds absolute (`/…`) and home-relative (`~/…`) filesystem paths in prose.
/// A token only counts when the probe says it exists, which is what tells a
/// real path from `/review`, `and/or` or a URL fragment. Paths containing
/// spaces are not detected.
enum ACPAbsolutePathDetector {
    struct Match: Equatable {
        /// Range of the path as written (including a leading `~`).
        let range: NSRange
        /// Expanded, standardized path (`~` resolved).
        let path: String
        let isDirectory: Bool
    }

    /// Returns `isDirectory` for an existing path, `nil` when it is missing.
    typealias Probe = (String) -> Bool?

    static func fileSystemProbe(_ path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue
    }

    private static let openers: Set<unichar> = Set("([{\"'<".utf16)
    private static let trailingPunctuation: Set<unichar> = Set(".,;:!?)]}>\"'".utf16)

    /// Matches in `text`, in order. `precededBy` / `followedBy` are the
    /// characters adjacent to `text` in a larger document (a pasted fragment),
    /// so its edges are judged as boundaries rather than assumed to be.
    static func matches(
        in text: String,
        precededBy: unichar? = nil,
        followedBy: unichar? = nil,
        probe: Probe = fileSystemProbe
    ) -> [Match] {
        let string = text as NSString
        let length = string.length
        var result: [Match] = []
        var index = 0
        while index < length {
            let ch = string.character(at: index)
            let previous: unichar? = index > 0 ? string.character(at: index - 1) : precededBy
            guard isPathStart(ch, at: index, in: string), isBoundary(previous) else {
                index += 1
                continue
            }
            var end = index
            while end < length, !isWhitespace(string.character(at: end)) { end += 1 }
            // A token cut off by the end of a fragment may continue in the
            // surrounding text; don't guess.
            if end == length, let followedBy, !isWhitespace(followedBy) { return result }
            if let match = resolve(token: NSRange(location: index, length: end - index), in: string, probe: probe) {
                result.append(match)
            }
            index = end
        }
        return result
    }

    private static func isPathStart(_ ch: unichar, at index: Int, in string: NSString) -> Bool {
        let slash = unichar(UInt8(ascii: "/"))
        if ch == slash {
            // `//` is a URL/comment marker, and a lone `/` is the root.
            guard index + 1 < string.length else { return false }
            let next = string.character(at: index + 1)
            return next != slash && !isWhitespace(next)
        }
        return ch == unichar(UInt8(ascii: "~"))
            && index + 2 < string.length
            && string.character(at: index + 1) == slash
            && !isWhitespace(string.character(at: index + 2))
    }

    private static func resolve(token: NSRange, in string: NSString, probe: Probe) -> Match? {
        var length = token.length
        while length > 0 {
            let candidate = string.substring(with: NSRange(location: token.location, length: length))
            let expanded = (candidate as NSString).expandingTildeInPath
            if expanded.count > 1, let isDirectory = probe(expanded) {
                return Match(
                    range: NSRange(location: token.location, length: length),
                    path: expanded,
                    isDirectory: isDirectory
                )
            }
            guard trailingPunctuation.contains(string.character(at: token.location + length - 1)) else { return nil }
            length -= 1
        }
        return nil
    }

    private static func isBoundary(_ ch: unichar?) -> Bool {
        guard let ch else { return true }
        return isWhitespace(ch) || openers.contains(ch)
    }

    private static func isWhitespace(_ ch: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(ch) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
