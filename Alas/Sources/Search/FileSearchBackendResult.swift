import Foundation

/// Result shape returned by an optional indexed file-search backend.
/// SearchModel owns decoration with worktree/project ids and git status.
struct FileSearchBackendResult: Equatable, Sendable {
    let relativePath: String
    let score: Double
    let matchIndices: [Int]
}
