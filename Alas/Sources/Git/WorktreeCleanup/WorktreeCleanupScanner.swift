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
    /// Current `HEAD` SHA, used to verify a forge-reported merge actually
    /// applies to what is checked out here — a branch-name match alone is
    /// not enough, since names get reused. `nil` when it could not be read.
    var headSHA: String?
    /// Freshly-read activity timestamp, independent of the possibly-stale
    /// `Worktree.lastActivity` the topology cache carries. `nil` when it
    /// could not be read, in which case the cached value is used instead.
    var lastActivity: Date?
}

/// Merged review requests for one repository, keyed by head branch. A branch
/// name can have multiple entries: it may have been reused across several
/// merged reviews over time, and the caller must be able to check the local
/// worktree's HEAD against any of them, not just the most recent — keeping
/// only the newest would silently drop the exact "reused branch name" case
/// SHA verification exists to handle.
struct WorktreeForgeMergeIndex: Sendable {
    let refsByHeadBranch: [String: [MergedReviewRequestRef]]

    init(refsByHeadBranch: [String: [MergedReviewRequestRef]]) {
        self.refsByHeadBranch = refsByHeadBranch
    }

    init(refs: [MergedReviewRequestRef]) {
        self.refsByHeadBranch = Dictionary(grouping: refs, by: \.headRefName)
    }

