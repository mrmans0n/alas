import Foundation

/// Git-derived facts for one worktree. Separate from `WorktreeCleanupProbe`
/// because the scanner also folds in non-git facts (sessions, forge state)
/// before classification.
struct WorktreeCleanupGitFacts: Equatable, Sendable {
    var hasUncommittedChanges: Bool
    var hasUntrackedFiles: Bool
    var unpushedCommitCount: Int
    var stashCount: Int
    var isMergedLocally: Bool
}

/// Merged review requests for one repository, keyed by head branch.
struct WorktreeForgeMergeIndex: Sendable {
    let refsByHeadBranch: [String: MergedReviewRequestRef]

    init(refsByHeadBranch: [String: MergedReviewRequestRef]) {
        self.refsByHeadBranch = refsByHeadBranch
    }

    init(refs: [MergedReviewRequestRef]) {
        // Newest first from both CLIs, so keep the first ref seen for a branch.
        var byBranch: [String: MergedReviewRequestRef] = [:]
        for ref in refs where byBranch[ref.headRefName] == nil {
            byBranch[ref.headRefName] = ref
        }
        self.refsByHeadBranch = byBranch
    }

    func ref(forBranch branch: String) -> MergedReviewRequestRef? {
        refsByHeadBranch[branch]
    }
}

/// Collects the facts the classifier needs. All I/O arrives through
/// `Dependencies`, so tests drive the whole scan without a repository or a
/// network.
struct WorktreeCleanupScanner: Sendable {
    struct Dependencies: Sendable {
        var gitFacts: @Sendable (Worktree) async -> WorktreeCleanupGitFacts
        /// `Result` rather than an optional so a failure can carry its reason
        /// into the `unknown` merge state the user sees.
        var mergeIndex: @Sendable (ProjectConfig) async -> Result<WorktreeForgeMergeIndex, Error>
        /// Async because the live implementations read `@MainActor` app state
        /// (open tabs, harness activity, in-flight operations) while the
        /// scanner itself is not main-actor isolated.
        var activeSessionCount: @Sendable (String) async -> Int
        var operationInFlight: @Sendable (String) async -> Bool
    }

    /// Concurrent git probes in flight. Thirty worktrees must not mean thirty
    /// simultaneous git processes.
    static let probeConcurrency = 4

    let dependencies: Dependencies

    /// `baseBranch` must be the same branch the `gitFacts` probe compared
    /// against, since it is what the `.mergedLocally` signal names back to the
    /// user. Passing it explicitly keeps the label and the check from drifting.
    func scan(
        project: ProjectConfig,
        worktrees: [Worktree],
        baseBranch: String,
        now: Date,
        idleThresholdDays: Int
    ) async -> [WorktreeCleanupCandidate] {
        // Remote/SSH projects are out of scope for cleanup: excluded up front,
        // with no probes run at all.
        if project.host != nil {
            return worktrees.map { worktree in
                WorktreeCleanupClassifier.classify(
                    worktree: worktree,
                    probe: Self.remoteProbe(for: worktree),
                    now: now,
                    idleThresholdDays: idleThresholdDays
                )
            }
        }

        let indexResult = await dependencies.mergeIndex(project)
        let facts = await collectGitFacts(for: worktrees)

        var candidates: [WorktreeCleanupCandidate] = []
        candidates.reserveCapacity(worktrees.count)
        for (offset, worktree) in worktrees.enumerated() {
            let probe = WorktreeCleanupProbe(
                isMainWorktree: worktree.isMainWorktree == true,
                isRemote: false,
                hasUncommittedChanges: facts[offset].hasUncommittedChanges,
                hasUntrackedFiles: facts[offset].hasUntrackedFiles,
                unpushedCommitCount: facts[offset].unpushedCommitCount,
                stashCount: facts[offset].stashCount,
                activeSessionCount: await dependencies.activeSessionCount(worktree.id),
                operationInFlight: await dependencies.operationInFlight(worktree.id),
                lastActivity: worktree.lastActivity,
                mergeState: Self.mergeState(
                    branch: worktree.branch,
                    baseBranch: baseBranch,
                    isMergedLocally: facts[offset].isMergedLocally,
                    indexResult: indexResult
                )
            )
            candidates.append(WorktreeCleanupClassifier.classify(
                worktree: worktree,
                probe: probe,
                now: now,
                idleThresholdDays: idleThresholdDays
            ))
        }
        return candidates
    }

    /// Resolves merge state, preserving the distinction the acceptance criteria
    /// require: forge-merged, locally merged, genuinely not merged, and
    /// "we could not find out". A forge failure never becomes `.notMerged`.
    static func mergeState(
        branch: String,
        baseBranch: String,
        isMergedLocally: Bool,
        indexResult: Result<WorktreeForgeMergeIndex, Error>
    ) -> WorktreeMergeState {
        switch indexResult {
        case .success(let index):
            if let ref = index.ref(forBranch: branch) {
                return .mergedOnForge(identity: "#\(ref.number)", url: ref.url)
            }
            if isMergedLocally { return .mergedLocally(base: baseBranch) }
            return .notMerged
        case .failure(let error):
            // The local check is independent of the forge query, so a local
            // merge still counts even when the forge could not be reached.
            if isMergedLocally { return .mergedLocally(base: baseBranch) }
            return .unknown(reason: Self.reason(for: error))
        }
    }

