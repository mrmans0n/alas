import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP

/// A gg stack whose every entry has a pull or merge request, with those
/// requests freshly read.
public struct PublishedGGStack: Sendable {
    public let stack: GGStack
    public let remote: CodeHostRemote
    public let requests: [Int: ReviewRequest]
    public let hasUncommittedChanges: Bool
}

/// MCP `stack_ship` and the stack half of `pr_status`. The router has
/// already resolved the calling ACP session and its worktree, and rejected
/// Workspace checkout owners.
extension AlasCoreContext {
    /// Publishes the worktree's gg stack with `gg sync`, the same guarded path
    /// as the stack drawer's Sync, then binds the stack shepherd to session
    /// `sessionID`. Runs one at a time with `pr_create` per worktree.
    func shipStack(sessionID: String, worktreeID: String) async -> AlasCLIResponse {
        await serializedPublish(worktreeID: worktreeID) {
            let result = try await self.publishShepherdedStack(sessionID: sessionID, worktreeID: worktreeID)
            return ReviewCommentWireDTO.jsonLine(result)
        }
    }

    private func publishShepherdedStack(sessionID: String, worktreeID: String) async throws -> StackShipResultWire {
        let (effects, context) = try stackShepherdTarget(worktreeID, sessionID: sessionID)
        guard let stack = try await loadStack(effects, path: context.path) else {
            throw PRShepherdCLIError(message: "gg does not list a stack for this worktree. Check out the stack's branch, then call stack_ship again.")
        }
        // A live record for another stack of this worktree means the user
        // moved on while this session still shepherds that one: publishing
        // this stack would drop it. Stop it first, or check it out again.
        if let live = stackShepherd.record(forSession: sessionID),
           live.id.worktreeID == worktreeID, !live.isFinished, live.id.stackName != stack.name {
            throw PRShepherdCLIError(
                message: "This session shepherds the gg stack \"\(live.id.stackName)\", but this worktree is on \"\(stack.name)\". "
                    + "Check out \"\(live.id.stackName)\" and call stack_ship again, or stop shepherding it from the Ship popover first."
            )
        }
        guard !stack.entries.isEmpty else {
            throw PRShepherdCLIError(message: "The gg stack \"\(stack.name)\" has no commits yet. Commit the work into the stack, then call stack_ship again.")
        }
        if let position = stack.currentPosition, position < stack.totalCommits {
            throw PRShepherdCLIError(
                message: "This worktree is on entry \(position) of \(stack.totalCommits). Run `gg last` to return to the top of the stack, then call stack_ship again."
            )
        }
        do {
            try await effects.syncStack(worktreeID)
        } catch {
            throw PRShepherdCLIError(message: "gg sync did not finish: \(Self.prShepherdErrorMessage(error))")
        }
        let published = try await publishedStack(effects, context: context, unpublishedHint: "gg sync did not open one")
        let record = await bindStackShepherd(sessionID: sessionID, worktreeID: worktreeID, published: published, contextRules: nil)
        return StackShipResultWire(record: record, requests: published.requests, uncommittedChanges: published.hasUncommittedChanges)
    }

    /// Binds the worktree's already published stack to `sessionID` without
    /// syncing it, as the toolbar's "Shepherd stack" does. `contextRules`
    /// sends the session the context prompt.
    public func shepherdPublishedStack(
        sessionID: String,
        worktreeID: String,
        contextRules: ShepherdRules?
    ) async throws -> StackShepherdRecord {
        let (effects, context) = try stackShepherdTarget(worktreeID, sessionID: sessionID)
        let published = try await publishedStack(effects, context: context, unpublishedHint: "Ship the stack to open it")
        return await bindStackShepherd(sessionID: sessionID, worktreeID: worktreeID, published: published, contextRules: contextRules)
    }

    /// Before a standalone PR bind: stops the session's live stack record (a
    /// session shepherds one PR or one stack, never both) and any live stack
    /// record in the worktree that still holds `request` as an entry that has
    /// not merged, whoever owns it. A closed entry counts: a reopened request
    /// is watched again on the next poll. A request has one shepherd, or both
    /// would dispatch fixes for it.
    public func releaseStackShepherds(forStandaloneBindOf request: ReviewRequest, sessionID: String, worktreeID: String) {
        for record in stackShepherd.records.values where !record.isFinished {
            let watchesRequest = record.id.worktreeID == worktreeID
                && record.entries.contains { $0.requestNumber == request.number && $0.shepherd.phase != .merged }
            if record.sessionID == sessionID || watchesRequest {
                stackShepherd.stopShepherding(record.id)
            }
        }
    }

    /// Before a stack bind: stops the session's live PR records, and every
    /// live PR record in the worktree for one of the stack's requests, whoever
    /// owns it. A standalone record with auto-merge on could otherwise merge
    /// one entry, though a stack lands bottom-up through `gg land`.
    func releasePRShepherds(forStackBindOf requestNumbers: Set<Int>, sessionID: String, worktreeID: String) {
        for record in reviewShepherd.records.values where !record.phase.isTerminal {
            let watchesEntry = record.id.worktreeID == worktreeID && requestNumbers.contains(record.id.requestNumber)
            if record.sessionID == sessionID || watchesEntry {
                reviewShepherd.stopShepherding(record.id)
            }
        }
    }

