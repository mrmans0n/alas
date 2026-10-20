import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations

/// Agent-facing failure of `pr_create` / `pr_status`; `message` is returned verbatim.
private struct PRShepherdCLIError: Error {
    let message: String
}

/// MCP `pr_create` and `pr_status`. The router has already resolved the
/// calling ACP session and its worktree, and rejected Workspace checkout owners.
extension AlasCoreContext {
    /// Pushes the exact HEAD, opens the PR/MR (or adopts the open one for this
    /// branch), and binds the shepherd to the calling session. Calls for one
    /// worktree run one at a time: a call made while another runs waits for
    /// it, then runs the whole publish path itself, so its own HEAD is pushed
    /// before the request the first call opened is adopted.
    func createPR(
        sessionID: String,
        worktreeID: String,
        title: String,
        body: String,
        draft: Bool,
        base: String?
    ) async -> AlasCLIResponse {
        // The caller that started a task clears it only after it resumes, so a
        // finished task can still be listed: wait for each one once.
        var finished: Task<AlasCLIResponse, Never>?
        while let running = prCreateTasks[worktreeID], running != finished {
            _ = await running.value
            finished = running
        }
        let task = Task { @MainActor [weak self] () -> AlasCLIResponse in
            guard let self else { return .error("Alas is not available.") }
            do {
                let result = try await self.createShepherdedPR(
                    sessionID: sessionID, worktreeID: worktreeID,
                    title: title, body: body, draft: draft, base: base
                )
                return .text([ReviewCommentWireDTO.jsonLine(result)])
            } catch {
                return .error(Self.prShepherdErrorMessage(error))
            }
        }
        prCreateTasks[worktreeID] = task
        let response = await task.value
        if prCreateTasks[worktreeID] == task {
            prCreateTasks[worktreeID] = nil
        }
        return response
    }

    /// The requested base, else the worktree's, without a `<remote>/` prefix.
    private func prCreateBaseBranch(_ base: String?, context: ReviewShepherd.WorktreeContext) async -> String {
        let remotes = (try? await GitService().remotes(worktreePath: context.path)) ?? []
        return Self.normalizedBaseBranch(base ?? context.baseBranch, remoteNames: Set(remotes.map(\.name)))
    }

