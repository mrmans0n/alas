import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// What one stack poll saw.
public struct StackShepherdObservation: Sendable {
    /// Fresh requests by number, each with its checks and threads. An entry
    /// missing here was not read and is left alone.
    public let requests: [Int: ReviewRequest]
    /// The ids of the published entries gg lists for this stack, or nil when
    /// the worktree is not on it (nothing can be dropped then).
    public let presentEntryIDs: Set<String>?
    /// The worktree's own state. Entries are never checked out on their own,
    /// so it only fills the snapshot `ShepherdPolicy` reads.
    public let local: ReviewLoopLocalState
    public let capabilities: CodeHostProviderCapabilities
    /// Lowercased logins on each request's head, by number; missing means
    /// unknown, which keeps a required-reviewer gate closed.
    public let headReviewers: [Int: Set<String>]
    public let session: ShepherdSessionState
    /// The worktree is on this stack with no gg or git operation paused, so
    /// the session can move between entries. Fix turns wait otherwise.
    public let canDispatch: Bool
    public let rules: ShepherdRules
    public let now: Date

    public init(
        requests: [Int: ReviewRequest],
        presentEntryIDs: Set<String>?,
        local: ReviewLoopLocalState,
        capabilities: CodeHostProviderCapabilities,
        headReviewers: [Int: Set<String>],
        session: ShepherdSessionState,
        canDispatch: Bool,
        rules: ShepherdRules,
        now: Date
    ) {
        self.requests = requests
        self.presentEntryIDs = presentEntryIDs
        self.local = local
        self.capabilities = capabilities
        self.headReviewers = headReviewers
        self.session = session
        self.canDispatch = canDispatch
        self.rules = rules
        self.now = now
    }
}

/// One entry's share of a fix turn.
public struct StackShepherdFix: Equatable, Sendable {
    public let entry: StackShepherdEntry
    public let request: ReviewRequest
    public let problems: ShepherdFixRequest

    public init(entry: StackShepherdEntry, request: ReviewRequest, problems: ShepherdFixRequest) {
        self.entry = entry
        self.request = request
        self.problems = problems
    }
}

public enum StackShepherdEntryEvent: Equatable, Sendable {
    case escalated(StackShepherdEntry, ShepherdEscalation, title: String)
    case closed(StackShepherdEntry, title: String)
}

public struct StackShepherdDecision: Equatable, Sendable {
    public var record: StackShepherdRecord
    /// Bottom-up. Every entry here is already `fixing`; they go out as one
    /// turn. Empty when no turn is due.
    public var fixes: [StackShepherdFix] = []
    public var entryEvents: [StackShepherdEntryEvent] = []
    /// Every open entry passes the gate on heads not announced before.
    public var notifyReady = false
    public var gatePasses = false
    /// Set on the poll that saw the last entry merge or close.
    public var finished: ShepherdOutcome?

    public init(record: StackShepherdRecord) {
        self.record = record
    }
}

/// Pure decisions for one stack poll. Each entry runs through
/// `ShepherdPolicy` with the same owner session; what the stack adds is one
/// combined fix turn, the stack-wide ready gate, and keeping the entries in
/// step with what gg lists.
public enum StackShepherdPolicy {
    /// The record's entries in step with `stack`'s published entries,
    /// bottom-up. An entry is matched by its GG-ID (or SHA), then by request
    /// number; a match whose request number changed starts over. Entries gg
    /// no longer lists are kept ahead of the rest until `decide` reads their
    /// requests: merged ones finish, open ones are dropped.
    public static func reconcile(_ record: StackShepherdRecord, with stack: GGStack, now: Date) -> StackShepherdRecord {
        let published = stack.entries
            .filter { $0.prNumber != nil }
            .sorted { $0.position < $1.position }
        var unmatched = Array(record.entries.indices)
        var matches: [Int: Int] = [:]
        for (slot, stackEntry) in published.enumerated() {
            if let found = unmatched.firstIndex(where: { record.entries[$0].entryID == stackEntry.id }) {
                matches[slot] = unmatched.remove(at: found)
            }
        }
        for (slot, stackEntry) in published.enumerated() where matches[slot] == nil {
            if let found = unmatched.firstIndex(where: { record.entries[$0].requestNumber == stackEntry.prNumber }) {
                matches[slot] = unmatched.remove(at: found)
            }
        }
        var entries = unmatched.map { record.entries[$0] }
        for (slot, stackEntry) in published.enumerated() {
            guard let number = stackEntry.prNumber else { continue }
            var entry = matches[slot].map { record.entries[$0] }
                ?? StackShepherdEntry(
                    entryID: stackEntry.id, position: stackEntry.position, title: stackEntry.title,
                    shepherd: newShepherd(for: number, in: record, now: now)
                )
            if entry.requestNumber != number {
                entry.shepherd = newShepherd(for: number, in: record, now: now)
            }
            entry.entryID = stackEntry.id
            entry.position = stackEntry.position
            entry.title = stackEntry.title
            entries.append(entry)
        }
        guard entries != record.entries else { return record }
        var next = record
        next.entries = entries
        next.updatedAt = now
        return next
    }

