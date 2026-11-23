import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations
import AlasACP

/// `pr_create` or `stack_ship` held its push back for review before push.
/// Not an error: `line` is the agent's answer.
struct ShipReviewPending: Error {
    let line: String

    init(wire: some Encodable) {
        line = ReviewCommentWireDTO.jsonLine(wire)
    }
}

/// Review before push through the host's own pieces: the shepherd's worktree
/// context and prompt delivery, the worktree's session manager for the
/// reviewer, the review stores for findings, and `pr_create`'s publish path
/// for the push.
extension AlasCoreContext {
    /// How long one reviewer turn may run.
    static let shipReviewTimeoutMinutes = 20

    func installShipReviewerEffects() {
        shipReviewer.effects = ShipReviewer.Effects(
            context: { [weak self] worktreeID in
                self?.shipReviewContext(worktreeID)
            },
            settings: { [weak self] in
                guard let changes = self?.environment.configuration().changes else {
                    return (CodeReviewSettings(), ShepherdDefaults())
                }
                return (changes.codeReview, changes.shepherd)
            },
            ownerAgentID: { [weak self] id in
                guard let self, let worktree = worktree(withId: id.worktreeID) else { return nil }
                let manager = orchestrationManager(for: worktree)
                return manager?.liveSession(for: id.sessionID)?.agentId
                    ?? manager?.cachedPersistedSessionRow(id: id.sessionID)?.agentId
            },
            agentLabel: { [weak self] reviewer in
                self?.shipReviewerLabel(reviewer)
            },
            git: .live,
            instructions: { path, project in
                try await CodeReviewInstructionsResolver.load(worktreePath: path, projectInstructions: project)
            },
            runReviewer: { [weak self] run in
                await self?.runShipReviewer(run) ?? .failed(sessionID: nil, reason: "Alas is shutting down")
            },
            discardReviewer: { [weak self] id, sessionID in
                guard let self, let worktree = worktree(withId: id.worktreeID) else { return }
                await orchestrationManager(for: worktree)?.discardReviewSession(id: sessionID)
            },
            earlierFindings: { [weak self] reviewSessionIDs in
                self?.shipReviewEarlierFindings(reviewSessionIDs) ?? []
            },
            openFindingCount: { [weak self] reviewSessionID in
                guard let comments = try? self?.shipReviewComments(reviewSessionID) else { return nil }
                return comments.filter(\.isActive).count
            },
            fileRound: { [weak self] filing in
                guard let self else { throw PRShepherdCLIError(message: "Alas is shutting down") }
                return try fileShipReviewRound(filing)
            },
            deliverFindings: { [weak self] id, prompt in
                await self?.reviewShepherd.effects?.deliverPrompt(id.sessionID, id.worktreeID, prompt) { true } ?? .failed
            },
            push: { [weak self] id, target, _ in
                await self?.pushReviewedHead(id, target: target) ?? "Alas is shutting down"
            },
            autoFix: { [weak self] id in
                guard let self else { return false }
                return shipReviewBoundRecord(id)?.autoFix ?? environment.configuration().changes.shepherd.autoFix
            },
            localCommitsToPush: { [weak self] id in
                await self?.shipReviewLocalCommits(id)
            },
            notify: { [weak self] id, stop in
                guard let self, let record = shipReviewer.record(for: id) else { return }
                shipReviewNotice?(id, ShipReviewPresentation.stopMessage(stop, maxRounds: record.maxRounds))
            },
            shipHead: { [weak self] id, target in
                guard let self else { throw ShipHeadUnreadable(errorDescription: "Alas is shutting down") }
                return try await shipReviewHead(id, target: target)
            }
        )
    }

    /// The review before push state the PR shepherd decides with, for
    /// `ReviewShepherd.Effects.reviewGate`; nil when the lever is off.
    public func reviewGate(for record: ShepherdRecord) -> ShepherdReviewGate? {
        shipReviewer.reviewGate(worktreeID: record.id.worktreeID, sessionID: record.sessionID)
    }