    /// Re-binding the stack this session already shepherds keeps its
    /// Auto-fix switch; a new binding takes the Settings default.
    private func bindStackShepherd(
        sessionID: String,
        worktreeID: String,
        published: PublishedGGStack,
        contextRules: ShepherdRules?
    ) async -> StackShepherdRecord {
        let id = StackShepherdRecordID(worktreeID: worktreeID, stackName: published.stack.name)
        let current = stackShepherd.records[id].flatMap { $0.sessionID == sessionID && !$0.isFinished ? $0 : nil }
        releasePRShepherds(
            forStackBindOf: Set(published.stack.entries.compactMap(\.prNumber)),
            sessionID: sessionID, worktreeID: worktreeID
        )
        return await stackShepherd.bind(
            sessionID: sessionID,
            worktreeID: worktreeID,
            stack: published.stack,
            requests: published.requests,
            remote: published.remote,
            autoFix: current?.autoFix ?? environment.configuration().changes.shepherd.autoFix,
            maxFixAttempts: current?.fixAttemptBudget ?? environment.configuration().changes.shepherd.maxFixAttempts,
            contextRules: contextRules
        )
    }

    /// The worktree must be in gg mode, or hold the session's live stack
    /// record: mid-fix, gg leaves HEAD detached on an entry, which the
    /// branch-named gg mode check can't see.
    private func stackShepherdTarget(
        _ worktreeID: String,
        sessionID: String
    ) throws -> (StackShepherd.Effects, StackShepherd.WorktreeContext) {
        guard let effects = stackShepherd.effects else {
            throw PRShepherdCLIError(message: "The Alas stack shepherd is not running yet. Try again in a moment.")
        }
        guard let context = effects.worktreeContext(worktreeID) else {
            throw PRShepherdCLIError(message: "Alas could not find this session's worktree.")
        }
        guard context.isEligible else {
            throw PRShepherdCLIError(
                message: "The stack shepherd works on git worktrees only. Folders and Workspace checkouts are not supported yet."
            )
        }
        let shipsStack = stackShepherd.record(forSession: sessionID)
            .map { $0.id.worktreeID == worktreeID && !$0.isFinished } ?? false
        guard context.stackName != nil || shipsStack else {
            throw PRShepherdCLIError(
                message: "This worktree is not in gg stacked-diffs mode. Call pr_create to open a pull request for its branch."
            )
        }
        return (effects, context)
    }

    private func loadStack(_ effects: StackShepherd.Effects, path: URL) async throws -> GGStack? {
        do {
            return try await effects.loadStack(path)
        } catch {
            throw PRShepherdCLIError(message: "gg could not list the stack: \(Self.prShepherdErrorMessage(error))")
        }
    }

    /// The worktree's stack with every entry's request read. Throws when an
    /// entry has none yet; `unpublishedHint` says what to do about it.
    private func publishedStack(
        _ effects: StackShepherd.Effects,
        context: StackShepherd.WorktreeContext,
        unpublishedHint: String
    ) async throws -> PublishedGGStack {
        guard let stack = try await loadStack(effects, path: context.path), !stack.entries.isEmpty else {
            throw PRShepherdCLIError(message: "gg does not list a stack with commits for this worktree.")
        }
        if let missing = stack.entries.sorted(by: { $0.position < $1.position }).first(where: { $0.prNumber == nil }) {
            throw PRShepherdCLIError(
                message: "Entry \(missing.position) (\"\(missing.title)\") of the gg stack \"\(stack.name)\" has no pull request: \(unpublishedHint)."
            )
        }
        guard let snapshot = await reviewShepherd.fetchSnapshot(worktreePath: context.path, baseBranch: stack.base) else {
            throw PRShepherdCLIError(message: "Alas could not read this worktree's Git state.")
        }
        guard let remote = snapshot.remote else {
            throw PRShepherdCLIError(message: "This worktree has no GitHub or GitLab remote.")
        }
        if let problem = Self.prProviderSetupProblem(snapshot) {
            throw PRShepherdCLIError(message: problem)
        }
        let requests = try await readStackRequests(numbers: stack.entries.compactMap(\.prNumber), remote: remote, path: context.path)
        return PublishedGGStack(
            stack: stack,
            remote: remote,
            requests: requests,
            hasUncommittedChanges: snapshot.local.hasWorkingTreeChanges || snapshot.local.hasStagedChanges
        )
    }

    private func readStackRequests(numbers: [Int], remote: CodeHostRemote, path: URL) async throws -> [Int: ReviewRequest] {
        do {
            return try await stackShepherd.readRequests(numbers: numbers, remote: remote, worktreePath: path)
        } catch let error as CodeHostProviderError {
            throw PRShepherdCLIError(message: Self.prProviderErrorMessage(error, kind: remote.kind))
        }
    }

