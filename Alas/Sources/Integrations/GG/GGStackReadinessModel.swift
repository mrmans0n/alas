import Foundation

struct GGSyncProgressPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        let position: Int
        let text: String
        var id: Int { position }
    }

    let liveStatus: String?
    let showsSpinner: Bool
    let rows: [Row]
}

struct GGStackReadinessProjection {
    @MainActor
    static func make(
        stackLoadState: GGStackLoadState,
        stack: GGStack?,
        action: GGStackActionState,
        selectedBaseBranch: String,
        behindBase: GitService.BehindStatus?,
        mergeOperation: MergeOperation?,
        effectiveConfig: GGEffectiveConfig,
        localChanges: GGLocalChangeStatistics,
        undoCandidate: GGUndoCandidate?
    ) -> GGStackReadinessModel? {
        guard stackLoadState == .loaded, let stack else { return nil }
        return GGStackReadinessModel.make(
            stack: stack,
            action: action,
            liveBehindBase: liveBehindBaseOverride(
                stack: stack,
                selectedBaseBranch: selectedBaseBranch,
                behindBase: behindBase
            ),
            hasBlockingGitOperation: hasBlockingGitOperation(
                mergeOperation: mergeOperation,
                pausedGGOperation: action.pausedOperation
            ),
            effectiveConfig: effectiveConfig,
            localChanges: localChanges,
            undoCandidate: undoCandidate
        )
    }

    static func liveBehindBaseOverride(
        stack: GGStack,
        selectedBaseBranch: String,
        behindBase: GitService.BehindStatus?
    ) -> Int? {
        guard selectedBaseBranch == stack.base else { return nil }
        return behindBase?.count
    }

    static func hasBlockingGitOperation(
        mergeOperation: MergeOperation?,
        pausedGGOperation: GGPausedOperation?
    ) -> Bool {
        mergeOperation != nil && pausedGGOperation == nil
    }
}

/// Pure presentation policy for the stack drawer. GG remains authoritative
/// at execution time; this model only selects the action the current snapshot
/// calls for and describes its effect.
struct GGStackReadinessModel: Equatable {
    struct Fact: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct Action: Equatable, Identifiable {
        enum Emphasis: Equatable { case primary, normal }
        let kind: GGStackActionKind
        let title: String
        let detail: String?
        let isEnabled: Bool
        let isInFlight: Bool
        let emphasis: Emphasis
        var id: String { "\(kind)" }
    }

    let title: String
    let summaryChip: String
    let facts: [Fact]
    let primaryActions: [Action]
    let overflowActions: [Action]
    let syncProgress: GGSyncProgressPresentation?
    let isRetainedSyncFailure: Bool
    let isPaused: Bool
    let actionSummary: String?
    let localChangesNote: String?

    /// Compatibility for callers that need to reason about every action.
    var actions: [Action] { primaryActions + overflowActions }