    /// The review before push state the stack shepherd decides with, for
    /// `StackShepherd.Effects.reviewGate`; nil when the lever is off.
    public func stackReviewGate(for record: StackShepherdRecord) -> ShepherdReviewGate? {
        shipReviewer.reviewGate(worktreeID: record.id.worktreeID, sessionID: record.sessionID)
    }

    /// For `ReviewShepherd.Effects.unreviewedHead`: the request's head
    /// reached the remote without passing review.
    public func noteUnreviewedHead(_ record: ShepherdRecord, headSHA: String) {
        shipReviewer.reviewPushedHead(ShipReviewID(worktreeID: record.id.worktreeID, sessionID: record.sessionID), headSHA: headSHA)
    }

    /// Asks review before push whether `pr_create` may push `headSHA` now,
    /// and throws its answer when the push waits.
    func gatePRPush(
        sessionID: String, worktreeID: String, push: PendingPRPush, headSHA: String, kind: CodeHostKind
    ) throws {
        let id = ShipReviewID(worktreeID: worktreeID, sessionID: sessionID)
        guard case .reviewing(let record) = shipReviewer.requestPush(id, target: .pullRequest(push), headSHA: headSHA) else {
            return
        }
        if case .stopped(let stop) = record.phase {
            throw PRShepherdCLIError(message: ShipReviewPresentation.stopMessage(stop, maxRounds: record.maxRounds))
        }
        let review = shipReviewer.wire(for: id) ?? ShipReviewWire(record: record, reviewer: "", openFindings: 0)
        throw ShipReviewPending(wire: PRCreateReviewingWire(
            review: review,
            message: "Alas is reviewing the commits before it pushes them. Findings come back as a new turn; "
                + "once the review is clean Alas pushes and opens the \(kind.reviewRequestLabel). Don't push yourself."
        ))
    }

    /// Asks review before push whether `stack_ship` may sync `plan`, whose top
    /// entry is `headSHA`, now, and throws its answer when the sync waits.
    func gateStackPush(sessionID: String, worktreeID: String, plan: StackShipPlan, headSHA: String) throws {
        let id = ShipReviewID(worktreeID: worktreeID, sessionID: sessionID)
        guard case .reviewing(let record) = shipReviewer.requestPush(id, target: .stack(plan), headSHA: headSHA) else {
            return
        }
        if case .stopped(let stop) = record.phase {
            throw PRShepherdCLIError(message: ShipReviewPresentation.stopMessage(stop, maxRounds: record.maxRounds))
        }
        let review = shipReviewer.wire(for: id) ?? ShipReviewWire(record: record, reviewer: "", openFindings: 0)
        throw ShipReviewPending(wire: StackShipProgressWire.reviewing(
            review: review,
            message: "Alas is reviewing the stack's commits before gg sync publishes them. "
                + "Findings come back as a new turn; once the review is clean Alas runs gg sync and sends this session a turn with the result. "
                + "Don't run gg sync or push yourself."
        ))
    }

    // MARK: - Effects

    private func shipReviewContext(_ worktreeID: String) -> ShipReviewer.Context? {
        guard let shepherd = reviewShepherd.effects?.worktreeContext(worktreeID),
              let resolved = projectAndWorktree(withWorktreeId: worktreeID)
        else { return nil }
        let bound = reviewShepherd.record(forWorktree: worktreeID).flatMap { $0.phase.isTerminal ? nil : $0 }
        let kind = bound?.remote.kind ?? reviewLoops[worktreeID]?.snapshot?.remote?.kind
        return ShipReviewer.Context(
            worktreePath: shepherd.path,
            branch: resolved.worktree.branch,
            baseBranch: bound?.baseBranch ?? shipReviewStackBase(worktreeID) ?? shepherd.baseBranch,
            providerName: kind?.displayName ?? "the remote",
            projectSettings: resolved.project.codeReview
        )
    }

    /// The base of the stack the worktree's live stack record ships.
    private func shipReviewStackBase(_ worktreeID: String) -> String? {
        stackShepherd.records.values.first { $0.id.worktreeID == worktreeID && !$0.isFinished }?.base
    }