    static func reason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private static func remoteProbe(for worktree: Worktree) -> WorktreeCleanupProbe {
        WorktreeCleanupProbe(
            isMainWorktree: worktree.isMainWorktree == true,
            isRemote: true,
            hasUncommittedChanges: false,
            hasUntrackedFiles: false,
            unpushedCommitCount: 0,
            stashCount: 0,
            activeSessionCount: 0,
            operationInFlight: false,
            lastActivity: worktree.lastActivity,
            mergeState: .unknown(reason: "remote worktree")
        )
    }

    /// Probes run concurrently, bounded, and results are re-ordered to match
    /// the input so callers can zip by index.
    private func collectGitFacts(
        for worktrees: [Worktree]
    ) async -> [WorktreeCleanupGitFacts] {
        await withTaskGroup(
            of: (Int, WorktreeCleanupGitFacts).self
        ) { group in
            var results = [WorktreeCleanupGitFacts?](
                repeating: nil,
                count: worktrees.count
            )
            var next = 0

            func addTask(_ index: Int) {
                let worktree = worktrees[index]
                let probe = dependencies.gitFacts
                group.addTask { (index, await probe(worktree)) }
            }

            while next < worktrees.count && next < Self.probeConcurrency {
                addTask(next)
                next += 1
            }
            while let (index, facts) = await group.next() {
                results[index] = facts
                if next < worktrees.count {
                    addTask(next)
                    next += 1
                }
            }

            return results.map {
                $0 ?? WorktreeCleanupGitFacts(
                    hasUncommittedChanges: true,
                    hasUntrackedFiles: false,
                    unpushedCommitCount: 0,
                    stashCount: 0,
                    isMergedLocally: false
                )
            }
        }
    }
}

extension WorktreeCleanupScanner {
    /// Live git probe. Each failure degrades that single fact in the
    /// conservative direction rather than failing the scan.
    static func gitFacts(
        worktreePath: URL,
        baseBranch: String
    ) async -> WorktreeCleanupGitFacts {
        async let status = statusFacts(worktreePath: worktreePath)
        async let unpushed = unpushedCount(worktreePath: worktreePath)
        async let stashes = stashCount(worktreePath: worktreePath)
        async let merged = isMergedLocally(
            worktreePath: worktreePath,
            baseBranch: baseBranch
        )

        let (statusFacts, unpushedCount, stashCount, mergedLocally) =
            await (status, unpushed, stashes, merged)

        return WorktreeCleanupGitFacts(
            hasUncommittedChanges: statusFacts.hasUncommittedChanges,
            hasUntrackedFiles: statusFacts.hasUntrackedFiles,
            unpushedCommitCount: unpushedCount,
            stashCount: stashCount,
            isMergedLocally: mergedLocally
        )
    }

    private static func statusFacts(
        worktreePath: URL
    ) async -> (hasUncommittedChanges: Bool, hasUntrackedFiles: Bool) {
        guard let result = try? await Process.git(
            ["status", "--porcelain", "--untracked-files=normal"],
            cwd: worktreePath
        ), result.exitCode == 0 else {
            // Could not read status — assume dirty rather than offer deletion.
            return (true, false)
        }
        return parseStatusPorcelain(result.stdout)
    }

    static func parseStatusPorcelain(
        _ output: String
    ) -> (hasUncommittedChanges: Bool, hasUntrackedFiles: Bool) {
        var hasUncommittedChanges = false
        var hasUntrackedFiles = false
        for line in output.split(separator: "\n") where line.count >= 2 {
            if line.hasPrefix("??") {
                hasUntrackedFiles = true
            } else {
                hasUncommittedChanges = true
            }
        }
        return (hasUncommittedChanges, hasUntrackedFiles)
    }

    private static func unpushedCount(worktreePath: URL) async -> Int {
        guard let result = try? await Process.git(
            ["rev-list", "--count", "@{u}..HEAD"],
            cwd: worktreePath
        ), result.exitCode == 0 else {
            // No upstream configured (or the check failed). An unpublished
            // branch has work that exists nowhere else, so treat it as unpushed.
            return 1
        }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func stashCount(worktreePath: URL) async -> Int {
        // The stash stack is repository-wide, so filter to stashes whose
        // recorded branch matches this worktree's branch.
        guard let branch = try? await Process.git(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            cwd: worktreePath
        ), branch.exitCode == 0 else { return 0 }
        let branchName = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else { return 0 }

        guard let stashes = try? await GitService().stashes(worktreePath: worktreePath)
        else { return 0 }
        return stashes.filter { $0.subject.contains(branchName) }.count
    }

    private static func isMergedLocally(
        worktreePath: URL,
        baseBranch: String
    ) async -> Bool {
        guard let result = try? await Process.git(
            ["merge-base", "--is-ancestor", "HEAD", baseBranch],
            cwd: worktreePath
        ) else { return false }
        return result.exitCode == 0
    }
}
