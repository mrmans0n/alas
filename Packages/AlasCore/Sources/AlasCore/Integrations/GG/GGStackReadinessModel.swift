import Foundation

public struct GGSyncProgressPresentation: Equatable, Sendable {
    public struct Step: Equatable, Identifiable, Sendable {
        public enum State: Equatable, Sendable { case pending, current, complete, failed }

        public let id: String
        public let title: String
        public let detail: String
        public let state: State

        public init(id: String, title: String, detail: String, state: State) {
            self.id = id
            self.title = title
            self.detail = detail
            self.state = state
        }
    }

    public struct Row: Equatable, Identifiable, Sendable {
        public let position: Int
        public let text: String
        public var id: Int { position }

        public init(position: Int, text: String) {
            self.position = position
            self.text = text
        }
    }

    public let liveStatus: String?
    public let showsSpinner: Bool
    public let steps: [Step]
    public let rows: [Row]

    public init(liveStatus: String?, showsSpinner: Bool, steps: [Step], rows: [Row]) {
        self.liveStatus = liveStatus
        self.showsSpinner = showsSpinner
        self.steps = steps
        self.rows = rows
    }
}

public struct GGStackReadinessProjection: Sendable {
    @MainActor
    public static func make(
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

    public static func liveBehindBaseOverride(
        stack: GGStack,
        selectedBaseBranch: String,
        behindBase: GitService.BehindStatus?
    ) -> Int? {
        guard selectedBaseBranch == stack.base else { return nil }
        return behindBase?.count
    }

    public static func effectiveBehindBase(
        stack: GGStack,
        selectedBaseBranch: String,
        behindBase: GitService.BehindStatus?
    ) -> Int {
        liveBehindBaseOverride(
            stack: stack,
            selectedBaseBranch: selectedBaseBranch,
            behindBase: behindBase
        ) ?? stack.behindBase ?? 0
    }

    public static func hasBlockingGitOperation(
        mergeOperation: MergeOperation?,
        pausedGGOperation: GGPausedOperation?
    ) -> Bool {
        mergeOperation != nil && pausedGGOperation == nil
    }

    public init() {
    }
}

/// Pure presentation policy for the stack drawer. GG remains authoritative
/// at execution time; this model only selects the action the current snapshot
/// calls for and describes its effect.
public struct GGStackReadinessModel: Equatable, Sendable {
    public struct Fact: Equatable, Identifiable, Sendable {
        public let label: String
        public let value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Action: Equatable, Identifiable, Sendable {
        public enum Emphasis: Equatable, Sendable { case primary, normal }
        public let kind: GGStackActionKind
        public let title: String
        public let detail: String?
        public let isEnabled: Bool
        public let isInFlight: Bool
        public let emphasis: Emphasis
        public var id: String { "\(kind)" }

        public init(kind: GGStackActionKind, title: String, detail: String?, isEnabled: Bool, isInFlight: Bool, emphasis: Emphasis) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.isEnabled = isEnabled
            self.isInFlight = isInFlight
            self.emphasis = emphasis
        }
    }

    public let title: String
    public let summaryChip: String
    public let facts: [Fact]
    public let primaryActions: [Action]
    public let overflowActions: [Action]
    public let syncProgress: GGSyncProgressPresentation?
    public let isRetainedSyncFailure: Bool
    public let isPaused: Bool
    public let actionSummary: String?
    public let localChangesNote: String?

    /// Compatibility for callers that need to reason about every action.
    public var actions: [Action] { primaryActions + overflowActions }