    /// Every merged ref recorded for a branch name, oldest and newest alike.
    func refs(forBranch branch: String) -> [MergedReviewRequestRef] {
        refsByHeadBranch[branch] ?? []
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
            let mergeState = Self.mergeState(
                branch: worktree.branch,
                baseBranch: baseBranch,
                isMergedLocally: facts[offset].isMergedLocally,
                localHeadSHA: facts[offset].headSHA,
                indexResult: indexResult
            )
            // A branch the code host confirms is merged has its commits on the
            // remote by definition. `unpushedCount` reports 1 whenever `@{u}`
            // does not resolve, which is also what happens once the upstream
            // has been pruned after a "delete branch on merge" — a stale
            // local-tracking artifact, not unpublished work. It must not drive
            // the dirty verdict the way a genuinely unpublished branch does.
            let unpushedCommitCount: Int
            if case .mergedOnForge = mergeState {
                unpushedCommitCount = 0
            } else {
                unpushedCommitCount = facts[offset].unpushedCommitCount
            }
            let probe = WorktreeCleanupProbe(
                isMainWorktree: worktree.isMainWorktree == true,
                isRemote: false,
                hasUncommittedChanges: facts[offset].hasUncommittedChanges,
                hasUntrackedFiles: facts[offset].hasUntrackedFiles,
                unpushedCommitCount: unpushedCommitCount,
                stashCount: facts[offset].stashCount,
                activeSessionCount: await dependencies.activeSessionCount(worktree.id),
                operationInFlight: await dependencies.operationInFlight(worktree.id),
                // `worktree.lastActivity` is cached from the last topology
                // refresh — ordinary commit activity while the app is open
                // does not update it. Prefer a freshly-read value so a
                // worktree just touched and merged since that last refresh
                // does not read as long-idle and get default-selected.
                lastActivity: facts[offset].lastActivity ?? worktree.lastActivity,
                mergeState: mergeState
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
    ///
    /// A branch-name match against the forge index is not enough on its own:
    /// branch names get reused after an old, unrelated PR on the same name
    /// merged, and a stale name match would misreport the current, unrelated
    /// commits as merged. `localHeadSHA` — this worktree's actual `HEAD` —
    /// must equal the matched ref's recorded head SHA before the match is
    /// trusted; otherwise this falls through to the local-merge check exactly
    /// as if the forge had never reported a match at all.
    static func mergeState(
        branch: String,
        baseBranch: String,
        isMergedLocally: Bool,
        localHeadSHA: String?,
        indexResult: Result<WorktreeForgeMergeIndex, Error>
    ) -> WorktreeMergeState {
        switch indexResult {
        case .success(let index):
            if let localHeadSHA,
               let ref = index.refs(forBranch: branch).first(where: { $0.headSHA == localHeadSHA }) {
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
                    isMergedLocally: false,
                    headSHA: nil,
                    lastActivity: nil
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
        branch: String,
        baseBranch: String
    ) async -> WorktreeCleanupGitFacts {
        async let status = statusFacts(worktreePath: worktreePath)
        async let unpushed = unpushedCount(worktreePath: worktreePath)
        async let stashes = stashCount(worktreePath: worktreePath, branch: branch)
        async let merged = isMergedLocally(
            worktreePath: worktreePath,
            branch: branch,
            baseBranch: baseBranch
        )
        async let head = headSHA(worktreePath: worktreePath)

        let (statusFacts, unpushedCount, stashCount, mergedLocally, headSHA) =
            await (status, unpushed, stashes, merged, head)

        // Synchronous file-attribute read, same mechanism that populates
        // `Worktree.lastActivity` in the first place — reading it fresh here
        // (rather than trusting that possibly-stale cached value) needs no
        // subprocess and no extra concurrency.
        let freshActivity = WorktreeService.lastActivity(forWorktreeAt: worktreePath)

        return WorktreeCleanupGitFacts(
            hasUncommittedChanges: statusFacts.hasUncommittedChanges,
            hasUntrackedFiles: statusFacts.hasUntrackedFiles,
            unpushedCommitCount: unpushedCount,
            stashCount: stashCount,
            isMergedLocally: mergedLocally,
            headSHA: headSHA,
            lastActivity: freshActivity
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
        // A successful command with unparseable output degrades the same way
        // as a failed one: unpushed commits exist nowhere but this worktree,
        // so a "we couldn't tell" case must not read as "nothing unpushed".
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
    }

    private static func stashCount(worktreePath: URL, branch: String) async -> Int {
        // Unlike the unpushed-commit and status probes, a lookup failure here
        // safely degrades to 0, not 1: the stash stack lives in the shared
        // `.git` common directory, not this worktree's private state, so a
        // stash survives `git worktree remove` regardless of whether this
        // probe could read it. There is no way to lose a stash by
        // under-counting it here — so 0 is the honest answer, and it avoids
        // reporting a false "1 stash" blocker to a worktree that has none.
        guard let stashes = try? await GitService().stashes(worktreePath: worktreePath)
        else { return 0 }
        return stashes.filter { isStash($0, forBranch: branch) }.count
    }

    /// Matches a stash's `%gs` reflog subject against a branch name, anchored
    /// on git's own subject shapes (`WIP on <branch>: ...` or
    /// `On <branch>: ...`) rather than a bare substring — a bare
    /// `subject.contains(branch)` would over-count branch `x` against a
    /// stash actually belonging to `feature/x`.
    static func isStash(_ stash: GitStash, forBranch branch: String) -> Bool {
        stash.subject.hasPrefix("WIP on \(branch):")
            || stash.subject.hasPrefix("On \(branch):")
    }

    private static func isMergedLocally(
        worktreePath: URL,
        branch: String,
        baseBranch: String
    ) async -> Bool {
        // A base-branch resolution that falls back past the configured
        // default and past main/master/trunk can, in an unconventional repo,
        // land on one of the very branches being scanned. Comparing a branch
        // against itself as the base trivially "succeeds" (HEAD is always its
        // own ancestor), which would misreport a genuinely unmerged worktree
        // as merged locally. Guard the degenerate case directly rather than
        // trusting the resolved base branch is never a scanned worktree.
        guard branch != baseBranch else { return false }
        guard let result = try? await Process.git(
            ["merge-base", "--is-ancestor", "HEAD", baseBranch],
            cwd: worktreePath
        ) else { return false }
        return result.exitCode == 0
    }

    private static func headSHA(worktreePath: URL) async -> String? {
        guard let result = try? await Process.git(
            ["rev-parse", "HEAD"],
            cwd: worktreePath
        ), result.exitCode == 0 else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
}
