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
                path: RemotePath.display(worktree.path.path),
                metricsAvailable: true,
                comparisonRef: comparisonRef,
                commitCount: commitCount,
                changedFileCount: uniquePaths.count,
                addedLines: changes.reduce(0) { $0 + $1.add },
                deletedLines: changes.reduce(0) { $0 + $1.del },
                conflictCount: changes.filter { $0.conflict != nil }.count,
                isMain: worktree.isMainWorktree,
                createdAt: worktree.createdAt.timeIntervalSince1970,
                lastActivity: worktree.lastActivity.timeIntervalSince1970
            )
        case .unavailable:
            return RemoteWorktreeSummary(
                projectName: projectName,
                worktreeName: worktree.name,
                branch: worktree.branch,
                path: RemotePath.display(worktree.path.path),
                metricsAvailable: false,
                comparisonRef: nil,
                commitCount: 0,
                changedFileCount: 0,
                addedLines: 0,
                deletedLines: 0,
                conflictCount: 0,
                isMain: worktree.isMainWorktree,
                createdAt: worktree.createdAt.timeIntervalSince1970,
                lastActivity: worktree.lastActivity.timeIntervalSince1970
            )
        }
    }
}
