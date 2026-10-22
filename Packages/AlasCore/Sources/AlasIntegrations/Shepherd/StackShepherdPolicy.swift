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
    /// The requests describe what is in the worktree: the worktree is on this
    /// stack, every local entry has a request, gg reports the stack synced,
    /// and nothing is uncommitted. False while a commit is unpublished, an
    /// entry was rewritten after its last sync, the worktree has edits, or it
    /// is on another stack, when green requests say nothing about the code
    /// that would land. See `StackShepherdPolicy.publication`.
    public let isStackPublished: Bool
    /// gg lists a local entry with no request yet, or the worktree has
    /// uncommitted edits. Nil while the worktree is on another stack: the
    /// record keeps what it last saw.
    public let hasUnpublishedEntries: Bool?
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
        isStackPublished: Bool = true,
        hasUnpublishedEntries: Bool? = nil,
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
        self.isStackPublished = isStackPublished
        self.hasUnpublishedEntries = hasUnpublishedEntries
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
    /// Nothing is left to shepherd: the record should be removed.
    public var isRetired = false

    public init(record: StackShepherdRecord) {
        self.record = record
    }
}

/// Pure decisions for one stack poll. Each entry runs through
/// `ShepherdPolicy` with the same owner session; what the stack adds is one
/// combined fix turn, the stack-wide ready gate, and keeping the entries in
/// step with what gg lists.
public enum StackShepherdPolicy {
    /// What the worktree holds that no request describes yet. `stack` is what
    /// gg lists for the worktree, nil when it is on another stack. Uncommitted
    /// edits count as unpublished work, as in a single PR's merge gate: green
    /// requests must not announce, or finish, a stack with edits in it.
    /// Entries above `shipThroughEntryID` are held back on purpose: they keep
    /// the record alive but don't stop the shipped entries from being
    /// published. A boundary gg no longer lists holds back every entry.
    public static func publication(
        of stack: GGStack?,
        local: ReviewLoopLocalState,
        shipThroughEntryID: String? = nil
    ) -> (isPublished: Bool, hasUnpublishedEntries: Bool?) {
        let hasEdits = local.hasWorkingTreeChanges || local.hasStagedChanges
        // Off the stack nothing is known about its publication: not ready,
        // and no verdict on unpublished work either.
        guard let stack else { return (false, nil) }
        let hasUnpublished = stack.entries.contains { $0.prNumber == nil } || hasEdits
        // Shipped is what Held back leaves: with a boundary gg no longer
        // lists, every entry that has a request.
        let heldBackIDs = Set(StackShipPlan(shipThroughEntryID: shipThroughEntryID).heldBackEntries(of: stack).map(\.id))
        let shipped = stack.entries.filter { !heldBackIDs.contains($0.id) }
        // gg counts the entries whose branch matches the remote; held-back
        // entries have no branch, so the shipped ones are synced when the
        // count covers them.
        let isSynced = stack.syncedCommits >= shipped.count
        return (!hasEdits && shipped.allSatisfy { $0.prNumber != nil } && isSynced, hasUnpublished)
    }

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
            // Removed from the stack: gg no longer lists it. A merged entry
            // stays as landed history; anything else is no longer part of it.
            let isAbsent = observation.presentEntryIDs.map { !$0.contains(entry.entryID) } ?? false
            // A closed request that is open again is a live entry once more,
            // starting fresh as a newly bound one does.
            if entry.shepherd.phase == .closed, !isAbsent, observation.requests[entry.requestNumber]?.state == .open {
                entry.shepherd.phase = .watching
                entry.shepherd.finishedAt = nil
                entry.shepherd.fixAttempts = 0
                entry.shepherd.lastDispatchedFingerprint = nil
                entry.shepherd.viewerCommentIDsAtDispatch = nil
            }
            guard !entry.shepherd.phase.isTerminal,
                  let request = observation.requests[entry.requestNumber]
            else {
                if isAbsent, entry.shepherd.phase == .closed { continue }
                entries.append(entry)
                continue
            }
            // Dropped or unstacked: the request stays open or was closed, but
            // it is no longer part of this stack.
            if isAbsent, request.state != .merged {
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
        if let unpublished = observation.hasUnpublishedEntries { next.hasUnpublishedEntries = unpublished }
        decision.gatePasses = isReady(
            next, requests: observation.requests, isStackPublished: observation.isStackPublished,
            capabilities: observation.capabilities, rules: observation.rules,
            headReviewers: observation.headReviewers, now: observation.now
        )
        let open = next.openEntries
        if decision.gatePasses {
            let heads = open.map { "\($0.requestNumber):\(observation.requests[$0.requestNumber]?.headSHA ?? "")" }
            if next.notifiedReadyHeads != heads {
                next.notifiedReadyHeads = heads
                decision.notifyReady = true
            }
        }
        // Every entry was dropped or unstacked and gg lists no local work
        // either: there is no stack left to watch. Unknown (off the stack)
        // keeps the record, as does work that has not been published yet.
        decision.isRetired = next.entries.isEmpty && observation.hasUnpublishedEntries == false
        if next.isFinished {
            next.finishedAt = next.finishedAt ?? observation.now
            decision.finished = next.phase == .merged ? .merged : .closed
        }
        if next != record { next.updatedAt = observation.now }
        decision.record = next
        return decision
    }