    @MainActor
    static func make(
        stack: GGStack,
        action: GGStackActionState,
        liveBehindBase: Int? = nil,
        hasBlockingGitOperation: Bool = false,
        effectiveConfig: GGEffectiveConfig = .defaults,
        localChanges: GGLocalChangeStatistics = .zero,
        undoCandidate: GGUndoCandidate? = nil
    ) -> GGStackReadinessModel {
        let merged = stack.entries.filter { $0.prState == .merged }.count
        let unsynced = max(0, stack.totalCommits - stack.syncedCommits)
        let behind = liveBehindBase ?? stack.behindBase ?? 0
        let isPaused = action.pausedOperation != nil
        let inFlight = action.inFlightAction
        let busy = inFlight != nil || hasBlockingGitOperation
        let rebaseThreshold = effectiveConfig.syncBehindThreshold

        let summaryChip: String = {
            if isPaused { return "paused" }
            if unsynced > 0 { return "\(unsynced) unsynced" }
            if behind > 0 { return "↓\(behind) behind" }
            return "\(merged)/\(stack.totalCommits) merged"
        }()

        let facts = [
            Fact(label: "Commits", value: "\(stack.totalCommits)"),
            Fact(label: "Merged", value: "\(merged)"),
            Fact(label: "Unsynced", value: "\(unsynced)"),
            Fact(label: "Behind base", value: "\(behind)"),
        ]

        let primaryActions: [Action]
        if isPaused {
            primaryActions = [
                makeAction(.continueOp, title: "Continue", enabled: !busy, inFlight: inFlight, emphasis: .primary),
                makeAction(.abortOp, title: "Abort", enabled: !busy, inFlight: inFlight),
            ]
        } else if behind > 0,
                  rebaseThreshold > 0,
                  !effectiveConfig.syncAutoRebase,
                  behind >= rebaseThreshold {
            primaryActions = [
                makeAction(
                    .rebase,
                    title: "Rebase onto \(stack.base)",
                    enabled: !busy,
                    inFlight: inFlight,
                    emphasis: .primary
                ),
            ]
        } else if unsynced > 0 || behind > 0 || stack.entries.contains(where: { $0.prState == nil }) {
            primaryActions = [
                makeAction(
                    .sync,
                    title: "Sync stack",
                    detail: rebaseThreshold > 0
                        && effectiveConfig.syncAutoRebase
                        && behind >= rebaseThreshold
                        ? "Includes rebase onto \(stack.base)"
                        : nil,
                    enabled: !busy,
                    inFlight: inFlight,
                    emphasis: .primary
                ),
            ]
        } else if hasLandablePrefix(stack) {
            primaryActions = [
                makeAction(.land, title: "Land ready", enabled: !busy, inFlight: inFlight, emphasis: .primary),
            ]
        } else {
            primaryActions = []
        }

        let mutableRegionCanReorder = stack.entries
            .split(whereSeparator: { $0.prState == .merged })
            .contains { $0.count > 1 }
        let overflowActions: [Action] = isPaused ? [] : [
            makeAction(
                .reorder,
                title: "Reorder Stack…",
                enabled: !busy && mutableRegionCanReorder && stack.entries.allSatisfy { $0.ggId != nil },
                inFlight: inFlight
            ),
            makeAction(.restack, title: "Restack…", enabled: !busy, inFlight: inFlight),
            makeAction(
                .undo,
                title: "Undo Last GG Operation",
                enabled: !busy && undoCandidate != nil,
                inFlight: inFlight
            ),
            makeAction(
                .clean,
                title: "Clean Merged Commits…",
                enabled: !busy && merged > 0,
                inFlight: inFlight
            ),
        ]

        let isRetainedSyncFailure = inFlight == nil
            && action.pausedOperation == nil
            && action.lastError != nil
            && !action.syncProgress.isEmpty
        let syncIsRelevant = inFlight == .sync
            || action.pausedOperation?.pausedBy == .sync
            || isRetainedSyncFailure
        return GGStackReadinessModel(
            title: "Stack · \(stack.name)",
            summaryChip: summaryChip,
            facts: facts,
            primaryActions: primaryActions,
            overflowActions: overflowActions,
            syncProgress: syncIsRelevant
                ? makeSyncProgress(
                    events: action.syncProgress,
                    isInFlight: inFlight == .sync,
                    hasTerminalFailure: action.syncHasTerminalFailure
                )
                : nil,
            isRetainedSyncFailure: isRetainedSyncFailure,
            isPaused: isPaused,
            actionSummary: inFlight == .sync ? nil : action.lastActionSummary,
            localChangesNote: primaryActions.contains(where: { $0.kind == .sync }) && localChanges.hasChanges
                ? "Local changes are not included"
                : nil
        )
    }

    @MainActor
    static func makePausedFallback(action: GGStackActionState) -> GGStackReadinessModel? {
        guard action.pausedOperation != nil else { return nil }
        let inFlight = action.inFlightAction
        let busy = inFlight != nil
        let syncIsRelevant = inFlight == .sync
            || action.pausedOperation?.pausedBy == .sync
            || (inFlight == nil && action.lastError != nil && !action.syncProgress.isEmpty)
        return GGStackReadinessModel(
            title: "Stack operation",
            summaryChip: "paused",
            facts: [],
            primaryActions: [
                makeAction(.continueOp, title: "Continue", enabled: !busy, inFlight: inFlight, emphasis: .primary),
                makeAction(.abortOp, title: "Abort", enabled: !busy, inFlight: inFlight),
            ],
            overflowActions: [],
            syncProgress: syncIsRelevant
                ? makeSyncProgress(
                    events: action.syncProgress,
                    isInFlight: inFlight == .sync,
                    hasTerminalFailure: action.syncHasTerminalFailure
                )
                : nil,
            isRetainedSyncFailure: false,
            isPaused: true,
            actionSummary: nil,
            localChangesNote: nil
        )
    }