    /// A fresh per-entry record, owned and toggled like the stack. Never
    /// auto-merges.
    public static func newShepherd(for number: Int, in record: StackShepherdRecord, now: Date) -> ShepherdRecord {
        ShepherdRecord(
            id: ShepherdRecordID(
                worktreeID: record.id.worktreeID,
                providerKind: record.remote.kind,
                host: record.remote.host,
                repositorySlug: record.remote.repositorySlug,
                requestNumber: number
            ),
            sessionID: record.sessionID,
            remote: record.remote,
            branch: "",
            baseBranch: record.base,
            autoFix: record.autoFix,
            autoMerge: false,
            maxFixAttempts: record.fixAttemptBudget,
            now: now
        )
    }

    public static func decide(_ record: StackShepherdRecord, _ observation: StackShepherdObservation) -> StackShepherdDecision {
        var decision = StackShepherdDecision(record: record)
        guard !record.isFinished else { return decision }
        // A fix turn the session can't act on (another stack checked out, a
        // paused rebase) waits like one the session is too busy for.
        let session: ShepherdSessionState = observation.session == .idle && !observation.canDispatch
            ? .busy : observation.session
        var entries: [StackShepherdEntry] = []
        for var entry in record.entries {
            guard !entry.shepherd.phase.isTerminal,
                  let request = observation.requests[entry.requestNumber]
            else {
                entries.append(entry)
                continue
            }
            // Dropped or unstacked: the request stays open, but it is no
            // longer part of this stack.
            if let present = observation.presentEntryIDs, !present.contains(entry.entryID), request.state == .open {
                continue
            }
            entry.shepherd.branch = request.headRefName
            entry.shepherd.baseBranch = request.baseRefName
            let single = ShepherdPolicy.decide(entry.shepherd, ShepherdObservation(
                snapshot: ReviewLoopSnapshot(
                    local: observation.local,
                    remote: record.remote,
                    reviewRequest: request,
                    providerAvailable: true,
                    providerAuthenticated: true,
                    providerCapabilities: observation.capabilities,
                    errorMessage: nil
                ),
                headReviewers: observation.headReviewers[entry.requestNumber],
                session: session,
                rules: observation.rules,
                now: observation.now
            ))
            entry.shepherd = single.record
            switch single.action {
            case .dispatchFix(let problems):
                decision.fixes.append(StackShepherdFix(entry: entry, request: request, problems: problems))
            case .escalate(let reason):
                decision.entryEvents.append(.escalated(entry, reason, title: request.title))
            case .finish(.closed):
                decision.entryEvents.append(.closed(entry, title: request.title))
            case .finish(.merged), .wait, .notifyReady, .merge:
                // Entries never auto-merge, and readiness is the stack's call.
                break
            }
            entries.append(entry)
        }
        var next = record
        next.entries = entries

        let open = next.openEntries
        decision.gatePasses = !open.isEmpty && open.allSatisfy { entry in
            guard entry.shepherd.phase == .watching,
                  let request = observation.requests[entry.requestNumber]
            else { return false }
            return ReviewReadinessModel.requestIsMergeReady(request, capabilities: observation.capabilities)
                && ShepherdPolicy.headGatePasses(
                    entry.shepherd, request: request, rules: observation.rules,
                    headReviewers: observation.headReviewers[entry.requestNumber], now: observation.now
                )
        }
        if decision.gatePasses {
            let heads = open.map { "\($0.requestNumber):\(observation.requests[$0.requestNumber]?.headSHA ?? "")" }
            if next.notifiedReadyHeads != heads {
                next.notifiedReadyHeads = heads
                decision.notifyReady = true
            }
        }
        if next.isFinished {
            next.finishedAt = next.finishedAt ?? observation.now
            decision.finished = next.phase == .merged ? .merged : .closed
        }
        if next != record { next.updatedAt = observation.now }
        decision.record = next
        return decision
    }
}
