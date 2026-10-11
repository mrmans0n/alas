import Foundation

/// A file-mode result row. `worktreeId` is needed so we can route
/// open-actions back to the correct worktree, and so SwiftUI list ids
/// stay unique across worktrees in `.allRepos` scope.
public struct FileSearchResult: Identifiable, Equatable, Sendable {
    public let worktreeId: String
    public let projectId: String
    public var workspaceCheckoutID: UUID? = nil
    public var workspaceCheckoutMemberID: UUID? = nil
    /// Repo-relative path (e.g., `crates/alas-gui/src/main.rs`).
    public let relativePath: String
    /// Filename extension without leading dot, lowercased (e.g., `rs`, `toml`).
    public let ext: String
    /// `git status --porcelain` short code: M / A / D / R, or nil.
    public let statusBadge: GitStatusBadge?
    /// Indices into `relativePath` of fuzzy-matched characters. Empty when
    /// query is empty.
    public let matchIndices: [Int]
    public let score: Double

    public var id: String { worktreeId + ":" + relativePath }

    public init(worktreeId: String, projectId: String, workspaceCheckoutID: UUID? = nil, workspaceCheckoutMemberID: UUID? = nil, relativePath: String, ext: String, statusBadge: GitStatusBadge?, matchIndices: [Int], score: Double) {
        self.worktreeId = worktreeId
        self.projectId = projectId
        self.workspaceCheckoutID = workspaceCheckoutID
        self.workspaceCheckoutMemberID = workspaceCheckoutMemberID
        self.relativePath = relativePath
        self.ext = ext
        self.statusBadge = statusBadge
        self.matchIndices = matchIndices
        self.score = score
    }
}

public enum GitStatusBadge: String, Sendable {
    case modified = "M"
    case added    = "A"
    case deleted  = "D"
    case renamed  = "R"
}

/// A single content-search hit. `groupKey` is `worktreeId + relativePath`,
/// used to bucket hits into `ContentSearchGroup`s.
public struct ContentSearchHit: Identifiable, Equatable, Sendable {
    public let worktreeId: String
    public let projectId: String
    public var workspaceCheckoutID: UUID? = nil
    public var workspaceCheckoutMemberID: UUID? = nil
    public let relativePath: String
    public let line: Int
    public let column: Int
    public let revealColumn: Int?
    public let snippet: String
    /// Character (grapheme) offsets into `snippet` of the matched run, or
    /// nil if the offsets don't align with character boundaries. Producers
    /// (ContentSearcher) convert from raw byte offsets up-front so views
    /// can slice with String.Index arithmetic safely on non-ASCII content.
    public let matchCharRange: Range<Int>?

    public var id: String { "\(worktreeId):\(relativePath):\(line):\(column)" }
    public var groupKey: String { "\(worktreeId):\(relativePath)" }
    public var revealLine: Int { max(0, line - 1) }
    public var revealCharacter: Int { max(0, (revealColumn ?? column) - 1) }

    public init(worktreeId: String, projectId: String, workspaceCheckoutID: UUID? = nil, workspaceCheckoutMemberID: UUID? = nil, relativePath: String, line: Int, column: Int, revealColumn: Int?, snippet: String, matchCharRange: Range<Int>?) {
        self.worktreeId = worktreeId
        self.projectId = projectId
        self.workspaceCheckoutID = workspaceCheckoutID
        self.workspaceCheckoutMemberID = workspaceCheckoutMemberID
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.revealColumn = revealColumn
        self.snippet = snippet
        self.matchCharRange = matchCharRange
    }
}

public struct ContentSearchGroup: Identifiable, Equatable, Sendable {
    public let worktreeId: String
    public let projectId: String
    public var workspaceCheckoutID: UUID? = nil
    public var workspaceCheckoutMemberID: UUID? = nil
    public let relativePath: String
    public var hits: [ContentSearchHit]

    public var id: String { "\(worktreeId):\(relativePath)" }

    public init(worktreeId: String, projectId: String, workspaceCheckoutID: UUID? = nil, workspaceCheckoutMemberID: UUID? = nil, relativePath: String, hits: [ContentSearchHit]) {
        self.worktreeId = worktreeId
        self.projectId = projectId
        self.workspaceCheckoutID = workspaceCheckoutID
        self.workspaceCheckoutMemberID = workspaceCheckoutMemberID
        self.relativePath = relativePath
        self.hits = hits
    }
}
