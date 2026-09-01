import Foundation

/// A file-mode result row. `worktreeId` is needed so we can route
/// open-actions back to the correct worktree, and so SwiftUI list ids
/// stay unique across worktrees in `.allRepos` scope.
struct FileSearchResult: Identifiable, Equatable, Sendable {
    let worktreeId: String
    let projectId: String
    var workspaceCheckoutMemberID: UUID? = nil
    /// Repo-relative path (e.g., `crates/alas-gui/src/main.rs`).
    let relativePath: String
    /// Filename extension without leading dot, lowercased (e.g., `rs`, `toml`).
    let ext: String
    /// `git status --porcelain` short code: M / A / D / R, or nil.
    let statusBadge: GitStatusBadge?
    /// Indices into `relativePath` of fuzzy-matched characters. Empty when
    /// query is empty.
    let matchIndices: [Int]
    let score: Double

    var id: String { worktreeId + ":" + relativePath }
}

enum GitStatusBadge: String, Sendable {
    case modified = "M"
    case added    = "A"
    case deleted  = "D"
    case renamed  = "R"
}

/// A single content-search hit. `groupKey` is `worktreeId + relativePath`,
/// used to bucket hits into `ContentSearchGroup`s.
struct ContentSearchHit: Identifiable, Equatable, Sendable {
    let worktreeId: String
    let projectId: String
    var workspaceCheckoutMemberID: UUID? = nil
    let relativePath: String
    let line: Int
    let column: Int
    let revealColumn: Int?
    let snippet: String
    /// Character (grapheme) offsets into `snippet` of the matched run, or
    /// nil if the offsets don't align with character boundaries. Producers
    /// (ContentSearcher) convert from raw byte offsets up-front so views
    /// can slice with String.Index arithmetic safely on non-ASCII content.
    let matchCharRange: Range<Int>?

    var id: String { "\(worktreeId):\(relativePath):\(line):\(column)" }
    var groupKey: String { "\(worktreeId):\(relativePath)" }
    var revealLine: Int { max(0, line - 1) }
    var revealCharacter: Int { max(0, (revealColumn ?? column) - 1) }
}

struct ContentSearchGroup: Identifiable, Equatable, Sendable {
    let worktreeId: String
    let projectId: String
    var workspaceCheckoutMemberID: UUID? = nil
    let relativePath: String
    var hits: [ContentSearchHit]

    var id: String { "\(worktreeId):\(relativePath)" }
}
