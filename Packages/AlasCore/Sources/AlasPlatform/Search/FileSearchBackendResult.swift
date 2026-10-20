import Foundation
import AlasFoundation
import AlasModel

/// Result shape returned by an optional indexed file-search backend.
/// SearchModel owns decoration with worktree/project ids and git status.
public struct FileSearchBackendResult: Equatable, Sendable {
    public let relativePath: String
    public let score: Double
    public let matchIndices: [Int]

    public init(relativePath: String, score: Double, matchIndices: [Int]) {
        self.relativePath = relativePath
        self.score = score
        self.matchIndices = matchIndices
    }
}