    /// `pr_status` for the stack bound to the calling session, else for the
    /// worktree's stack in gg mode. Nil when neither applies, or when the
    /// session shepherds a single PR in this worktree: the PR status answers.
    func shepherdedStackStatus(sessionID: String, worktreeID: String) async throws -> StackStatusWire? {
        // A finished record stays listed after its worktree moves on, so only
        // a live one routes here; otherwise the worktree answers as it is now.
        let bound = stackShepherd.record(forSession: sessionID)
            .flatMap { $0.id.worktreeID == worktreeID && !$0.isFinished ? $0 : nil }
        if bound == nil {
            if reviewShepherd.record(forSession: sessionID)?.id.worktreeID == worktreeID { return nil }
            guard stackShepherd.effects?.worktreeContext(worktreeID)?.stackName != nil else { return nil }
        }
        let (effects, context) = try stackShepherdTarget(worktreeID, sessionID: sessionID)
        let rules = try await effects.rules(worktreeID)
        if let bound {
            // The stack as gg lists it now, so an entry published, removed or
            // reordered since the last poll is reported as it is.
            let freshStack = try? await effects.loadStack(context.path)
            let rows = StackShepherdPolicy.statusEntries(of: bound, stack: freshStack, now: Date())
            let requests = try await readStackRequests(
                numbers: rows.compactMap(\.requestNumber), remote: bound.remote, path: context.path
            )
            var entries: [StackStatusWire.Entry] = []
            var reviewers: [Int: Set<String>] = [:]
            for row in rows {
                let request = row.requestNumber.flatMap { requests[$0] }
                let status = await statusRequest(
                    request, rules: rules, path: context.path,
                    notBefore: { row.shepherd?.headFirstSeenAt(of: $0.headSHA) }
                )
                if let number = row.requestNumber, let logins = status.headReviewers { reviewers[number] = logins }
                entries.append(.init(
                    position: row.position, entryId: row.entryID, title: row.title,
                    pullRequest: status.wire, phase: row.shepherd.map { PRStatusWire.Shepherd.wireName($0.phase) }
                ))
            }
            // Ready is judged on what was just read, not on the last poll.
            let readyToLand = await stackShepherd.isReadyToLand(
                bound.id, freshRequests: requests, stack: freshStack, headReviewers: reviewers, rules: rules
            )
            // The record may have changed while the fetch ran; report it as it is now.
            let latest = stackShepherd.records[bound.id] ?? bound
            return StackStatusWire(
                stack: .init(name: bound.id.stackName, base: latest.base, entries: entries),
                shepherd: .init(record: latest, readyToLand: readyToLand, rules: rules)
            )
        }
        guard let stack = try await loadStack(effects, path: context.path) else { return nil }
        var requests: [Int: ReviewRequest] = [:]
        let numbers = stack.entries.compactMap(\.prNumber)
        if !numbers.isEmpty {
            guard let snapshot = await reviewShepherd.fetchSnapshot(worktreePath: context.path, baseBranch: stack.base),
                  let remote = snapshot.remote
            else {
                throw PRShepherdCLIError(message: "Alas could not find this worktree's GitHub or GitLab remote.")
            }
            if let problem = Self.prProviderSetupProblem(snapshot) {
                throw PRShepherdCLIError(message: problem)
            }
            requests = try await readStackRequests(numbers: numbers, remote: remote, path: context.path)
        }
        var entries: [StackStatusWire.Entry] = []
        for entry in stack.entries.sorted(by: { $0.position < $1.position }) {
            let status = await statusRequest(
                entry.prNumber.flatMap { requests[$0] }, rules: rules, path: context.path, notBefore: { _ in nil }
            )
            entries.append(.init(position: entry.position, entryId: entry.id, title: entry.title, pullRequest: status.wire, phase: nil))
        }
        return StackStatusWire(stack: .init(name: stack.name, base: stack.base, entries: entries), shepherd: nil)
    }

    /// The request's `pr_status` entry, with the logins that reviewed its
    /// head when the rules name required reviewers (nil when none were
    /// needed or the provider could not say).
    private func statusRequest(
        _ request: ReviewRequest?,
        rules: ShepherdRules,
        path: URL,
        notBefore: (ReviewRequest) -> Date?
    ) async -> (wire: PRStatusWire.PullRequest?, headReviewers: Set<String>?) {
        guard let request else { return (nil, nil) }
        var headReviewers: Set<String>?
        if !rules.requiredReviewers.isEmpty {
            headReviewers = await stackShepherd.headReviewers(for: request, worktreePath: path, notBefore: notBefore(request))
        }
        return (PRStatusWire.PullRequest(request: request, rules: rules, headReviewers: headReviewers), headReviewers)
    }
}

extension PRsAPI {
    /// Publishes the gg stack of `worktreeID` with `gg sync` and binds the
    /// stack shepherd to session `sessionID`.
    public func shipStack(sessionID: String, worktreeID: String) async -> AlasCLIResponse {
        await core.shipStack(sessionID: sessionID, worktreeID: worktreeID)
    }
}
