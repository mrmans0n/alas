import Foundation

/// Agent-facing failure of `pr_create` / `pr_status`; `message` is returned verbatim.
private struct PRShepherdCLIError: Error {
    let message: String
}

/// MCP `pr_create` and `pr_status`. The router has already resolved the
/// calling ACP session and its worktree, and rejected Workspace checkout owners.
extension AppState {
    /// Pushes the exact HEAD, opens the PR/MR (or adopts the open one for this
    /// branch), and binds the shepherd to the calling session.
    func cliPRCreate(
        sessionID: String,
        worktreeID: String,
        title: String,
        body: String,
        draft: Bool,
        base: String?
    ) async -> AlasCLIResponse {
        do {
            let result = try await createShepherdedPR(
                sessionID: sessionID, worktreeID: worktreeID,
                title: title, body: body, draft: draft, base: base
            )
            return .text([ReviewCommentWireDTO.jsonLine(result)])
        } catch {
            return .error(Self.prShepherdErrorMessage(error))
        }
    }

    /// Fresh status of the PR/MR bound to the calling session, else of the
    /// worktree branch's PR/MR.
    func cliPRStatus(sessionID: String, worktreeID: String) async -> AlasCLIResponse {
        do {
            let status = try await shepherdedPRStatus(sessionID: sessionID, worktreeID: worktreeID)
            return .text([ReviewCommentWireDTO.jsonLine(status)])
        } catch {
            return .error(Self.prShepherdErrorMessage(error))
        }
    }

    private func createShepherdedPR(
        sessionID: String,
        worktreeID: String,
        title: String,
        body: String,
        draft: Bool,
        base: String?
    ) async throws -> PRCreateResultWire {
        let (_, context) = try prShepherdTarget(worktreeID)
        let baseBranch = base ?? context.baseBranch
        guard let snapshot = await reviewShepherd.fetchSnapshot(worktreePath: context.path, baseBranch: baseBranch) else {
            throw PRShepherdCLIError(message: "Alas could not read this worktree's Git state.")
        }
        let local = snapshot.local
        if let blocker = Self.prCreateBranchBlocker(local, baseBranch: baseBranch) {
            throw PRShepherdCLIError(message: blocker)
        }
        guard let remote = snapshot.remote else {
            throw PRShepherdCLIError(message: "This worktree has no GitHub or GitLab remote.")
        }
        if let problem = Self.prProviderSetupProblem(snapshot) {
            throw PRShepherdCLIError(message: problem)
        }
        if let message = snapshot.errorMessage {
            throw PRShepherdCLIError(message: "Could not check for an existing pull request: \(message)")
        }
        let hasUncommittedChanges = local.hasWorkingTreeChanges || local.hasStagedChanges

        if let existing = snapshot.reviewRequest, existing.state == .open {
            let record = await bindPRShepherd(sessionID: sessionID, worktreeID: worktreeID, request: existing)
            return PRCreateResultWire(
                request: existing, headSHA: existing.headSHA ?? local.headSHA, created: false,
                uncommittedChanges: hasUncommittedChanges, record: record
            )
        }

        // Same exact-SHA publish path as Commit & publish: capture validates the
        // branch, HEAD and push destinations; push re-checks the URL set and
        // never forces; tracking is configured when the branch had none.
        let run: ([String]) async throws -> ProcessResult = { try await Process.git($0, cwd: context.path) }
        let operations = CommitPublishOperations.live(
            worktreePath: context.path,
            reviewLoop: ReviewLoopState(worktreePath: context.path, baseBranch: baseBranch),
            comparisonBase: nil,
            syncGG: { _ in },
            refreshAfterCompletion: {},
            runGit: run
        )
        let url: URL
        do {
            let target = try await CommitPublishReviewTarget.capture(snapshot: snapshot, createAsDraft: draft, runGit: run)
            if try await !operations.remoteBranchContainsCommit(target, local.headSHA) {
                try await operations.push(target, local.headSHA)
            }
            try await operations.configureUpstreamTracking(target)
            url = try await operations.createReviewRequest(target, title, body)
        } catch let error as CodeHostProviderError {
            throw PRShepherdCLIError(message: Self.prProviderErrorMessage(error, kind: remote.kind))
        }

        guard let created = await reviewShepherd.fetchSnapshot(
            worktreePath: context.path, baseBranch: baseBranch
        )?.reviewRequest else {
            throw PRShepherdCLIError(
                message: "Created \(url.absoluteString), but Alas could not load it yet. Call pr_create again to start watching it."
            )
        }
        let record = await bindPRShepherd(sessionID: sessionID, worktreeID: worktreeID, request: created)
        return PRCreateResultWire(
            request: created, headSHA: created.headSHA ?? local.headSHA, created: true,
            uncommittedChanges: hasUncommittedChanges, record: record
        )
    }

