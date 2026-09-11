import Testing
import Foundation
@testable import Alas

struct WorktreeCleanupScannerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func project(host: String? = nil) -> ProjectConfig {
        ProjectConfig(
            id: "p",
            name: "alas",
            path: "/tmp/repo",
            color: "blue",
            addedAt: now,
            host: host
        )
    }

    private static func worktree(branch: String, isMain: Bool = false) -> Worktree {
        Worktree(
            id: "/tmp/wt-\(branch)",
            projectId: "p",
            name: branch,
            branch: branch,
            path: URL(fileURLWithPath: "/tmp/wt-\(branch)"),
            isMainWorktree: isMain,
            status: .clean,
            lastActivity: now.addingTimeInterval(-30 * 86_400)
        )
    }

    /// Matches the `headSHA` on every `MergedReviewRequestRef` fixture below,
    /// so tests that only care about the merged-on-forge path don't also have
    /// to think about SHA verification — the dedicated mismatch test below
    /// does that.
    private static let localHeadSHA = "abc123"

    private static let cleanFacts = WorktreeCleanupGitFacts(
        hasUncommittedChanges: false,
        hasUntrackedFiles: false,
        unpushedCommitCount: 0,
        stashCount: 0,
        isMergedLocally: false,
        headSHA: localHeadSHA,
        lastActivity: nil
    )

    private static func scanner(
        facts: @escaping @Sendable (Worktree) async -> WorktreeCleanupGitFacts = { _ in cleanFacts },
        mergeIndex: @escaping @Sendable (ProjectConfig) async -> Result<WorktreeForgeMergeIndex, Error> = { _ in
            .success(WorktreeForgeMergeIndex(refsByHeadBranch: [:]))
        },
        activeSessionCount: @escaping @Sendable (String) async -> Int = { _ in 0 },
        operationInFlight: @escaping @Sendable (String) async -> Bool = { _ in false }
    ) -> WorktreeCleanupScanner {
        WorktreeCleanupScanner(
            dependencies: WorktreeCleanupScanner.Dependencies(
                gitFacts: facts,
                mergeIndex: mergeIndex,
                activeSessionCount: activeSessionCount,
                operationInFlight: operationInFlight
            )
        )
    }

    private static func scan(
        _ scanner: WorktreeCleanupScanner,
        project: ProjectConfig = project(),
        worktrees: [Worktree]
    ) async -> [WorktreeCleanupCandidate] {
        await scanner.scan(
            project: project,
            worktrees: worktrees,
            baseBranch: "main",
            now: now,
            idleThresholdDays: 14
        )
    }

    @Test func forgeIndexIsAppliedByHeadRefName() async {
        let ref = MergedReviewRequestRef(
            number: 42,
            headRefName: "feature/a",
            url: URL(string: "https://github.com/o/r/pull/42")!,
            headSHA: Self.localHeadSHA
        )
        let scanner = Self.scanner(mergeIndex: { _ in
            .success(WorktreeForgeMergeIndex(refsByHeadBranch: ["feature/a": [ref]]))
        })
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .candidate(confidence: .high))
        #expect(results[0].signals.contains(
            .mergedOnForge(identity: "#42", url: ref.url)
        ))
    }

    /// A branch-name match against the forge index is not enough on its own:
    /// names get reused after an old, unrelated PR on the same name merged.
    /// A recorded head SHA that does not match what is actually checked out
    /// here must not be trusted as this branch's merge.
    @Test func forgeMatchWithMismatchedSHAIsNotTrustedAsMergedOnForge() async {
        let ref = MergedReviewRequestRef(
            number: 42,
            headRefName: "feature/a",
            url: URL(string: "https://github.com/o/r/pull/42")!,
            headSHA: "old-unrelated-sha"
        )
        let scanner = Self.scanner(mergeIndex: { _ in
            .success(WorktreeForgeMergeIndex(refsByHeadBranch: ["feature/a": [ref]]))
        })
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(!results[0].signals.contains { signal in
            if case .mergedOnForge = signal { return true } else { return false }
        })
        #expect(results[0].signals.contains(.notMerged))
        #expect(results[0].verdict == .active)
    }

    /// A branch name reused across two merged reviews must still match: the
    /// index has to retain every ref for a branch, not just the newest, or a
    /// worktree whose HEAD corresponds to the *older* merged review would be
    /// compared only against the newer SHA and wrongly read as not merged.
    @Test func olderRefForAReusedBranchNameStillMatches() async {
        let olderRef = MergedReviewRequestRef(
            number: 10,
            headRefName: "feature/a",
            url: URL(string: "https://github.com/o/r/pull/10")!,
            headSHA: "old-commit-sha"
        )
        let newerRef = MergedReviewRequestRef(
            number: 99,
            headRefName: "feature/a",
            url: URL(string: "https://github.com/o/r/pull/99")!,
            headSHA: "new-commit-sha"
        )
        var facts = Self.cleanFacts
        facts.headSHA = "old-commit-sha"
        let scanner = Self.scanner(
            facts: { _ in facts },
            mergeIndex: { _ in
                .success(WorktreeForgeMergeIndex(refsByHeadBranch: ["feature/a": [newerRef, olderRef]]))
            }
        )
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .candidate(confidence: .high))
        #expect(results[0].signals.contains(
            .mergedOnForge(identity: "#10", url: olderRef.url)
        ))
    }

    /// The core degradation rule: a forge failure must not manufacture a
    /// "not merged" answer.
    @Test func forgeFailureYieldsUnknownNotNotMerged() async {
        let scanner = Self.scanner(mergeIndex: { _ in
            .failure(CodeHostProviderError.cliMissing("gh"))
        })
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(!results[0].signals.contains(.notMerged))
        #expect(results[0].signals.contains { signal in
            if case .mergeStateUnknown = signal { return true } else { return false }
        })
    }

    /// A local merge-base check that succeeded is still reported, even when the
    /// forge could not be reached — the two checks are independent.
    @Test func localMergeSurvivesForgeFailure() async {
        var facts = Self.cleanFacts
        facts.isMergedLocally = true
        let scanner = Self.scanner(
            facts: { _ in facts },
            mergeIndex: { _ in .failure(CodeHostProviderError.cliMissing("gh")) }
        )
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .candidate(confidence: .medium))
        #expect(results[0].signals.contains(.mergedLocally(base: "main")))
    }

    @Test func branchAbsentFromForgeIndexIsNotMerged() async {
        let scanner = Self.scanner(mergeIndex: { _ in
            .success(WorktreeForgeMergeIndex(refsByHeadBranch: [:]))
        })
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].signals.contains(.notMerged))
        #expect(results[0].verdict == .active)
    }

    /// `unpushedCount` reports 1 when `@{u}` cannot be resolved, which is what
    /// happens after the forge deletes the branch on merge and a local prune
    /// drops the tracking ref. A branch the forge says is merged must not be
    /// held back as dirty by that artifact.
    @Test func mergedOnForgeSuppressesFalseUnpushedSignalFromPrunedUpstream() async {
        var facts = Self.cleanFacts
        facts.unpushedCommitCount = 1   // simulates a pruned/missing @{u}
        let ref = MergedReviewRequestRef(
            number: 42,
            headRefName: "feature/a",
            url: URL(string: "https://github.com/o/r/pull/42")!,
            headSHA: Self.localHeadSHA
        )
        let scanner = Self.scanner(
            facts: { _ in facts },
            mergeIndex: { _ in
                .success(WorktreeForgeMergeIndex(refsByHeadBranch: ["feature/a": [ref]]))
            }
        )
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .candidate(confidence: .high))
        #expect(!results[0].signals.contains { signal in
            if case .unpushedCommits = signal { return true } else { return false }
        })
    }

    /// The suppression is scoped to the forge-merged case only: a branch that
    /// is not merged still reports its real unpushed work.
    @Test func notMergedWorktreeStillReportsRealUnpushedCommits() async {
        var facts = Self.cleanFacts
        facts.unpushedCommitCount = 3
        let scanner = Self.scanner(
            facts: { _ in facts },
            mergeIndex: { _ in
                .success(WorktreeForgeMergeIndex(refsByHeadBranch: [:]))
            }
        )
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .dirty)
        #expect(results[0].signals.contains(.unpushedCommits(count: 3)))
    }

    /// Uncommitted work is never excused by a forge merge — only the unpushed
    /// signal is, and only because a pruned upstream cannot be told apart from
    /// an unpublished branch.
    @Test func mergedOnForgeStillBlocksOnUncommittedChanges() async {
        var facts = Self.cleanFacts
        facts.unpushedCommitCount = 1
        facts.hasUncommittedChanges = true
        let ref = MergedReviewRequestRef(
            number: 42,
            headRefName: "feature/a",
            url: URL(string: "https://github.com/o/r/pull/42")!,
            headSHA: Self.localHeadSHA
        )
        let scanner = Self.scanner(
            facts: { _ in facts },
            mergeIndex: { _ in
                .success(WorktreeForgeMergeIndex(refsByHeadBranch: ["feature/a": [ref]]))
            }
        )
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .dirty)
        #expect(results[0].signals.contains(.uncommittedChanges))
    }

    @Test func sshProjectShortCircuitsWithoutProbing() async {
        let probeCount = ProbeCounter()
        let scanner = Self.scanner(facts: { _ in
            await probeCount.increment()
            return Self.cleanFacts
        })
        let results = await Self.scan(
            scanner,
            project: Self.project(host: "devbox"),
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .excluded)
        #expect(results[0].signals.contains(.remoteWorktree))
        #expect(await probeCount.value == 0)
    }

    @Test func activeSessionsAreCarriedIntoTheProbe() async {
        let scanner = Self.scanner(activeSessionCount: { _ in 2 })
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .busy)
        #expect(results[0].signals.contains(.activeSessions(count: 2)))
    }

    /// `Worktree.lastActivity` is cached from the last topology refresh, not
    /// updated by ordinary commit activity while the app is open. A merged,
    /// freshly-touched worktree must not read as long-idle just because the
    /// cache is stale.
    @Test func freshActivityOverridesStaleCachedTimestamp() async {
        var facts = Self.cleanFacts
        facts.isMergedLocally = true
        facts.lastActivity = Self.now   // fresh: touched right now
        let scanner = Self.scanner(facts: { _ in facts })
        // The cached worktree looks idle (30 days old by the fixture default).
        let results = await Self.scan(
            scanner,
            worktrees: [Self.worktree(branch: "feature/a")]
        )
        #expect(results[0].verdict == .active)
        #expect(results[0].signals.contains(.recentActivity(days: 0)))
    }

    /// A worktree checked out today from an old, already-merged branch must
    /// not read as idle for the branch's own age — the worktree itself did
    /// not exist before it was created, regardless of what its branch's ref
    /// history says.
    @Test func idleClockNeverStartsBeforeTheWorktreeWasCreated() async {
        var facts = Self.cleanFacts
        facts.isMergedLocally = true
        facts.lastActivity = Self.now.addingTimeInterval(-60 * 86_400)   // an old branch
        let scanner = Self.scanner(facts: { _ in facts })
        let freshWorktree = Worktree(
            id: "/tmp/wt-feature-a",
            projectId: "p",
            name: "feature/a",
            branch: "feature/a",
            path: URL(fileURLWithPath: "/tmp/wt-feature-a"),
            status: .clean,
            lastActivity: Self.now.addingTimeInterval(-60 * 86_400),
            createdAt: Self.now   // created just now
        )
        let results = await Self.scan(scanner, worktrees: [freshWorktree])
        #expect(results[0].verdict == .active)
        #expect(results[0].signals.contains(.recentActivity(days: 0)))
    }

    @Test func resultsPreserveInputOrder() async {
        let scanner = Self.scanner()
        let worktrees = ["a", "b", "c"].map { Self.worktree(branch: "feature/\($0)") }
        let results = await Self.scan(scanner, worktrees: worktrees)
        #expect(results.map(\.worktree.branch)
                == ["feature/a", "feature/b", "feature/c"])
    }

    @Test func scanPublishesProgressForEveryWorktree() async {
        let scanner = Self.scanner()
        let worktrees = ["a", "b", "c"].map { Self.worktree(branch: "feature/\($0)") }
        let recorder = WorktreeCleanupUpdateRecorder()

        let results = await scanner.scan(
            project: Self.project(),
            worktrees: worktrees,
            baseBranch: "main",
            now: Self.now,
            idleThresholdDays: 14,
            onUpdate: { update in await recorder.append(update) }
        )
        let updates = await recorder.updates

        #expect(results.map(\.worktree.branch) == ["feature/a", "feature/b", "feature/c"])
        #expect(updates.map(\.completed) == [1, 2, 3])
        #expect(updates.allSatisfy { $0.total == 3 })
        #expect(Set(updates.map(\.candidate.id)) == Set(worktrees.map(\.id)))
    }

    @Test func statusPorcelainDistinguishesUntrackedFromModified() {
        let modified = WorktreeCleanupScanner.parseStatusPorcelain(" M Sources/A.swift\n")
        #expect(modified.hasUncommittedChanges)
        #expect(!modified.hasUntrackedFiles)

        let untracked = WorktreeCleanupScanner.parseStatusPorcelain("?? notes.txt\n")
        #expect(!untracked.hasUncommittedChanges)
        #expect(untracked.hasUntrackedFiles)

        let both = WorktreeCleanupScanner.parseStatusPorcelain("M  A.swift\n?? B.swift\n")
        #expect(both.hasUncommittedChanges)
        #expect(both.hasUntrackedFiles)

        let clean = WorktreeCleanupScanner.parseStatusPorcelain("")
        #expect(!clean.hasUncommittedChanges)
        #expect(!clean.hasUntrackedFiles)
    }

    /// A bare substring match would let branch `x` claim a stash that
    /// actually belongs to `feature/x`. The match must anchor on git's own
    /// `%gs` subject shapes.
    @Test func stashMatchDoesNotCollideOnBranchNameSubstrings() {
        let stashOnFeatureX = GitStash(
            ref: "stash@{0}",
            subject: "WIP on feature/x: abc1234 message",
            relativeTime: "2 days ago",
            sha: "abc1234"
        )
        #expect(!WorktreeCleanupScanner.isStash(stashOnFeatureX, forBranch: "x"))
        #expect(WorktreeCleanupScanner.isStash(stashOnFeatureX, forBranch: "feature/x"))

        let stashOnX = GitStash(
            ref: "stash@{1}",
            subject: "On x: custom message",
            relativeTime: "1 day ago",
            sha: "def5678"
        )
        #expect(WorktreeCleanupScanner.isStash(stashOnX, forBranch: "x"))
    }
}

private actor ProbeCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor WorktreeCleanupUpdateRecorder {
    private(set) var updates: [WorktreeCleanupScanUpdate] = []

    func append(_ update: WorktreeCleanupScanUpdate) {
        updates.append(update)
    }
}
