import Foundation

/// Turns collected facts into a cleanup verdict. Pure and synchronous: given
/// the same probe and clock it always produces the same answer, which is what
/// makes the whole classification surface exhaustively testable.
enum WorktreeCleanupClassifier {
    static func classify(
        worktree: Worktree,
        probe: WorktreeCleanupProbe,
        now: Date,
        idleThresholdDays: Int
    ) -> WorktreeCleanupCandidate {
        let idleDays = daysSince(probe.lastActivity, now: now)

        // Exclusion outranks everything: a main or remote worktree is never
        // offered for cleanup regardless of how clean or idle it looks.
        if worktree.isMainWorktree == true || probe.isMainWorktree {
            return WorktreeCleanupCandidate(
                worktree: worktree,
                verdict: .excluded,
                signals: [.mainWorktree]
            )
        }
        if probe.isRemote {
            return WorktreeCleanupCandidate(
                worktree: worktree,
                verdict: .excluded,
                signals: [.remoteWorktree]
            )
        }
        // A detached HEAD's commits are reachable only via that worktree's
        // own HEAD. Removing it — even with git's own dirty-tree protections
        // satisfied — makes those commits unreachable and eventually
        // GC-eligible, unlike a branch's commits, which stay reachable via
        // the branch ref regardless of unpushed status. Never offered, and
        // never selectable via the per-item override.
        if worktree.branch == "(detached)" {
            return WorktreeCleanupCandidate(
                worktree: worktree,
                verdict: .excluded,
                signals: [.detachedHead]
            )
        }

        var blocking: [WorktreeCleanupSignal] = []
        var qualifying: [WorktreeCleanupSignal] = []

        // Busy
        if probe.operationInFlight { blocking.append(.operationInFlight) }
        if probe.activeSessionCount > 0 {
            blocking.append(.activeSessions(count: probe.activeSessionCount))
        } else {
            qualifying.append(.noActiveSessions)
        }
        let isBusy = probe.operationInFlight || probe.activeSessionCount > 0

        // Dirty
        if probe.hasUncommittedChanges { blocking.append(.uncommittedChanges) }
        if probe.hasUntrackedFiles { blocking.append(.untrackedFiles) }
        if !probe.hasUncommittedChanges && !probe.hasUntrackedFiles {
            qualifying.append(.noUncommittedChanges)
        }
        if probe.unpushedCommitCount > 0 {
            blocking.append(.unpushedCommits(count: probe.unpushedCommitCount))
        } else {
            qualifying.append(.fullyPushed)
        }
        if probe.stashCount > 0 {
            blocking.append(.stashes(count: probe.stashCount))
        } else {
            qualifying.append(.noStashes)
        }
        let isDirty = probe.hasUncommittedChanges
            || probe.hasUntrackedFiles
            || probe.unpushedCommitCount > 0
            || probe.stashCount > 0

        // Merge state
        var mergeConfidence: WorktreeCleanupVerdict.Confidence?
        switch probe.mergeState {
        case .mergedOnForge(let identity, let url):
            qualifying.append(.mergedOnForge(identity: identity, url: url))
            mergeConfidence = .high
        case .mergedLocally(let base):
            qualifying.append(.mergedLocally(base: base))
            mergeConfidence = .medium
        case .unknown(let reason):
            blocking.append(.mergeStateUnknown(reason: reason))
            mergeConfidence = .low
        case .notMerged:
            blocking.append(.notMerged)
            mergeConfidence = nil
        }

        // Staleness
        let isIdle = idleDays >= idleThresholdDays
        if isIdle {
            qualifying.append(.idle(days: idleDays))
        } else {
            blocking.append(.recentActivity(days: idleDays))
        }

        let signals = orderedSignals(blocking: blocking, qualifying: qualifying)

        // Precedence: busy, then dirty, then merged-and-idle decides.
        let verdict: WorktreeCleanupVerdict
        if isBusy {
            verdict = .busy
        } else if isDirty {
            verdict = .dirty
        } else if let confidence = mergeConfidence, isIdle {
            verdict = .candidate(confidence: confidence)
        } else {
            verdict = .active
        }

        return WorktreeCleanupCandidate(
            worktree: worktree,
            verdict: verdict,
            signals: signals
        )
    }

    /// Whole days elapsed, floored, never negative — a worktree whose mtime is
    /// in the future (clock skew, restored backup) reads as "active today"
    /// rather than as absurdly stale.
    static func daysSince(_ date: Date, now: Date) -> Int {
        let seconds = now.timeIntervalSince(date)
        guard seconds > 0 else { return 0 }
        return Int(seconds / 86_400)
    }

    private static func orderedSignals(
        blocking: [WorktreeCleanupSignal],
        qualifying: [WorktreeCleanupSignal]
    ) -> [WorktreeCleanupSignal] {
        blocking + qualifying
    }
}
