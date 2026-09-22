import Foundation

/// Why Alas refuses to start `gg land` at a given stack entry.
enum GGLandBlocker: Equatable, Sendable {
    case alreadyMerged
    case reviewClosed
    case reviewIsDraft
    case reviewMissing
    case ciFailed
    /// Legacy gg (no `--wait` streaming): the target must already be mergeable.
    case notReady
    case lowerCommitBlocked
    /// Legacy gg: a lower commit is not fully approved/green yet.
    case lowerCommitNotReady

    func message(reviewLabel: String) -> String {
        switch self {
        case .alreadyMerged:
            return "This commit is already merged."
        case .reviewClosed:
            return "This commit's \(reviewLabel) is closed."
        case .reviewIsDraft:
            return "Mark this commit's \(reviewLabel) ready for review first."
        case .reviewMissing:
            return "Sync the stack to open a \(reviewLabel) for this commit first."
        case .ciFailed:
            return "CI failed for this commit."
        case .notReady:
            return "This commit is not ready to land."
        case .lowerCommitBlocked:
            return "A lower commit can't be landed yet."
        case .lowerCommitNotReady:
            return "A lower commit is not ready to land."
        }
    }
}

/// Single source of truth for whether Alas will start a `gg land --until`.
///
/// `gg land --wait` runs its own readiness poll loop (approvals, CI, merge
/// train), so when the installed gg can stream land events Alas only blocks
/// the states that polling can never resolve: an already-merged, closed,
/// draft, review-less, or red-CI commit. Everything else — including a
/// review nobody has approved yet — starts and waits, exactly like the CLI.
///
/// Older gg builds merge in one shot with no wait loop, so they still require
/// full readiness before the action is offered.
enum GGLandReadiness {
    /// Nil when a land may be started at `target`.
    static func blocker(
        target: GGStackEntry,
        in stack: GGStack,
        canWaitForReadiness: Bool
    ) -> GGLandBlocker? {
        if let blocker = targetBlocker(target, canWaitForReadiness: canWaitForReadiness) {
            return blocker
        }
        let lowerEntries = stack.entries.filter { $0.position < target.position }
        guard lowerEntries.allSatisfy({ entry in
            entry.prState == .merged
                || targetBlocker(entry, canWaitForReadiness: canWaitForReadiness) == nil
        }) else {
            return canWaitForReadiness ? .lowerCommitBlocked : .lowerCommitNotReady
        }
        return nil
    }

    static func canStartLand(
        target: GGStackEntry,
        in stack: GGStack,
        canWaitForReadiness: Bool
    ) -> Bool {
        blocker(target: target, in: stack, canWaitForReadiness: canWaitForReadiness) == nil
    }

    /// Entries `gg land --until target` will act on: everything at or below
    /// the target that is not already merged. Unlike a ready-commit count this
    /// depends only on local stack structure, so it stays stable while
    /// approvals and CI land underneath a staged confirmation.
    static func scope(upTo target: GGStackEntry, in stack: GGStack) -> [GGStackEntry] {
        stack.entries
            .filter { $0.position <= target.position && $0.prState != .merged }
            .sorted { $0.position < $1.position }
    }

    /// Entries in scope that `gg land --wait` will have to poll before merging.
    static func waitingEntries(upTo target: GGStackEntry, in stack: GGStack) -> [GGStackEntry] {
        scope(upTo: target, in: stack).filter { !isMergeable($0) }
    }

    /// Open, approved, and not red — `gg land` merges this one immediately.
    static func isMergeable(_ entry: GGStackEntry) -> Bool {
        entry.prState == .open && entry.approved && (entry.ciStatus == nil || entry.ciStatus == .success)
    }

    private static func targetBlocker(
        _ entry: GGStackEntry,
        canWaitForReadiness: Bool
    ) -> GGLandBlocker? {
        guard canWaitForReadiness else {
            return isMergeable(entry) ? nil : .notReady
        }
        // `prState == .open` is gg's own signal that a review exists; the
        // number is display metadata and may lag behind it.
        switch entry.prState {
        case .merged:
            return .alreadyMerged
        case .closed:
            return .reviewClosed
        case .draft:
            return .reviewIsDraft
        case nil:
            return .reviewMissing
        case .open:
            break
        }
        // A red pipeline is terminal for gg's wait loop; re-running CI flips
        // the entry back to pending/running and re-enables the action.
        if entry.ciStatus == .failed || entry.ciStatus == .canceled { return .ciFailed }
        return nil
    }
}