    /// Fresh status of the PR/MR bound to the calling session, else of the
    /// worktree branch's PR/MR.
    func prStatus(sessionID: String, worktreeID: String) async -> AlasCLIResponse {
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
        // The local probe fails outright on an unborn branch, so say so first.
        if let head = try? await Process.git(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: context.path),
           head.exitCode == 1 {
            let branch = (try? await GitService().currentBranch(worktreePath: context.path)) ?? ""
            throw PRShepherdCLIError(message: "\(branch.isEmpty ? "This branch" : branch) has no commits yet.")
        }
        let baseBranch = await prCreateBaseBranch(base, context: context)
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
        func bound(_ request: ReviewRequest, created: Bool) async -> PRCreateResultWire {
            let record = await bindPRShepherd(sessionID: sessionID, worktreeID: worktreeID, request: request)
            return PRCreateResultWire(
                request: request, headSHA: request.headSHA ?? local.headSHA, created: created,
                uncommittedChanges: hasUncommittedChanges, record: record
            )
        }

        // A failed lookup aborts: treating it as "no request" could open a second
        // one against another base. A differently named upstream is searched too,
        // but the push below never targets that name.
        var adopted = snapshot.reviewRequest.flatMap { $0.state == .open ? $0 : nil }
        if adopted == nil {
            for branch in Self.prCreateLookupBranches(local) {
                adopted = try await openRequest(
                    remote: remote, branch: branch, headOwner: local.headRemoteOwner,
                    bases: [""], worktreePath: context.path
                )
                if adopted != nil { break }
            }
        }
        if let adopted {
            switch Self.prCreateAdoption(
                headRefName: adopted.headRefName, number: adopted.number, kind: adopted.provider, local: local
            ) {
            case .bind: return await bound(adopted, created: false)
            case .blocked(let message): throw PRShepherdCLIError(message: message)
            case .publishThenBind: break
            }
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
        do {
            var target = try await CommitPublishReviewTarget.capture(snapshot: snapshot, createAsDraft: draft, runGit: run)
            // The publish path pushes to the upstream's name. Keep it only when it
            // is this branch's own name; otherwise push to refs/heads/<branch> and
            // retarget tracking, so an upstream such as origin/main never receives it.
            target.upstreamBranch = Self.prCreateUpstreamToKeep(branch: target.branch, upstream: target.upstreamBranch)
            if try await !operations.remoteBranchContainsCommit(target, local.headSHA) {
                try await operations.push(target, local.headSHA)
            }
            try await operations.configureUpstreamTracking(target)
            // Reconcile against the branch that was captured and pushed, not
            // whatever the worktree has checked out by now. A request opened
            // since the first lookup (by an earlier call whose reply timed out
            // on the agent side, say) is adopted, not duplicated.
            func pushedBranchRequest() async throws -> ReviewRequest? {
                try await openRequest(
                    remote: target.remote, branch: target.branch, headOwner: target.headOwner,
                    bases: [baseBranch, ""], worktreePath: context.path
                )
            }
            if let existing = try await pushedBranchRequest() {
                return await bound(existing, created: false)
            }
            // The adopted request is on this branch: the pending HEAD is now
            // published, so bind it rather than open another.
            if let adopted {
                return await bound(adopted, created: false)
            }
            let url: URL
            do {
                url = try await operations.createReviewRequest(target, title, body)
            } catch {
                // The provider may have opened it anyway, or it already exists.
                if let existing = try? await pushedBranchRequest() {
                    return await bound(existing, created: false)
                }
                throw error
            }
            guard let created = try? await pushedBranchRequest() else {
                throw PRShepherdCLIError(
                    message: "Created \(url.absoluteString), but Alas could not load it yet. Call pr_create again to start watching it."
                )
            }
            return await bound(created, created: true)
        } catch let error as CodeHostProviderError {
            throw PRShepherdCLIError(message: Self.prProviderErrorMessage(error, kind: remote.kind))
        }
    }

    /// The open request for `branch`, trying each base in order (an empty base
    /// matches any). Throws when the provider can't answer, so a failed lookup
    /// is never mistaken for "no request".
    private func openRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        bases: [String],
        worktreePath: URL
    ) async throws -> ReviewRequest? {
        let lookup = ReviewLoopState(worktreePath: worktreePath, baseBranch: bases.first ?? "")
        for base in bases {
            if let request = try await lookup.currentReviewRequest(
                remote: remote, branch: branch, headOwner: headOwner, baseBranch: base
            ), request.state == .open {
                return request
            }
        }
        return nil
    }

    /// `probe`'s open request, else the open request of the branch or its
    /// differently named upstream against any base. Read-only callers only: a
    /// lookup failure reads as no request.
    private func openRequestAnyBase(probe: ReviewLoopSnapshot, worktreePath: URL) async -> ReviewRequest? {
        if let request = probe.reviewRequest, request.state == .open { return request }
        guard let remote = probe.remote, !probe.local.branchName.isEmpty else { return nil }
        for branch in Self.prCreateLookupBranches(probe.local) {
            if let request = try? await openRequest(
                remote: remote, branch: branch, headOwner: probe.local.headRemoteOwner,
                bases: [""], worktreePath: worktreePath
            ) {
                return request
            }
        }
        return nil
    }

