import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Identity of one shepherded gg stack: the worktree it lives in and the gg
/// stack's name. Workspace checkouts are out of scope, as for single PRs.
public struct StackShepherdRecordID: Hashable, Codable, Sendable {
    public let worktreeID: String
    public let stackName: String

    public init(worktreeID: String, stackName: String) {
        self.worktreeID = worktreeID
        self.stackName = stackName
    }

    public var storageKey: String { "stack|\(worktreeID)|\(stackName)" }
}

/// One published entry of a shepherded stack. `shepherd` holds the same
/// per-request state a single PR's record does, so `ShepherdPolicy` decides
/// each entry. Entries never auto-merge: a stack lands bottom-up through
/// `gg land`, so `shepherd.autoMerge` is always false.
public struct StackShepherdEntry: Codable, Equatable, Sendable {
    /// The entry's GG-ID, else its commit SHA (`GGStackEntry.id`).
    public var entryID: String
    /// 1 is the bottom of the stack.
    public var position: Int
    public var title: String
    public var shepherd: ShepherdRecord

    public init(entryID: String, position: Int, title: String, shepherd: ShepherdRecord) {
        self.entryID = entryID
        self.position = position
        self.title = title
        self.shepherd = shepherd
    }

    public var requestNumber: Int { shepherd.id.requestNumber }
}

public struct StackShepherdRecord: Codable, Equatable, Sendable {
    public let id: StackShepherdRecordID
    public var sessionID: String
    public var remote: CodeHostRemote
    public var base: String
    public var autoFix: Bool
    /// Fix prompts each entry is allowed before escalating. Nil in records
    /// saved before this field existed; read it through `fixAttemptBudget`.
    public var maxFixAttempts: Int?
    /// Bottom-up by position.
    public var entries: [StackShepherdEntry]
    /// `"<number>:<head>"` of every open entry when "ready to land" was last
    /// notified, so the same heads are announced once.
    public var notifiedReadyHeads: [String]?
    /// gg lists a local entry with no request yet, as of the last poll that
    /// saw the stack. Keeps the record alive after every tracked request has
    /// merged, so unpublished work isn't reported as landed. Nil until seen.
    public var hasUnpublishedEntries: Bool?
    /// What Ship publishes, kept for every later `stack_ship`: entries above
    /// its boundary are held back. Nil publishes the whole stack.
    public var shipPlan: StackShipPlan?
    /// Entries whose request merged while gg still lists their commits, as
    /// of the last poll that saw the stack: the bottom of the stack landed and
    /// the rest must be rebased onto the base before it publishes again. Nil
    /// when there are none.
    public var landedEntryIDs: [String]?
    /// `landedEntryIDs` when the owner was last asked to restack, so each
    /// landing is announced once.
    public var restackRequestedFor: [String]?
    public var finishedAt: Date?
    /// Every entry merged while the owner session was busy; the
    /// archive-after-merge step waits for its turn to end.
    public var archivePending: Bool?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: StackShepherdRecordID,
        sessionID: String,
        remote: CodeHostRemote,
        base: String,
        autoFix: Bool,
        maxFixAttempts: Int = ShepherdDefaults.defaultMaxFixAttempts,
        entries: [StackShepherdEntry],
        now: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.remote = remote
        self.base = base
        self.autoFix = autoFix
        self.maxFixAttempts = ShepherdDefaults.clampedFixAttempts(maxFixAttempts)
        self.entries = entries
        self.createdAt = now
        self.updatedAt = now
    }

    public var owner: SessionOwnerID { .worktree(id.worktreeID) }

    public var openEntries: [StackShepherdEntry] {
        entries.filter { !$0.shepherd.phase.isTerminal }
    }

    /// Every entry merged or closed, and no local entry is still unpublished.
    public var isFinished: Bool {
        !entries.isEmpty && entries.allSatisfy { $0.shepherd.phase.isTerminal } && hasUnpublishedEntries != true
    }

    /// The phase that sums up the entries, most urgent first: finished,
    /// escalated, paused, fixing, waiting for a push, else watching.
    public var phase: ShepherdPhase {
        if isFinished {
            return entries.allSatisfy { $0.shepherd.phase == .merged } ? .merged : .closed
        }
        let phases = openEntries.map(\.shepherd.phase)
        for phase in phases { if case .escalated = phase { return phase } }
        if phases.contains(.paused) { return .paused }
        for phase in phases { if case .fixing = phase { return phase } }
        for phase in phases { if case .awaitingPush = phase { return phase } }
        return .watching
    }

    /// The most fix attempts any open entry has used.
    public var fixAttempts: Int {
        openEntries.map(\.shepherd.fixAttempts).max() ?? 0
    }

    public var fixAttemptBudget: Int { maxFixAttempts ?? ShepherdDefaults.defaultMaxFixAttempts }

    /// Sets the budget on the stack and every entry that has not merged,
    /// clamped to `ShepherdDefaults.fixAttemptRange`; entries that escalated
    /// for running out of attempts go back to watching when the new budget
    /// leaves room. A closed entry keeps its phase but takes the budget, so a
    /// reopen later runs under it.
    public mutating func setFixAttemptBudget(_ budget: Int) {
        maxFixAttempts = ShepherdDefaults.clampedFixAttempts(budget)
        for index in entries.indices where entries[index].shepherd.phase != .merged {
            entries[index].shepherd.setFixAttemptBudget(budget)
        }
    }

    public func entry(number: Int) -> StackShepherdEntry? {
        entries.first { $0.requestNumber == number }
    }
}
