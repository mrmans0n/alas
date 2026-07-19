import Foundation

/// Pure presentation model for the stack-mode drawer. Computes the title,
/// summary chip, fact rows, action buttons (+ enablement), and live sync
/// progress rows from the stack and its action state. No I/O — unit-tested.
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
        let isEnabled: Bool
        let isInFlight: Bool
        let emphasis: Emphasis
        var id: String { "\(kind)" }
    }

    let title: String
    let summaryChip: String
    let facts: [Fact]
    let actions: [Action]
    let progressRows: [String]
    let isPaused: Bool

    @MainActor
    static func make(stack: GGStack, action: GGStackActionState) -> GGStackReadinessModel {
        let merged = stack.entries.filter { $0.prState == .merged }.count
        let unsynced = max(0, stack.totalCommits - stack.syncedCommits)
        let behind = stack.behindBase ?? 0
        let isPaused = action.pausedOperation != nil
        let inFlight = action.inFlightAction
        let busy = inFlight != nil

        let summaryChip: String = {
            if isPaused { return "paused" }
            if unsynced > 0 { return "\(unsynced) unsynced" }
            if behind > 0 { return "↓\(behind) behind" }
            return "\(merged)/\(stack.totalCommits) merged"
        }()

        let facts: [Fact] = [
            Fact(label: "Entries", value: "\(stack.totalCommits)"),
            Fact(label: "Merged", value: "\(merged)"),
            Fact(label: "Unsynced", value: "\(unsynced)"),
            Fact(label: "Behind base", value: "\(behind)"),
        ]

        let actions: [Action]
        if isPaused {
            actions = [
                Action(kind: .continueOp, title: "Continue", isEnabled: !busy,
                       isInFlight: inFlight == .continueOp, emphasis: .primary),
                Action(kind: .abortOp, title: "Abort", isEnabled: !busy,
                       isInFlight: inFlight == .abortOp, emphasis: .normal),
            ]
        } else {
            let landReady = stack.entries.contains {
                $0.prState == .open && $0.approved && $0.ciStatus == .success
            }
            let hasMerged = merged > 0
            actions = [
                Action(kind: .sync, title: "Sync stack", isEnabled: !busy,
                       isInFlight: inFlight == .sync, emphasis: .primary),
                Action(kind: .land, title: "Land ready", isEnabled: !busy && landReady,
                       isInFlight: inFlight == .land, emphasis: .normal),
                Action(kind: .clean, title: "Clean all", isEnabled: !busy && hasMerged,
                       isInFlight: inFlight == .clean, emphasis: .normal),
            ]
        }

        let syncIsRelevant = inFlight == .sync || action.pausedOperation?.pausedBy == .sync
        return GGStackReadinessModel(
            title: "Stack · \(stack.name)",
            summaryChip: summaryChip,
            facts: facts,
            actions: actions,
            progressRows: syncIsRelevant ? progressRows(from: action.syncProgress) : [],
            isPaused: isPaused
        )
    }

    @MainActor
    static func makePausedFallback(action: GGStackActionState) -> GGStackReadinessModel? {
        guard action.pausedOperation != nil else { return nil }
        let inFlight = action.inFlightAction
        let busy = inFlight != nil
        let syncIsRelevant = inFlight == .sync || action.pausedOperation?.pausedBy == .sync
        return GGStackReadinessModel(
            title: "Stack operation",
            summaryChip: "paused",
            facts: [],
            actions: [
                Action(kind: .continueOp, title: "Continue", isEnabled: !busy,
                       isInFlight: inFlight == .continueOp, emphasis: .primary),
                Action(kind: .abortOp, title: "Abort", isEnabled: !busy,
                       isInFlight: inFlight == .abortOp, emphasis: .normal),
            ],
            progressRows: syncIsRelevant ? progressRows(from: action.syncProgress) : [],
            isPaused: true
        )
    }

    private static func progressRows(from events: [GGSyncEvent]) -> [String] {
        events.compactMap { event in
            switch event {
            case .start(let total): return "Syncing \(total) entr\(total == 1 ? "y" : "ies")…"
            case .entryStarted(let pos, let title): return "[\(pos)] \(title)"
            case .pushStarted(let pos): return "[\(pos)] pushing…"
            case .pushDone(let pos, _): return "[\(pos)] pushed"
            case .prCreated(let pos, let number, _, _): return "[\(pos)] PR #\(number)"
            case .summary: return nil
            case .error(let message): return "Error: \(message)"
            }
        }
    }
}