    @MainActor
    public static func make(
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
                    hasTerminalFailure: action.syncHasTerminalFailure,
                    base: stack.base,
                    behindBase: behind,
                    effectiveConfig: effectiveConfig
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
    public static func makePausedFallback(action: GGStackActionState) -> GGStackReadinessModel? {
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
                    hasTerminalFailure: action.syncHasTerminalFailure,
                    base: "base",
                    behindBase: 0,
                    effectiveConfig: .defaults
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

        public init(title: String? = nil, didPush: Bool = false, failedToPush: Bool = false, row: String? = nil) {
            self.title = title
            self.didPush = didPush
            self.failedToPush = failedToPush
            self.row = row
        }
    }

    @MainActor
    public static func syncProgress(
        action: GGStackActionState,
        base: String,
        behindBase: Int,
        effectiveConfig: GGEffectiveConfig
    ) -> GGSyncProgressPresentation? {
        let isRetainedFailure = action.inFlightAction == nil
            && action.lastError != nil
            && !action.syncProgress.isEmpty
        guard action.inFlightAction == .sync
                || action.pausedOperation?.pausedBy == .sync
                || isRetainedFailure
        else { return nil }
        return makeSyncProgress(
            events: action.syncProgress,
            isInFlight: action.inFlightAction == .sync,
            hasTerminalFailure: action.syncHasTerminalFailure,
            base: base,
            behindBase: behindBase,
            effectiveConfig: effectiveConfig
        )
    }

    private static func makeSyncProgress(
        events: [GGSyncEvent],
        isInFlight: Bool,
        hasTerminalFailure: Bool,
        base: String,
        behindBase: Int,
        effectiveConfig: GGEffectiveConfig
    ) -> GGSyncProgressPresentation {
        var entries: [Int: SyncEntryProgress] = [:]
        var completed: Set<Int> = []
        var totalEntries: Int?
        var liveStatus: String? = events.isEmpty && isInFlight ? "Preparing stack…" : nil
        var sawSummary = false
        var hasTerminalEventError = false
        var hasEntryError = false
        var sawStart = false
        var sawPREvent = false

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
                sawStart = true
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
                sawPREvent = true
                let prefix = pushedPrefix(position: position)
                entries[position, default: .init()].row = "[\(position)] \(prefix)PR #\(number) created"
                completed.insert(position)
                liveStatus = countStatus()
            case .prUpdated(let position, let number, let action):
                sawPREvent = true
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
                sawPREvent = true
                let prefix = pushedPrefix(position: position)
                entries[position, default: .init()].row = "[\(position)] \(prefix)PR #\(number) already closed"
                completed.insert(position)
                liveStatus = countStatus()
            case .error(let position, let operation, _):
                if let position {
                    hasEntryError = true
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

        let summaryEntryFailure = sawSummary && hasEntryError
        let terminalFailure = hasTerminalFailure || hasTerminalEventError || summaryEntryFailure
        let summaryFailure = sawSummary && terminalFailure
        if sawSummary && isInFlight && !terminalFailure {
            liveStatus = "Refreshing Changes…"
        } else if !isInFlight || terminalFailure {
            liveStatus = nil
        }
        let preparationDetails = [
            "Checking base",
            effectiveConfig.syncAutoRebase
                && effectiveConfig.syncBehindThreshold > 0
                && behindBase >= effectiveConfig.syncBehindThreshold
                ? "Rebase onto \(base) if needed"
                : nil,
            effectiveConfig.syncAutoLint ? "Run configured lint" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        let activeFailureState: GGSyncProgressPresentation.Step.State = terminalFailure ? .failed :
            (isInFlight ? .current : .pending)
        let commitsDetail = summaryFailure ? "Sync failed" :
            (sawSummary ? "Commit sync complete" :
                (sawStart ? (liveStatus ?? countStatus()) : "Waiting for stack preparation"))
        let reviewsDetail = summaryFailure ? "Not completed" :
            (sawSummary ? "Pull request updates complete" :
                (sawPREvent ? "Publishing review state" : "Waiting for pushed commits"))
        let steps = [
            GGSyncProgressPresentation.Step(
                id: "prepare",
                title: "Preparing stack",
                detail: preparationDetails,
                state: sawStart || sawSummary ? .complete : activeFailureState
            ),
            GGSyncProgressPresentation.Step(
                id: "commits",
                title: "Syncing commits",
                detail: commitsDetail,
                state: summaryFailure ? .failed : (sawSummary ? .complete :
                    (sawStart ? activeFailureState : .pending))
            ),
            GGSyncProgressPresentation.Step(
                id: "reviews",
                title: "Updating pull requests",
                detail: reviewsDetail,
                state: summaryFailure ? .pending : (sawSummary ? .complete : .pending)
            ),
            GGSyncProgressPresentation.Step(
                id: "refresh",
                title: "Refreshing Changes",
                detail: "Reloading Git and provider status",
                state: sawSummary && !terminalFailure ? (isInFlight ? .current : .complete) : .pending
            ),
        ]
        return GGSyncProgressPresentation(
            liveStatus: liveStatus,
            showsSpinner: isInFlight && !terminalFailure,
            steps: steps,
            rows: entries.compactMap { position, entry in
                entry.row.map { .init(position: position, text: $0) }
            }.sorted { $0.position < $1.position }
        )
    }

    public init(title: String, summaryChip: String, facts: [Fact], primaryActions: [Action], overflowActions: [Action], syncProgress: GGSyncProgressPresentation?, isRetainedSyncFailure: Bool, isPaused: Bool, actionSummary: String?, localChangesNote: String?) {
        self.title = title
        self.summaryChip = summaryChip
        self.facts = facts
        self.primaryActions = primaryActions
        self.overflowActions = overflowActions
        self.syncProgress = syncProgress
        self.isRetainedSyncFailure = isRetainedSyncFailure
        self.isPaused = isPaused
        self.actionSummary = actionSummary
        self.localChangesNote = localChangesNote
    }
}
