import Foundation

/// A slash command that is a skill. The host keeps the `SKILL.md` path.
public struct RemoteSkillInfo: Codable, Equatable, Hashable, Sendable {
    /// False for a skill bundled with the agent.
    public var hasFile: Bool

    public init(hasFile: Bool) {
        self.hasFile = hasFile
    }
}

/// A mention a sent prompt carried, as its row shows it.
public struct RemoteUserMention: Codable, Equatable, Hashable, Sendable {
    /// `RemoteMention.file`, `.session` or `.symbol`.
    public var kind: String
    /// The chip's label: a file or folder name, a session title, a symbol's display name.
    public var name: String
    public var symbol: RemoteSymbolMention?

    public init(kind: String, name: String, symbol: RemoteSymbolMention? = nil) {
        self.kind = kind
        self.name = name
        self.symbol = symbol
    }
}

/// A sent symbol mention: the declaration it named and what was sent.
public struct RemoteSymbolMention: Codable, Equatable, Hashable, Sendable {
    /// Worktree-relative.
    public var path: String
    public var name: String
    /// `SymbolKind.rawValue`.
    public var kind: String
    public var container: String?
    /// 0-based, inclusive, as inserted.
    public var lineRange: ClosedRange<Int>
    public var includesCode: Bool
    public var snapshot: ACPSymbolSnapshot?

    public init(
        path: String, name: String, kind: String, container: String?,
        lineRange: ClosedRange<Int>, includesCode: Bool, snapshot: ACPSymbolSnapshot?
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.container = container
        self.lineRange = lineRange
        self.includesCode = includesCode
        self.snapshot = snapshot
    }
}

/// One answer of `referenceSummaries`: what a reference turned out to be,
/// or why it could not be looked up.
public struct RemoteReferenceEntry: Codable, Equatable, Sendable {
    /// `#12`, `!7`.
    public var spelling: String
    public var summary: CodeHostReferenceSummary?
    public var failure: CodeHostReferenceFailure?

    public init(spelling: String, summary: CodeHostReferenceSummary? = nil, failure: CodeHostReferenceFailure? = nil) {
        self.spelling = spelling
        self.summary = summary
        self.failure = failure
    }
}

public enum RemoteChipLimits {
    /// Spellings one `resolveReferences` may ask for.
    public static let maxReferences = 50
}
