import Foundation

/// A same-repository PR/MR/issue reference as typed in prose: `#1234`, or on
/// GitLab also `!1234` for a merge request.
public struct CodeHostReference: Hashable, Sendable {
    public enum Sigil: Character, Sendable {
        case hash = "#"
        case bang = "!"
    }

    public let sigil: Sigil
    public let number: Int

    public init(sigil: Sigil, number: Int) {
        self.sigil = sigil
        self.number = number
    }

    /// Parses an exact spelling such as `#12`. Rejects leading zeros and
    /// anything longer than nine digits, matching the detector's grammar.
    public init?(spelling: String) {
        guard let first = spelling.first, let sigil = Sigil(rawValue: first) else { return nil }
        let digits = spelling.dropFirst()
        guard (1...9).contains(digits.count),
              digits.first != "0",
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits)
        else { return nil }
        self.init(sigil: sigil, number: number)
    }

    public var spelling: String { "\(sigil.rawValue)\(number)" }

    /// Browser URL before any lookup has resolved the kind. GitHub redirects
    /// `/issues/N` to `/pull/N` when N is a pull request.
    public func webURL(on remote: CodeHostRemote) -> URL {
        switch (remote.kind, sigil) {
        case (.gitlab, .bang):
            return remote.reviewRequestURL(number: number)
        case (.gitlab, .hash):
            return remote.webURL.appendingPathComponent("-")
                .appendingPathComponent("issues").appendingPathComponent("\(number)")
        case (.github, _):
            return remote.webURL.appendingPathComponent("issues").appendingPathComponent("\(number)")
        }
    }
}

/// The compact metadata a reference chip's hover card shows.
public struct CodeHostReferenceSummary: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case reviewRequest
        case issue
    }

    public enum State: Equatable, Sendable {
        case open
        case draft
        case merged
        case closed
    }

    public let kind: Kind
    public let number: Int
    public let title: String
    public let state: State
    public let author: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let closedAt: Date?
    public let mergedAt: Date?
    public let url: URL

    public init(kind: Kind, number: Int, title: String, state: State, author: String?, createdAt: Date?, updatedAt: Date?, closedAt: Date?, mergedAt: Date?, url: URL) {
        self.kind = kind
        self.number = number
        self.title = title
        self.state = state
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.mergedAt = mergedAt
        self.url = url
    }
}

public enum CodeHostReferenceFailure: Equatable, Sendable {
    /// `repository` is `host/owner/repo`, as shown in the card.
    case notFound(repository: String)
    case unauthenticated(executable: String, host: String)
    case cliMissing(executable: String)
    case other(String)
}

extension CodeHostKind {
    public var cliExecutable: String {
        switch self {
        case .github: "gh"
        case .gitlab: "glab"
        }
    }
}
