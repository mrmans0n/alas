import Foundation

/// How a worktree's branch relates to its base, and — critically — how
/// confident we are in that answer. A code-host check that could not be
/// performed yields `.unknown`, never `.notMerged`: "we could not ask GitHub"
/// and "GitHub says this is not merged" are different facts and the UI must
/// not conflate them.
enum WorktreeMergeState: Equatable, Sendable {
    /// The code host reports the branch's review request as merged.
    case mergedOnForge(identity: String, url: URL)
    /// `git merge-base --is-ancestor HEAD <base>` succeeded locally.
    case mergedLocally(base: String)
    /// Checked, and the branch is genuinely not merged.
    case notMerged
    /// The check could not be completed. `reason` is surfaced to the user.
    case unknown(reason: String)
}

/// The raw facts about one worktree, collected by `WorktreeCleanupScanner`
/// and consumed by `WorktreeCleanupClassifier`. Deliberately free of I/O and
/// of any git or code-host type, so classification is a pure function.
struct WorktreeCleanupProbe: Equatable, Sendable {
    var isMainWorktree: Bool
    var isRemote: Bool
    var hasUncommittedChanges: Bool
    var hasUntrackedFiles: Bool
    var unpushedCommitCount: Int
    var stashCount: Int
    var activeSessionCount: Int
    var operationInFlight: Bool
    var lastActivity: Date
    var mergeState: WorktreeMergeState
}

/// One reason a worktree does or does not qualify for cleanup. Signals carry
/// their own user-facing copy so the "why not" text is testable data rather
/// than logic buried in a view.
enum WorktreeCleanupSignal: Equatable, Hashable, Sendable {
    // Qualifying
    case mergedOnForge(identity: String, url: URL)
    case mergedLocally(base: String)
    case noUncommittedChanges
    case fullyPushed
    case noStashes
    case noActiveSessions
    case idle(days: Int)

    // Blocking
    case uncommittedChanges
    case untrackedFiles
    case unpushedCommits(count: Int)
    case stashes(count: Int)
    case activeSessions(count: Int)
    case recentActivity(days: Int)
    case notMerged
    case mergeStateUnknown(reason: String)

    // Excluding
    case mainWorktree
    case remoteWorktree
    case operationInFlight

    /// True when this signal counts *against* cleanup. Drives both the row's
    /// icon and its sort position — blocking signals render first so the user
    /// reads the objection before the reassurance.
    ///
    /// Blocking is not the same as disqualifying. `.mergeStateUnknown` is
    /// blocking (it is a caution, and must not be shown with a reassuring
    /// checkmark) but a worktree carrying it can still be a low-confidence
    /// candidate when it is otherwise clean and long idle. The verdict, not
    /// this flag, decides candidacy.
    var isBlocking: Bool {
        switch self {
        case .mergedOnForge, .mergedLocally, .noUncommittedChanges,
             .fullyPushed, .noStashes, .noActiveSessions, .idle:
            return false
        case .uncommittedChanges, .untrackedFiles, .unpushedCommits,
             .stashes, .activeSessions, .recentActivity, .notMerged,
             .mergeStateUnknown, .mainWorktree, .remoteWorktree,
             .operationInFlight:
            return true
        }
    }

    var label: String {
        switch self {
        case .mergedOnForge(let identity, _):
            return "Merged on the code host (\(identity))"
        case .mergedLocally(let base):
            return "Merged locally into \(base)"
        case .noUncommittedChanges:
            return "No uncommitted changes"
        case .fullyPushed:
            return "All commits pushed"
        case .noStashes:
            return "No stashes"
        case .noActiveSessions:
            return "No active sessions"
        case .idle(let days):
            return "Untouched for \(days) \(days == 1 ? "day" : "days")"
        case .uncommittedChanges:
            return "Has uncommitted changes"
        case .untrackedFiles:
            return "Has untracked files"
        case .unpushedCommits(let count):
            return "\(count) unpushed \(count == 1 ? "commit" : "commits")"
        case .stashes(let count):
            return "\(count) \(count == 1 ? "stash" : "stashes")"
        case .activeSessions(let count):
            return "\(count) active \(count == 1 ? "session" : "sessions")"
        case .recentActivity(let days):
            return days == 0
                ? "Active today"
                : "Active \(days) \(days == 1 ? "day" : "days") ago"
        case .notMerged:
            return "Not merged"
        case .mergeStateUnknown(let reason):
            return "Merge state unknown — \(reason)"
        case .mainWorktree:
            return "Main worktree — never removed"
        case .remoteWorktree:
            return "Remote worktree — cleanup is not supported yet"
        case .operationInFlight:
            return "Another operation is in progress"
        }
    }
}

/// The headline verdict for a worktree, collapsing its signal set.
enum WorktreeCleanupVerdict: Equatable, Sendable {
    /// Safe to clean up. Confidence tracks how the merge was established.
    case candidate(confidence: Confidence)
    /// Agent or terminal sessions are live, or an app operation is running.
    case busy
    /// Uncommitted changes, untracked files, unpushed commits, or stashes.
    case dirty
    /// Not merged, or merged but still being worked on.
    case active
    /// Structurally ineligible: the main worktree, or a remote/SSH one.
    case excluded

    enum Confidence: Equatable, Sendable {
        /// The code host confirmed the merge.
        case high
        /// Only a local `merge-base` check confirmed it.
        case medium
        /// Merge state is unknown; the worktree simply looks abandoned.
        case low
    }
}

struct WorktreeCleanupCandidate: Identifiable, Equatable, Sendable {
    let worktree: Worktree
    let verdict: WorktreeCleanupVerdict
    /// Blocking signals first, so the UI leads with the disqualifying reason.
    let signals: [WorktreeCleanupSignal]

    var id: String { worktree.id }

    /// Pre-checked in the cleanup sheet.
    var isSelectedByDefault: Bool {
        if case .candidate = verdict { return true }
        return false
    }

    /// Whether the user may override and select this row anyway. Dirty and
    /// busy rows are selectable — that is the per-item override. Excluded
    /// rows never are, which is what keeps bulk delete off a main worktree.
    var isSelectable: Bool {
        verdict != .excluded
    }
}
