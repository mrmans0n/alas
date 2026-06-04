import Foundation

struct CommitInfo: Identifiable, Hashable {
    var id: String { sha }
    let sha: String          // full 40-char
    let shortSha: String     // 7-char
    let author: String
    let authorInitials: String
    let date: Date
    let subject: String      // already stripped of conventional prefix
    let conventionalTag: String?
    let filesChanged: Int
    let insertions: Int
    let deletions: Int
}

extension CommitInfo {
    static let recognisedTypes: Set<String> = [
        "feat", "fix", "chore", "refactor", "perf", "docs", "test", "ci", "build",
        "style", "revert", "tune", "harden", "polish",
    ]

    /// Splits a commit subject of the form
    ///   `type(scope)?!?: rest`
    /// into `(type, rest)` if `type` is in the recognised set. Otherwise
    /// returns `(nil, subject)` unchanged.
    static func parseConventional(subject: String) -> (tag: String?, stripped: String) {
        // Match an alphabetic type, optional (scope), optional !, then ": ".
        // We intentionally only accept lowercase a–z for the type to avoid
        // matching things like "WIP:" or "TODO:".
        let pattern = #"^([a-z]+)(?:\([^)]*\))?!?:\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (nil, subject)
        }
        let range = NSRange(subject.startIndex..., in: subject)
        guard let match = regex.firstMatch(in: subject, options: [], range: range),
              match.numberOfRanges == 3,
              let tagRange = Range(match.range(at: 1), in: subject),
              let restRange = Range(match.range(at: 2), in: subject)
        else {
            return (nil, subject)
        }
        let tag = String(subject[tagRange])
        guard recognisedTypes.contains(tag) else {
            return (nil, subject)
        }
        return (tag, String(subject[restRange]))
    }

    /// First letter of each name component, max 2 chars, uppercase.
    /// "Nacho Lopez" → "NL", "Nacho" → "N", "" → "?"
    static func initials(for author: String) -> String {
        let parts = author
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return parts.isEmpty ? "?" : parts.joined()
    }
}