    private static func makeAction(
        _ kind: GGStackActionKind,
        title: String,
        detail: String? = nil,
        enabled: Bool,
        inFlight: GGStackActionKind?,
        emphasis: Action.Emphasis = .normal
    ) -> Action {
        Action(
            kind: kind,
            title: title,
            detail: detail,
            isEnabled: enabled,
            isInFlight: inFlight == kind,
            emphasis: emphasis
        )
    }

    private static func hasLandablePrefix(_ stack: GGStack) -> Bool {
        for entry in stack.entries.sorted(by: { $0.position < $1.position }) {
            if entry.prState == .merged { continue }
            return entry.prState == .open
                && entry.approved
                && (entry.ciStatus == nil || entry.ciStatus == .success)
        }
        return false
    }

    private struct SyncEntryProgress {
        var title: String?
        var didPush = false
        var failedToPush = false
        var row: String?
    }

    private static func makeSyncProgress(
        events: [GGSyncEvent],
        isInFlight: Bool,
        hasTerminalFailure: Bool
    ) -> GGSyncProgressPresentation {
        var entries: [Int: SyncEntryProgress] = [:]
        var completed: Set<Int> = []
        var totalEntries: Int?
        var liveStatus: String? = events.isEmpty && isInFlight ? "Preparing sync…" : nil
        var sawSummary = false
        var hasTerminalEventError = false

        func titledStatus(_ verb: String, position: Int) -> String {
            guard let title = entries[position]?.title else { return "\(verb) [\(position)]…" }
            return "\(verb) [\(position)] \(title)…"
        }

        func countStatus() -> String {
            guard let totalEntries else { return "Finishing sync…" }
            return "Syncing \(completed.count) of \(totalEntries) commit\(totalEntries == 1 ? "" : "s")…"
        }

        func pushedPrefix(position: Int) -> String {
            entries[position]?.didPush == true ? "Pushed · " : ""
        }

        for event in events {
            switch event {
            case .start(let total):
                totalEntries = total
                liveStatus = "Syncing 0 of \(total) commit\(total == 1 ? "" : "s")…"
            case .entryStarted(let position, let title):
                entries[position, default: .init()].title = title
                liveStatus = "Syncing [\(position)] \(title)…"
            case .pushStarted(let position):
                liveStatus = titledStatus("Pushing", position: position)
            case .pushDone(let position, _):
                entries[position, default: .init()].didPush = true
                entries[position, default: .init()].row = "[\(position)] Pushed"
                liveStatus = titledStatus("Finishing", position: position)
            case .prCreated(let position, let number, _, _):
                let prefix = pushedPrefix(position: position)
                entries[position, default: .init()].row = "[\(position)] \(prefix)PR #\(number) created"
                completed.insert(position)
                liveStatus = countStatus()
            case .prUpdated(let position, let number, let action):
                let result = switch action {
                case "updated": " updated"
                case "unchanged", "up_to_date": " up to date"
                case "recreated": " recreated"
                default: ""
                }
                let prefix = pushedPrefix(position: position)
                entries[position, default: .init()].row = "[\(position)] \(prefix)PR #\(number)\(result)"
                completed.insert(position)
                liveStatus = countStatus()
            case .prSkippedClosed(let position, let number):
                let prefix = pushedPrefix(position: position)
                entries[position, default: .init()].row = "[\(position)] \(prefix)PR #\(number) already closed"
                completed.insert(position)
                liveStatus = countStatus()
            case .error(let position, let operation, _):
                if let position {
                    var entry = entries[position, default: .init()]
                    entry.failedToPush = entry.failedToPush || operation == "push"
                    let failure = entry.failedToPush ? "Failed to push" : "Failed"
                    entry.row = "[\(position)] \(failure)"
                    entries[position] = entry
                    completed.insert(position)
                    liveStatus = countStatus()
                } else {
                    liveStatus = nil
                    hasTerminalEventError = true
                }
            case .summary:
                liveStatus = nil
                sawSummary = true
            }
        }

        if !isInFlight || hasTerminalFailure || hasTerminalEventError { liveStatus = nil }
        return GGSyncProgressPresentation(
            liveStatus: liveStatus,
            showsSpinner: isInFlight && !sawSummary && !hasTerminalFailure && !hasTerminalEventError,
            rows: entries.compactMap { position, entry in
                entry.row.map { .init(position: position, text: $0) }
            }.sorted { $0.position < $1.position }
        )
    }
}
