import Foundation
import AlasFoundation
import AlasModel

public struct CommitInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String { sha }
    public let sha: String          // full 40-char
    public let shortSha: String     // 7-char
    public let author: String
    public let authorInitials: String
    public let date: Date
    public let subject: String      // already stripped of conventional prefix
    public let rawSubject: String
    public let body: String
    public let conventionalTag: String?
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int

    public init(
        sha: String,
        shortSha: String,
        author: String,
        authorInitials: String,
        date: Date,
        subject: String,
        rawSubject: String? = nil,
        body: String = "",
        conventionalTag: String?,
        filesChanged: Int,
        insertions: Int,
        deletions: Int
    ) {
        self.sha = sha
        self.shortSha = shortSha
        self.author = author
        self.authorInitials = authorInitials
        self.date = date
        self.subject = subject
        self.rawSubject = rawSubject ?? subject
        self.body = body
        self.conventionalTag = conventionalTag
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }
}

extension CommitInfo {
    public static let recognisedTypes: Set<String> = [
        "feat", "fix", "chore", "refactor", "perf", "docs", "test", "ci", "build",
        "style", "revert", "tune", "harden", "polish",
    ]

    /// Splits a commit subject of the form
    ///   `type(scope)?!?: rest`
    /// into `(type, rest)` if `type` is in the recognised set. Otherwise
    /// returns `(nil, subject)` unchanged.
    public static func parseConventional(subject: String) -> (tag: String?, stripped: String) {
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
    public static func initials(for author: String) -> String {
        let parts = author
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
        return parts.isEmpty ? "?" : parts.joined()
    }

    public var fullMessage: String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return rawSubject }
        return "\(rawSubject)\n\n\(trimmedBody)"
    }
}