    /// Read-only: neither path runs the shepherd's policy or changes its record.
    private func shepherdedPRStatus(sessionID: String, worktreeID: String) async throws -> PRStatusWire {
        let (effects, context) = try prShepherdTarget(worktreeID)
        let bound = reviewShepherd.record(forSession: sessionID).flatMap { $0.id.worktreeID == worktreeID ? $0 : nil }
        let snapshot: ReviewLoopSnapshot
        if let bound {
            guard let fresh = await reviewShepherd.statusSnapshot(for: bound.id) else {
                throw PRShepherdCLIError(
                    message: "Alas could not load pull request #\(bound.id.requestNumber). Try again in a moment."
                )
            }
            snapshot = fresh
        } else {
            guard var fresh = await reviewShepherd.fetchSnapshot(
                worktreePath: context.path, baseBranch: context.baseBranch
            ) else {
                throw PRShepherdCLIError(message: "Alas could not read this worktree's Git state.")
            }
            // The branch's PR may target another base than the worktree's.
            if fresh.reviewRequest == nil,
               let other = await openRequestAnyBase(probe: fresh, worktreePath: context.path),
               let rebased = await reviewShepherd.fetchSnapshot(worktreePath: context.path, baseBranch: other.baseRefName),
               rebased.reviewRequest != nil {
                fresh = rebased
            }
            snapshot = fresh
        }
        let rules = try await effects.rules(worktreeID)
        var pullRequest: PRStatusWire.PullRequest?
        if let request = snapshot.reviewRequest {
            var headReviewers: Set<String>?
            if !rules.requiredReviewers.isEmpty {
                headReviewers = await reviewShepherd.headReviewers(
                    for: snapshot, worktreePath: context.path,
                    notBefore: bound.flatMap { reviewShepherd.records[$0.id]?.headFirstSeenAt(of: request.headSHA) }
                )
            }
            pullRequest = PRStatusWire.PullRequest(request: request, rules: rules, headReviewers: headReviewers)
        } else if let problem = Self.prProviderSetupProblem(snapshot) {
            throw PRShepherdCLIError(message: problem)
        } else if let message = snapshot.errorMessage, snapshot.remote != nil || bound != nil {
            throw PRShepherdCLIError(message: "Could not load the pull request: \(message)")
        }
        // The record may have changed while the fetch ran; report it as it is now.
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
                message: "The PR shepherd works on git worktrees only. Folders and Workspace checkouts are not supported yet."
            )
        }
        return (effects, context)
    }

    /// Re-binding a PR this session already shepherds keeps its toggles; a new
    /// binding, including one taken over from another session, takes the
    /// Settings defaults.
    private func bindPRShepherd(sessionID: String, worktreeID: String, request: ReviewRequest) async -> ShepherdRecord {
        let current = reviewShepherd.records[ShepherdRecordID(worktreeID: worktreeID, request: request)]
            .flatMap { $0.sessionID == sessionID ? $0 : nil }
        let defaults = environment.configuration().changes.shepherd
        return await reviewShepherd.bind(
            sessionID: sessionID,
            worktreeID: worktreeID,
            request: request,
            baseBranch: request.baseRefName,
            autoFix: current?.autoFix ?? defaults.autoFix,
            autoMerge: current?.autoMerge ?? defaults.autoMerge,
            maxFixAttempts: current?.fixAttemptBudget ?? defaults.maxFixAttempts,
            contextRules: nil
        )
    }

    /// `base` without a leading `<remote>/` that names a configured remote,
    /// so `origin/main` and `main` are one base for the push-safety checks.
    public static func normalizedBaseBranch(_ base: String, remoteNames: Set<String>) -> String {
        guard let remote = remoteNames.filter({ base.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }),
              base.count > remote.count + 1
        else { return base }
        return String(base.dropFirst(remote.count + 1))
    }

    /// `baseBranch` must already be normalized (`normalizedBaseBranch`).
    public static func prCreateBranchBlocker(_ local: ReviewLoopLocalState, baseBranch: String) -> String? {
        if local.branchName.isEmpty {
            return "HEAD is detached. Check out a branch before opening a pull request."
        }
        if local.branchName == baseBranch {
            return "This worktree is on the base branch \(baseBranch). Open a pull request from a feature branch."
        }
        if local.aheadCommitCount == 0 {
            return "\(local.branchName) has no commits ahead of \(baseBranch)."
        }
        // The upstream holds commits this worktree lacks: adopting or
        // publishing would leave the request's head ahead of HEAD, and the
        // shepherd could never call it ready. An upstream that is the base
        // (a worktree created from origin/main) is never pushed or adopted.
        if let upstream = local.upstreamBranchName, upstream != baseBranch,
           local.pushState == .stale || local.pushState == .diverged {
            return "\(upstream) on the remote has commits this worktree doesn't. Pull or merge them into \(local.branchName), then call pr_create again."
        }
        return nil
    }

    /// The upstream `pr_create` may push to: only one named like the local
    /// branch. Any other upstream (a worktree created from `origin/main`, say)
    /// is dropped, so the push goes to `refs/heads/<branch>`.
    public static func prCreateUpstreamToKeep(branch: String, upstream: String?) -> String? {
        upstream == branch ? upstream : nil
    }

    /// Branch names searched for an open request before creating one: the
    /// local branch, and a differently named upstream unless it is the base.
    public static func prCreateLookupBranches(_ local: ReviewLoopLocalState) -> [String] {
        guard let upstream = local.upstreamBranchName, !upstream.isEmpty,
              upstream != local.branchName, upstream != local.baseBranch
        else { return [local.branchName] }
        return [local.branchName, upstream]
    }

    public enum PRCreateAdoption: Equatable, Sendable {
        /// Run the exact-SHA push first, then bind the open request.
        case publishThenBind
        case bind
        case blocked(String)
    }

    /// What `pr_create` does with an open request whose head is `headRefName`.
    /// One on this branch gets the pending HEAD pushed first; one on a
    /// differently named upstream is never pushed to, so unpushed commits there
    /// block rather than report a request that lacks them.
    public static func prCreateAdoption(
        headRefName: String, number: Int, kind: CodeHostKind, local: ReviewLoopLocalState
    ) -> PRCreateAdoption {
        if headRefName == local.branchName { return .publishThenBind }
        guard local.needsPush else { return .bind }
        let request = "\(kind.reviewRequestLabel) \(kind.reviewRequestNumberPrefix)\(number)"
        return .blocked(
            "\(local.branchName) tracks \(headRefName), which has open \(request). "
                + "Push your commits to \(headRefName) or stop tracking it (`git branch --unset-upstream`), "
                + "then call pr_create again."
        )
    }

    public static func prProviderSetupProblem(_ snapshot: ReviewLoopSnapshot) -> String? {
        guard let remote = snapshot.remote else { return nil }
        if !snapshot.providerAvailable { return prProviderSetupMessage(kind: remote.kind, isInstalled: false) }
        if !snapshot.providerAuthenticated { return prProviderSetupMessage(kind: remote.kind, isInstalled: true) }
        return nil
    }

    public static func prProviderErrorMessage(_ error: CodeHostProviderError, kind: CodeHostKind) -> String {
        switch error {
        case .cliMissing: prProviderSetupMessage(kind: kind, isInstalled: false)
        case .unauthenticated: prProviderSetupMessage(kind: kind, isInstalled: true)
        default: error.localizedDescription
        }
    }

    public static func prProviderSetupMessage(kind: CodeHostKind, isInstalled: Bool) -> String {
        let cli = switch kind {
        case .github: "gh"
        case .gitlab: "glab"
        }
        if isInstalled {
            return "\(kind.displayName) CLI (\(cli)) is not signed in. Run `\(cli) auth login`, then try again."
        }
        return "\(kind.displayName) CLI (\(cli)) is not installed. Install it with `brew install \(cli)`, then run `\(cli) auth login`."
    }

    public static func prShepherdErrorMessage(_ error: Error) -> String {
        (error as? PRShepherdCLIError)?.message ?? error.localizedDescription
    }
}

extension AlasHost {
    /// Pull and merge requests an agent opens for its worktree, and the
    /// shepherd that watches them.
    public var prs: PRsAPI { PRsAPI(core: core) }
}

@MainActor
public struct PRsAPI {
    let core: AlasCoreContext

    /// Pushes the exact HEAD of `worktreeID`, opens its PR/MR or adopts the
    /// open one for its branch, and binds the shepherd to session `sessionID`.
    public func create(sessionID: String, worktreeID: String, title: String, body: String, draft: Bool, base: String?) async -> AlasCLIResponse {
        await core.createPR(sessionID: sessionID, worktreeID: worktreeID, title: title, body: body, draft: draft, base: base)
    }

    /// Fresh status of the PR/MR bound to session `sessionID`, else of the
    /// worktree branch's.
    public func status(sessionID: String, worktreeID: String) async -> AlasCLIResponse {
        await core.prStatus(sessionID: sessionID, worktreeID: worktreeID)
    }
}
