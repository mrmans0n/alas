import Foundation

enum RemoteWorktreeSummaryMetrics: Equatable {
    case available(comparisonRef: String?, commitCount: Int, changes: [ChangedFile])
    case unavailable
}

enum RemoteWorktreeSummaryBuilder {
    static func make(
        projectName: String,
        worktree: Worktree,
        metrics: RemoteWorktreeSummaryMetrics
    ) -> RemoteWorktreeSummary {
        switch metrics {
        case .available(let comparisonRef, let commitCount, let changes):
            let uniquePaths = Set(changes.map(\.path))
            return RemoteWorktreeSummary(
                projectName: projectName,
                worktreeName: worktree.name,
                branch: worktree.branch,
                path: worktree.path.path,
                metricsAvailable: true,
                comparisonRef: comparisonRef,
                commitCount: commitCount,
                changedFileCount: uniquePaths.count,
                addedLines: changes.reduce(0) { $0 + $1.add },
                deletedLines: changes.reduce(0) { $0 + $1.del },
                conflictCount: changes.filter { $0.conflict != nil }.count
            )
        case .unavailable:
            return RemoteWorktreeSummary(
                projectName: projectName,
                worktreeName: worktree.name,
                branch: worktree.branch,
                path: worktree.path.path,
                metricsAvailable: false,
                comparisonRef: nil,
                commitCount: 0,
                changedFileCount: 0,
                addedLines: 0,
                deletedLines: 0,
                conflictCount: 0
            )
        }
    }
}