    private func shepherdedPRStatus(sessionID: String, worktreeID: String) async throws -> PRStatusWire {
        let (effects, context) = try prShepherdTarget(worktreeID)
        let bound = reviewShepherd.record(forSession: sessionID).flatMap { $0.id.worktreeID == worktreeID ? $0 : nil }
        var snapshot: ReviewLoopSnapshot?
        if let bound {
            await reviewShepherd.evaluateNow(bound.id)
            snapshot = reviewShepherd.snapshots[bound.id]
        }
        if snapshot == nil {
            snapshot = await reviewShepherd.fetchSnapshot(
                worktreePath: context.path, baseBranch: bound?.baseBranch ?? context.baseBranch
            )
        }
        guard let snapshot else {
            throw PRShepherdCLIError(message: "Alas could not read this worktree's Git state.")
        }
        let rules = effects.rules(worktreeID)
        var pullRequest: PRStatusWire.PullRequest?
        if let request = snapshot.reviewRequest {
            var headReviewers: Set<String>?
            if !rules.requiredReviewers.isEmpty {
                headReviewers = await reviewShepherd.headReviewers(for: snapshot, worktreePath: context.path)
            }
            pullRequest = PRStatusWire.PullRequest(request: request, rules: rules, headReviewers: headReviewers)
        } else if let problem = Self.prProviderSetupProblem(snapshot) {
            throw PRShepherdCLIError(message: problem)
        } else if snapshot.remote != nil, let message = snapshot.errorMessage {
            throw PRShepherdCLIError(message: "Could not load the pull request: \(message)")
        }
        // evaluateNow may have advanced or finished the record; report it as it is now.
        let shepherd = bound
            .flatMap { reviewShepherd.records[$0.id] }
            .map { PRStatusWire.Shepherd(record: $0, rules: rules) }
        return PRStatusWire(pullRequest: pullRequest, shepherd: shepherd)
    }

    private func prShepherdTarget(
        _ worktreeID: String
    ) throws -> (effects: ReviewShepherd.Effects, context: ReviewShepherd.WorktreeContext) {
        guard let effects = reviewShepherd.effects else {
            throw PRShepherdCLIError(message: "The Alas PR shepherd is not running yet. Try again in a moment.")
        }
        guard let context = effects.worktreeContext(worktreeID) else {
            throw PRShepherdCLIError(message: "Alas could not find this session's worktree.")
        }
        guard context.isEligible else {
            throw PRShepherdCLIError(
                message: "The PR shepherd works on local worktrees only. Remote worktrees and Workspace checkouts are not supported yet."
            )
        }
        return (effects, context)
    }

    /// Re-binding a PR this session already shepherds keeps its toggles; a new
    /// binding takes the Settings defaults.
    private func bindPRShepherd(sessionID: String, worktreeID: String, request: ReviewRequest) async -> ShepherdRecord {
        let current = reviewShepherd.records[ShepherdRecordID(worktreeID: worktreeID, request: request)]
        let defaults = config.changes.shepherd
        return await reviewShepherd.bind(
            sessionID: sessionID,
            worktreeID: worktreeID,
            request: request,
            baseBranch: request.baseRefName,
            autoFix: current?.autoFix ?? defaults.autoFix,
            autoMerge: current?.autoMerge ?? defaults.autoMerge,
            sendContext: false
        )
    }

    static func prCreateBranchBlocker(_ local: ReviewLoopLocalState, baseBranch: String) -> String? {
        if local.branchName.isEmpty {
            return "HEAD is detached. Check out a branch before opening a pull request."
        }
        if local.headSHA.isEmpty {
            return "\(local.branchName) has no commits yet."
        }
        if local.branchName == baseBranch {
            return "This worktree is on the base branch \(baseBranch). Open a pull request from a feature branch."
        }
        if local.upstreamBranchName == baseBranch {
            return "\(local.branchName) tracks the base branch \(baseBranch), so a push would land on \(baseBranch). "
                + "Run `git branch --unset-upstream` in this worktree, then call pr_create again."
        }
        if local.aheadCommitCount == 0 {
            return "\(local.branchName) has no commits ahead of \(baseBranch)."
        }
        return nil
    }

    static func prProviderSetupProblem(_ snapshot: ReviewLoopSnapshot) -> String? {
        guard let remote = snapshot.remote else { return nil }
        if !snapshot.providerAvailable { return prProviderSetupMessage(kind: remote.kind, isInstalled: false) }
        if !snapshot.providerAuthenticated { return prProviderSetupMessage(kind: remote.kind, isInstalled: true) }
        return nil
    }

    static func prProviderErrorMessage(_ error: CodeHostProviderError, kind: CodeHostKind) -> String {
        switch error {
        case .cliMissing: prProviderSetupMessage(kind: kind, isInstalled: false)
        case .unauthenticated: prProviderSetupMessage(kind: kind, isInstalled: true)
        default: error.localizedDescription
        }
    }

    static func prProviderSetupMessage(kind: CodeHostKind, isInstalled: Bool) -> String {
        let cli = switch kind {
        case .github: "gh"
        case .gitlab: "glab"
        }
        if isInstalled {
            return "\(kind.displayName) CLI (\(cli)) is not signed in. Run `\(cli) auth login`, then try again."
        }
        return "\(kind.displayName) CLI (\(cli)) is not installed. Install it with `brew install \(cli)`, then run `\(cli) auth login`."
    }

    static func prShepherdErrorMessage(_ error: Error) -> String {
        (error as? PRShepherdCLIError)?.message ?? error.localizedDescription
    }
}