    /// What a round's result must still describe: for a stack ship the top
    /// entry its plan publishes, else HEAD.
    private func shipReviewHead(_ id: ShipReviewID, target: ShipReviewTarget?) async throws -> String {
        do {
            if case .stack(let plan) = target {
                return try await stackShipTopSHA(worktreeID: id.worktreeID, plan: plan)
            }
            guard let path = reviewShepherd.effects?.worktreeContext(id.worktreeID)?.path else {
                throw PRShepherdCLIError(message: "the worktree is gone")
            }
            return try await ShipReviewGit.live.headSHA(path)
        } catch {
            throw ShipHeadUnreadable(errorDescription: Self.prShepherdErrorMessage(error))
        }
    }

    /// The live PR shepherd record the owning session has in the worktree.
    private func shipReviewBoundRecord(_ id: ShipReviewID) -> ShepherdRecord? {
        reviewShepherd.record(forSession: id.sessionID)
            .flatMap { $0.id.worktreeID == id.worktreeID && !$0.phase.isTerminal ? $0 : nil }
    }

    /// "Codex · gpt-5.2", or "Codex" for the agent's default model; nil
    /// unless the agent is enabled and can run over ACP.
    private func shipReviewerLabel(_ reviewer: ResolvedReviewer) -> String? {
        guard ACPLaunchCatalog.spec(for: reviewer.agentID) != nil,
              let agent = environment.enabledAgents().first(where: { $0.id == reviewer.agentID })
        else { return nil }
        guard let modelID = reviewer.modelID else { return agent.displayName }
        let model = environment.modelCatalog?.models(for: reviewer.agentID).first { $0.id == modelID }?.name ?? modelID
        return "\(agent.displayName) · \(model)"
    }

    private func runShipReviewer(_ run: ShipReviewer.ReviewerRun) async -> ShipReviewer.ReviewerOutcome {
        guard let worktree = worktree(withId: run.id.worktreeID), let manager = orchestrationManager(for: worktree) else {
            return .failed(sessionID: nil, reason: "the worktree is gone")
        }
        let outcome = await manager.runReviewTurn(ACPReviewTurnRequest(
            parentSessionID: run.id.sessionID,
            reuseSessionID: run.reuseSessionID,
            agentID: run.reviewer.agentID,
            modelID: run.reviewer.modelID,
            title: "Review before push",
            prompt: run.prompt,
            timeout: .seconds(Self.shipReviewTimeoutMinutes * 60)
        ))
        switch outcome {
        case .finished(let sessionID, let finalText):
            return .finished(sessionID: sessionID, finalText: finalText)
        case .failed(let sessionID, let failure):
            return .failed(sessionID: sessionID, reason: shipReviewFailureReason(failure, agentID: run.reviewer.agentID))
        }
    }

    /// Reads after "Review didn't finish: ".
    private func shipReviewFailureReason(_ failure: ACPReviewTurnFailure, agentID: String) -> String {
        let agent = environment.agent(id: agentID)?.displayName ?? agentID
        switch failure {
        case .attachFailed(let reason): return "\(agent) couldn't start: \(reason)"
        case .cannotRunReadOnly: return "\(agent) can't run read-only"
        case .notAccepted: return "\(agent) didn't take the review prompt"
        case .timedOut: return "the review ran past \(Self.shipReviewTimeoutMinutes) minutes"
        case .turnFailed(let reason): return reason
        }
    }

    /// The comments filed in review session `id`.
    private func shipReviewComments(_ id: ReviewSessionID) throws -> [ReviewDraftComment] {
        guard let record = try reviewSessions.load(id: id) else {
            throw PRShepherdCLIError(message: "unknown review session \(id.rawValue)")
        }
        return try reviewDrafts.load(sessionID: record.target.draftSessionID)
    }

    /// Findings of earlier rounds still open, with the replies to each.
    private func shipReviewEarlierFindings(_ ids: [ReviewSessionID]) -> [CodeReviewEarlierFinding] {
        ids.flatMap { (try? shipReviewComments($0)) ?? [] }
            .filter(\.isActive)
            .map { comment in
                CodeReviewEarlierFinding(
                    id: comment.id,
                    path: comment.path,
                    line: comment.normalizedLineRange?.lowerBound,
                    body: comment.bodyMarkdown,
                    replies: comment.allReplies.map { "\($0.author.displayName): \($0.bodyMarkdown)" }
                )
            }
    }

