import Foundation

/// A same-repository PR/MR/issue reference as typed in prose: `#1234`, or on
/// GitLab also `!1234` for a merge request.
struct CodeHostReference: Hashable, Sendable {
    enum Sigil: Character, Sendable {
        case hash = "#"
        case bang = "!"
    }

    let sigil: Sigil
    let number: Int

    init(sigil: Sigil, number: Int) {
        self.sigil = sigil
        self.number = number
    }

    /// Parses an exact spelling such as `#12`. Rejects leading zeros and
    /// anything longer than nine digits, matching the detector's grammar.
    init?(spelling: String) {
        guard let first = spelling.first, let sigil = Sigil(rawValue: first) else { return nil }
        let digits = spelling.dropFirst()
        guard (1...9).contains(digits.count),
              digits.first != "0",
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits)
        else { return nil }
        self.init(sigil: sigil, number: number)
    }

    var spelling: String { "\(sigil.rawValue)\(number)" }

    /// Browser URL before any lookup has resolved the kind. GitHub redirects
    /// `/issues/N` to `/pull/N` when N is a pull request.
    func webURL(on remote: CodeHostRemote) -> URL {
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
struct CodeHostReferenceSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case reviewRequest
        case issue
    }

    enum State: Equatable, Sendable {
        case open
        case draft
        case merged
        case closed
    }

    let kind: Kind
    let number: Int
    let title: String
    let state: State
    let author: String?
    let createdAt: Date?
    let updatedAt: Date?
    let closedAt: Date?
    let mergedAt: Date?
    let url: URL
}

enum CodeHostReferenceFailure: Equatable, Sendable {
    /// `repository` is `host/owner/repo`, as shown in the card.
    case notFound(repository: String)
    case unauthenticated(executable: String, host: String)
    case cliMissing(executable: String)
    case other(String)
}

extension CodeHostKind {
    var cliExecutable: String {
        switch self {
        case .github: "gh"
        case .gitlab: "glab"
        }
    }
}
