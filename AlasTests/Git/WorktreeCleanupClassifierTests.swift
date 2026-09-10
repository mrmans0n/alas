import Testing
import Foundation
@testable import Alas

struct WorktreeCleanupClassifierTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func worktree(
        branch: String = "feature/x",
        isMain: Bool = false
    ) -> Worktree {
        Worktree(
            id: "/tmp/wt-\(branch)",
            projectId: "p",
            name: branch,
            branch: branch,
            path: URL(fileURLWithPath: "/tmp/wt-\(branch)"),
            isMainWorktree: isMain,
            status: .clean,
            lastActivity: now
        )
    }

    /// Baseline: merged on the forge, clean, pushed, idle, nothing running.
    private static func idealProbe(daysIdle: Int = 30) -> WorktreeCleanupProbe {
        WorktreeCleanupProbe(
            isMainWorktree: false,
            isRemote: false,
            hasUncommittedChanges: false,
            hasUntrackedFiles: false,
            unpushedCommitCount: 0,
            stashCount: 0,
            activeSessionCount: 0,
            operationInFlight: false,
            lastActivity: now.addingTimeInterval(-Double(daysIdle) * 86_400),
            mergeState: .mergedOnForge(
                identity: "GitHub #42",
                url: URL(string: "https://github.com/o/r/pull/42")!
            )
        )
    }

    private static func classify(
        _ probe: WorktreeCleanupProbe,
        worktree: Worktree = worktree(),
        idleThresholdDays: Int = 14
    ) -> WorktreeCleanupCandidate {
        WorktreeCleanupClassifier.classify(
            worktree: worktree,
            probe: probe,
            now: now,
            idleThresholdDays: idleThresholdDays
        )
    }

    @Test func forgeMergedIdleWorktreeIsHighConfidenceCandidate() {
        let result = Self.classify(Self.idealProbe())
        #expect(result.verdict == .candidate(confidence: .high))
        #expect(result.isSelectedByDefault)
        #expect(result.signals.contains {
            if case .mergedOnForge = $0 { return true } else { return false }
        })
    }

    @Test func locallyMergedWorktreeIsMediumConfidence() {
        var probe = Self.idealProbe()
        probe.mergeState = .mergedLocally(base: "main")
        let result = Self.classify(probe)
        #expect(result.verdict == .candidate(confidence: .medium))
        #expect(result.signals.contains(.mergedLocally(base: "main")))
    }

    /// The acceptance criterion: a code-host check that failed must not be
    /// presented the same way as a branch that genuinely is not merged.
    @Test func unknownMergeStateIsNeverReportedAsNotMerged() {
        var probe = Self.idealProbe()
        probe.mergeState = .unknown(reason: "gh pr list failed")
        let result = Self.classify(probe)
        #expect(!result.signals.contains(.notMerged))
        #expect(result.signals.contains(.mergeStateUnknown(reason: "gh pr list failed")))
    }

    @Test func unknownMergeStateWithLongIdleIsLowConfidenceCandidate() {
        var probe = Self.idealProbe(daysIdle: 30)
        probe.mergeState = .unknown(reason: "gh pr list failed")
        #expect(Self.classify(probe).verdict == .candidate(confidence: .low))
    }

    /// `isBlocking` drives icon and sort order, not candidacy — a clean, long
    /// idle worktree whose merge state could not be determined is still offered
    /// (at low confidence) with the caution shown alongside it.
    @Test func lowConfidenceCandidateIsStillSelectedDespiteACautionSignal() {
        var probe = Self.idealProbe(daysIdle: 30)
        probe.mergeState = .unknown(reason: "gh pr list failed")
        let result = Self.classify(probe)
        #expect(result.isSelectedByDefault)
        #expect(result.signals.contains { $0.isBlocking })
    }

    @Test func notMergedWorktreeIsNeverACandidate() {
        var probe = Self.idealProbe(daysIdle: 90)
        probe.mergeState = .notMerged
        let result = Self.classify(probe)
        #expect(result.verdict == .active)
        #expect(result.signals.contains(.notMerged))
    }

    @Test func uncommittedChangesBlockCandidacyWithVisibleReason() {
        var probe = Self.idealProbe()
        probe.hasUncommittedChanges = true
        let result = Self.classify(probe)
        #expect(result.verdict == .dirty)
        #expect(result.signals.first == .uncommittedChanges)
        #expect(!result.isSelectedByDefault)
        #expect(result.isSelectable)
    }

    @Test func untrackedFilesBlockCandidacy() {
        var probe = Self.idealProbe()
        probe.hasUntrackedFiles = true
        let result = Self.classify(probe)
        #expect(result.verdict == .dirty)
        #expect(result.signals.contains(.untrackedFiles))
    }

    @Test func unpushedCommitsBlockCandidacy() {
        var probe = Self.idealProbe()
        probe.unpushedCommitCount = 3
        let result = Self.classify(probe)
        #expect(result.verdict == .dirty)
        #expect(result.signals.contains(.unpushedCommits(count: 3)))
    }

    @Test func stashesBlockCandidacy() {
        var probe = Self.idealProbe()
        probe.stashCount = 2
        let result = Self.classify(probe)
        #expect(result.verdict == .dirty)
        #expect(result.signals.contains(.stashes(count: 2)))
    }

    @Test func activeSessionsBlockCandidacyAndOutrankDirtiness() {
        var probe = Self.idealProbe()
        probe.activeSessionCount = 1
        probe.hasUncommittedChanges = true
        let result = Self.classify(probe)
        #expect(result.verdict == .busy)
        #expect(result.signals.contains(.activeSessions(count: 1)))
    }

    @Test func inFlightOperationMakesWorktreeBusy() {
        var probe = Self.idealProbe()
        probe.operationInFlight = true
        #expect(Self.classify(probe).verdict == .busy)
    }

    @Test func recentlyTouchedMergedWorktreeIsActiveNotACandidate() {
        let probe = Self.idealProbe(daysIdle: 2)
        let result = Self.classify(probe, idleThresholdDays: 14)
        #expect(result.verdict == .active)
        #expect(result.signals.contains(.recentActivity(days: 2)))
    }

    @Test func idleThresholdBoundaryIsInclusive() {
        let probe = Self.idealProbe(daysIdle: 14)
        #expect(Self.classify(probe, idleThresholdDays: 14).verdict
                == .candidate(confidence: .high))
    }

    @Test func mainWorktreeIsExcludedAndUnselectable() {
        let result = Self.classify(
            Self.idealProbe(),
            worktree: Self.worktree(branch: "main", isMain: true)
        )
        #expect(result.verdict == .excluded)
        #expect(result.signals.contains(.mainWorktree))
        #expect(!result.isSelectable)
    }

    @Test func mainWorktreeExclusionOutranksBusyAndDirty() {
        var probe = Self.idealProbe()
        probe.isMainWorktree = true
        probe.activeSessionCount = 4
        probe.hasUncommittedChanges = true
        let result = Self.classify(
            probe,
            worktree: Self.worktree(branch: "main", isMain: true)
        )
        #expect(result.verdict == .excluded)
        #expect(!result.isSelectable)
    }

    @Test func remoteWorktreeIsExcludedWithExplanation() {
        var probe = Self.idealProbe()
        probe.isRemote = true
        let result = Self.classify(probe)
        #expect(result.verdict == .excluded)
        #expect(result.signals.contains(.remoteWorktree))
        #expect(!result.isSelectable)
        #expect(WorktreeCleanupSignal.remoteWorktree.label
                == "Remote worktree — cleanup is not supported yet")
    }

    @Test func blockingSignalsSortBeforeQualifyingOnes() {
        var probe = Self.idealProbe()
        probe.hasUncommittedChanges = true
        let signals = Self.classify(probe).signals
        let firstQualifying = signals.firstIndex { !$0.isBlocking } ?? signals.count
        let lastBlocking = signals.lastIndex { $0.isBlocking } ?? -1
        #expect(lastBlocking < firstQualifying)
    }

    @Test func everySignalHasANonEmptyLabel() {
        var probe = Self.idealProbe()
        probe.hasUncommittedChanges = true
        probe.hasUntrackedFiles = true
        probe.unpushedCommitCount = 1
        probe.stashCount = 1
        probe.activeSessionCount = 1
        for signal in Self.classify(probe).signals {
            #expect(!signal.label.isEmpty)
        }
    }
}