    /// Files the round's findings in its review session, attributed to the
    /// reviewer; resolves the earlier findings it reports fixed (all of this
    /// push's, on a clean result); stores the verdict.
    private func fileShipReviewRound(_ filing: ShipReviewer.Filing) throws -> ReviewSessionID {
        let target = filing.target
        var saved: ReviewSessionRecord?
        var failure: (any Error)?
        ReviewSessionLauncher.openOrFocus(
            target: target,
            findActive: { [reviewSessions] in try reviewSessions.findActive(targetID: $0) },
            save: { [reviewSessions] in try reviewSessions.save($0) },
            open: { saved = $0 },
            onFailure: { failure = $0 }
        )
        guard let saved else {
            throw failure ?? PRShepherdCLIError(message: "could not open the review session")
        }
        let now = Date()
        let reviewer = ReviewDraftCommentAuthor.agent(name: filing.reviewerLabel)
        for (commentID, finding) in zip(filing.findingIDs, filing.result.findings) {
            let anchor: ReviewDraftCommentAnchor = switch finding.anchor {
            case .line(let start, let end): .line(side: .new, startLine: start, endLine: end == start ? nil : end, selectedText: nil)
            case .file: .file
            }
            try reviewDrafts.save(ReviewDraftComment(
                id: commentID,
                sessionID: target.draftSessionID,
                fileID: DiffReviewFileID(namespace: "range", path: finding.path),
                path: finding.path,
                anchor: anchor,
                bodyMarkdown: finding.body,
                state: .active,
                createdAt: now,
                updatedAt: now,
                author: reviewer
            ))
        }
        let fixed = Set(filing.result.resolvedIDs)
        for sessionID in filing.earlierRoundSessionIDs {
            guard let comments = try? shipReviewComments(sessionID) else { continue }
            for var comment in comments where comment.isActive && (filing.result.isClean || fixed.contains(comment.id)) {
                comment.state = .resolved
                comment.resolvedBy = reviewer
                comment.updatedAt = now
                try reviewDrafts.save(comment)
            }
        }
        try reviewSessions.save(saved.markedReviewed(
            verdict: filing.result.verdict,
            summary: filing.result.summary,
            now: now
        ))
        reviewCommentsDidChange()
        return saved.id
    }

    /// Pushes a head that passed through `pr_create`'s publish path, which
    /// re-enters the gate: the head passed, so it goes out. Nil on success.
    private func pushReviewedHead(_ id: ShipReviewID, target: ShipReviewTarget) async -> String? {
        switch target {
        case .pullRequest(let push):
            let response = await createPR(
                sessionID: id.sessionID, worktreeID: id.worktreeID,
                title: push.title, body: push.body, draft: push.draft, base: push.base
            )
            switch response {
            case .text, .ok: return nil
            case .error(let message), .errorWithExitCode(let message, _): return message
            }
        case .pushedHead:
            return nil
        case .stack(let plan):
            return await shipReviewedStack(sessionID: id.sessionID, worktreeID: id.worktreeID, plan: plan)
        }
    }

    /// HEAD when the owning session's bound request's remote head branch
    /// doesn't contain it.
    private func shipReviewLocalCommits(_ id: ShipReviewID) async -> String? {
        guard let bound = shipReviewBoundRecord(id),
              let context = reviewShepherd.effects?.worktreeContext(id.worktreeID),
              let head = try? await ShipReviewGit.live.headSHA(context.path)
        else { return nil }
        let remoteHead = "refs/remotes/\(bound.remote.remoteName)/\(bound.branch)"
        guard let result = try? await Process.git(["merge-base", "--is-ancestor", head, remoteHead], cwd: context.path) else {
            return nil
        }
        return result.exitCode == 1 ? head : nil
    }
}

/// The head a ship review checks could not be read; `errorDescription` says why.
private struct ShipHeadUnreadable: LocalizedError {
    let errorDescription: String?
}