    /// Whether the stack is ready to land: every open entry is watching, on a
    /// head the shepherd has seen settle, mergeable on its request, and past
    /// its required reviewers; no entry closed; the stack published. Shared by
    /// each poll and by a status read with fresh inputs.
    public static func isReady(
        _ record: StackShepherdRecord,
        requests: [Int: ReviewRequest],
        isStackPublished: Bool,
        capabilities: CodeHostProviderCapabilities,
        rules: ShepherdRules,
        headReviewers: [Int: Set<String>],
        now: Date
    ) -> Bool {
        let open = record.openEntries
        // Merged entries are landed; a closed one never will be, and gg land
        // can't get past it, so the stack is not ready however green the rest is.
        let hasClosedEntry = record.entries.contains { $0.shepherd.phase == .closed }
        return isStackPublished && !hasClosedEntry && !open.isEmpty && open.allSatisfy { entry in
            guard entry.shepherd.phase == .watching, let request = requests[entry.requestNumber] else { return false }
            return ReviewReadinessModel.requestIsMergeReady(request, capabilities: capabilities)
                && ShepherdPolicy.headGatePasses(
                    entry.shepherd, request: request, rules: rules,
                    headReviewers: headReviewers[entry.requestNumber], now: now
                )
        }
    }

    /// One row of a `pr_status` read.
    public struct StatusEntry: Equatable, Sendable {
        public let position: Int
        public let entryID: String
        public let title: String
        /// Nil for a local entry gg has not published.
        public let requestNumber: Int?
        /// The shepherd's state for the entry; nil while it has no request.
        public let shepherd: ShepherdRecord?
    }

    /// What a status read reports for `record`: the stack as gg lists it now,
    /// bottom-up, with the shepherd's state for each published entry. An entry
    /// published or rewritten since the last poll is already in it (fresh,
    /// until a poll sees it), and one removed from the stack is gone. Without
    /// gg's stack, or with another stack checked out, it is the record's own
    /// entries as of the last poll.
    public static func statusEntries(of record: StackShepherdRecord, stack: GGStack?, now: Date) -> [StatusEntry] {
        guard let stack, stack.name == record.id.stackName else {
            return record.entries.sorted { $0.position < $1.position }.map {
                StatusEntry(position: $0.position, entryID: $0.entryID, title: $0.title, requestNumber: $0.requestNumber, shepherd: $0.shepherd)
            }
        }
        let current = reconcile(record, with: stack, now: now)
        return stack.entries.sorted { $0.position < $1.position }.map { entry in
            let matched = entry.prNumber.flatMap { current.entry(number: $0) }
            return StatusEntry(
                position: entry.position, entryID: entry.id, title: entry.title,
                requestNumber: entry.prNumber, shepherd: matched?.shepherd
            )
        }
    }
}
