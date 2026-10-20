import Foundation
import AlasFoundation
import AlasModel

public struct FileSearchRankingSource: Sendable {
    public let worktreeId: String
    public let projectId: String
    public var workspaceCheckoutID: UUID? = nil
    public var workspaceCheckoutMemberID: UUID? = nil
    public let entries: [FileIndex.Entry]
    public let backendResults: [FileSearchBackendResult]?
    public let statuses: [String: GitStatusBadge]

    public init(worktreeId: String, projectId: String, workspaceCheckoutID: UUID? = nil, workspaceCheckoutMemberID: UUID? = nil, entries: [FileIndex.Entry], backendResults: [FileSearchBackendResult]?, statuses: [String: GitStatusBadge]) {
        self.worktreeId = worktreeId
        self.projectId = projectId
        self.workspaceCheckoutID = workspaceCheckoutID
        self.workspaceCheckoutMemberID = workspaceCheckoutMemberID
        self.entries = entries
        self.backendResults = backendResults
        self.statuses = statuses
    }
}

public actor FileSearchRanker {
    public func rank(query: String, sources: [FileSearchRankingSource]) async throws -> [FileSearchResult] {
        var rows: [FileSearchResult] = []
        var sinceCancelCheck = 0

        for source in sources {
            try Task.checkCancellation()
            let backendPaths: Set<String>
            if let backendResults = source.backendResults {
                backendPaths = Set(backendResults.map(\.relativePath))
                rows.append(contentsOf: backendResults.map { row in
                    FileSearchResult(
                        worktreeId: source.worktreeId,
                        projectId: source.projectId,
                        workspaceCheckoutID: source.workspaceCheckoutID,
                        workspaceCheckoutMemberID: source.workspaceCheckoutMemberID,
                        relativePath: row.relativePath,
                        ext: (row.relativePath as NSString).pathExtension.lowercased(),
                        statusBadge: source.statuses[row.relativePath],
                        matchIndices: row.matchIndices,
                        score: row.score + (source.statuses[row.relativePath] != nil ? 2 : 0)
                    )
                })
            } else {
                backendPaths = []
            }

            for entry in source.entries where !backendPaths.contains(entry.relativePath) {
                sinceCancelCheck &+= 1
                if sinceCancelCheck >= 256 {
                    sinceCancelCheck = 0
                    try Task.checkCancellation()
                }

                let badge = source.statuses[entry.relativePath]
                if query.isEmpty {
                    rows.append(FileSearchResult(
                        worktreeId: source.worktreeId,
                        projectId: source.projectId,
                        workspaceCheckoutID: source.workspaceCheckoutID,
                        workspaceCheckoutMemberID: source.workspaceCheckoutMemberID,
                        relativePath: entry.relativePath,
                        ext: entry.ext,
                        statusBadge: badge,
                        matchIndices: [],
                        score: badge != nil ? 100 : 0
                    ))
                } else if let match = FuzzyMatch.score(query: query, target: entry.relativePath) {
                    let slash = entry.relativePath.lastIndex(of: "/")
                    let prefixLength = slash.map {
                        entry.relativePath.distance(from: entry.relativePath.startIndex, to: $0) + 1
                    } ?? 0
                    let matchesFilename = match.indices.allSatisfy { $0 >= prefixLength }
                    rows.append(FileSearchResult(
                        worktreeId: source.worktreeId,
                        projectId: source.projectId,
                        workspaceCheckoutID: source.workspaceCheckoutID,
                        workspaceCheckoutMemberID: source.workspaceCheckoutMemberID,
                        relativePath: entry.relativePath,
                        ext: entry.ext,
                        statusBadge: badge,
                        matchIndices: match.indices,
                        score: match.score + (matchesFilename ? 8 : 0) + (badge != nil ? 2 : 0)
                    ))
                }
            }
        }

        try Task.checkCancellation()
        if query.isEmpty {
            rows.sort { lhs, rhs in
                if (lhs.statusBadge != nil) != (rhs.statusBadge != nil) {
                    return lhs.statusBadge != nil
                }
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
        } else {
            rows.sort { $0.score > $1.score }
        }

        try Task.checkCancellation()
        return Array(rows.prefix(50))
    }

    public init() {}
}
