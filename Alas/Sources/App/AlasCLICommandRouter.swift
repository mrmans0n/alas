import Foundation

@MainActor
struct AlasCLICommandRouter {
    /// Resolves who sent each command and serves the worktrees it acts on.
    var host: AlasHost
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var openRelativeFileAtLines: (String, String, ClosedRange<Int>) -> Void = { _, _, _ in }
    var openExternalFileAtLines: (URL, String, ClosedRange<Int>) -> Void = { _, _, _ in }
    var focusWorktree: (Worktree) -> Void = { _ in }
    var createWorktree: (Worktree, String, String?, HostCaller) async -> AlasCLIResponse = { _, _, _, _ in
        .error("Creating worktrees from the terminal is not available yet.")
    }
    var deleteWorktree: (Worktree, Bool, Bool, HostCaller) async -> AlasCLIResponse = { _, _, _, _ in
        .error("Deleting worktrees from the terminal is not available yet.")
    }
    var openReviewChanges: (Worktree) -> Void = { _ in }
    var openReview: (Worktree, String) async -> AlasCLIResponse = { _, _ in
        .error("Opening provider reviews from the terminal is not available yet.")
    }
    var draftCommentStore: () -> ReviewDraftCommentStore = { ReviewDraftCommentStore() }
    var reviewSessionStore: () -> ReviewSessionStore = { ReviewSessionStore() }
    var notifyReviewCommentsChanged: () -> Void = {
        NotificationCenter.default.post(name: .alasReviewDraftCommentsDidChangeExternally, object: nil)
    }
    var notifyReviewReplyAdded: (Worktree, ReviewDraftComment, ReviewCommentReply) -> Void = { _, _, _ in }
    var now: () -> Date = Date.init
    var gitStatus: (URL) async throws -> [ChangedFile] = { try await GitService().status(worktreePath: $0) }
    var providerReviewOriginalPath: (ReviewDraftSessionID, String) async -> String? = { _, _ in nil }
    var notifySession: (String?, SessionOwnerID?, Worktree, String, String?, AlasCLINotifyLevel) -> AlasCLIResponse = { _, _, _, _, _, _ in
        .error("Notifications from the terminal are not available yet.")
    }
    var notifyOwnedSession: (String, SessionOwnerID, String, String?, AlasCLINotifyLevel) -> AlasCLIResponse = { _, _, _, _, _ in
        .error("Notifications from the terminal are not available yet.")
    }
    var listDelegationAgents: (ACPOrchestrationSessionOrigin, String?) async -> AlasCLIResponse = { _, _ in
        .error("Session orchestration is not available yet.")
    }
    var listDelegatedSessions: (ACPOrchestrationSessionOrigin) async -> AlasCLIResponse = { _ in
        .error("Session orchestration is not available yet.")
    }
    var createDelegatedSession: (ACPOrchestrationSessionOrigin, ACPDelegatedSessionNewRequest) async -> AlasCLIResponse = { _, _ in
        .error("Session orchestration is not available yet.")
    }
    var sendDelegatedSessionMessage: (ACPOrchestrationSessionOrigin, ACPDelegatedSessionMessageRequest) async -> AlasCLIResponse = { _, _ in
        .error("Session orchestration is not available yet.")
    }
    var performDelegatedSessionAction: (ACPOrchestrationSessionOrigin, ACPDelegatedSessionAction) async -> AlasCLIResponse = { _, _ in
        .error("Session orchestration is not available yet.")
    }
    var workspaceCommand: (AlasCLIRequest.WorkspaceCommand) async -> AlasCLIResponse = { _ in
        .error("Workspace automation is not available yet.")
    }
    var previewCommand: (WebPreviewCommand, SessionOwnerID, String?) async -> AlasCLIResponse = { _, _, _ in
        .error("Preview automation is not available.")
    }
    var activateApp: () -> Void
    var showVisualAid: (String, ACPVisualAid) async -> AlasCLIResponse = { _, _ in
        .error("Visual aids are not available yet.")
    }
    var prCreate: (String, String, PRCreateParams) async -> AlasCLIResponse = { _, _, _ in
        .error("The PR shepherd is not available yet.")
    }
    var prStatus: (String, String) async -> AlasCLIResponse = { _, _ in
        .error("The PR shepherd is not available yet.")
    }

    /// Also used by plugins (`review/comment`), so they take the CLI's paths rather than a copy of them.
    var service: AlasActionService {
        AlasActionService(
            visibleWorktrees: { [host] in host.worktrees.list().map(\.worktree) },
            openRelativeFile: openRelativeFile,
            openExternalFile: openExternalFile,
            openRelativeFileAtLines: openRelativeFileAtLines,
            openExternalFileAtLines: openExternalFileAtLines,
            focusWorktree: focusWorktree,
            createWorktree: createWorktree,
            deleteWorktreeAction: deleteWorktree,
            openReviewChanges: openReviewChanges,
            openReview: openReview,
            draftCommentStore: draftCommentStore,
            reviewSessionStore: reviewSessionStore,
            notifyReviewCommentsChanged: notifyReviewCommentsChanged,
            notifyReviewReplyAdded: notifyReviewReplyAdded,
            now: now,
            gitStatus: gitStatus,
            providerReviewOriginalPath: providerReviewOriginalPath,
            notifySession: notifySession,
            listDelegationAgents: listDelegationAgents,
            listDelegatedSessions: listDelegatedSessions,
            createDelegatedSession: createDelegatedSession,
            sendDelegatedSessionMessage: sendDelegatedSessionMessage,
            performDelegatedSessionAction: performDelegatedSessionAction,
            activateApp: activateApp
        )
    }

    func handle(_ request: AlasCLIRequest) async -> AlasCLIResponse {
        let service = self.service
        let callers = host.callers
        let caller: HostCaller = request.sessionId.map { .session(id: $0) } ?? .cli
        switch request.command {
        case .preview(let command):
            let owner: SessionOwnerID
            if let sessionID = request.sessionId {
                guard let resolved = callers.owner(ofSession: sessionID) else {
                    return .error("Unknown Alas session. Preview commands cannot fall back to another owner.")
                }
                owner = resolved
            } else if let cwd = request.cwd, let worktree = callers.worktree(owning: cwd) {
                owner = .worktree(worktree.id)
            } else {
                return .error("not inside an Alas worktree")
            }
            return await previewCommand(command, owner, request.sessionId)
        case .workspace(let command):
            return await workspaceCommand(command)
        case .visualShow(let title, let html, let question):
            guard let sessionId = request.sessionId, callers.acpOrigin(ofSession: sessionId) != nil else {
                return .error("visual_show is only available to ACP agent sessions")
            }
            return await showVisualAid(sessionId, ACPVisualAid(
                id: UUID(), title: title, html: html, question: question, answer: nil, createdAt: Date()
            ))
        case .agentList, .sessionList, .sessionNew, .sessionSend, .sessionAction:
            guard let sessionId = request.sessionId,
                  let acpOrigin = callers.acpOrigin(ofSession: sessionId) else {
                return .error("session commands require an originating ACP session")
            }
            // Anchor worktree selectors on the caller's host, like the origin path below.
            let request = await callers.worktree(ofSession: sessionId, cwd: nil)
                .map { request.virtualizingPaths(like: $0.path.path) } ?? request

            switch request.command {
            case .agentList(let worktree):
                return await service.agentList(origin: acpOrigin, worktree: worktree)
            case .sessionList:
                return await service.sessionList(origin: acpOrigin)
            case .sessionNew(let prompt, let agentID, let worktree, let model, let reasoning, let role):
                let target: ACPDelegatedSessionWorktreeTarget
                switch worktree {
                case .current:
                    target = .current
                case .existing(let worktreeID):
                    target = .existing(worktreeId: worktreeID)
                case .new(let branch, let base):
                    target = .new(branch: branch, base: base)
                }
                return await service.sessionNew(
                    origin: acpOrigin,
                    request: ACPDelegatedSessionNewRequest(
                        prompt: prompt,
                        agentId: agentID,
                        worktree: target,
                        modelSelection: ACPDelegatedModelSelection(model: model, reasoning: reasoning),
                        role: role
                    )
                )
            case .sessionSend(let sessionID, let prompt):
                return await service.sessionSend(
                    origin: acpOrigin,
                    request: ACPDelegatedSessionMessageRequest(
                        targetSessionId: sessionID,
                        prompt: prompt
                    )
                )
            case .sessionAction(let action):
                return await service.sessionAction(origin: acpOrigin, action: action)
            default:
                preconditionFailure("Session command switch must be exhaustive")
            }
        default:
            break
        }

        // Resolve the origin worktree: exact legacy session first, else cwd.
        // Checkout-owned terminal sessions intentionally do not collapse to a
        // synthetic worktree ID; their repository target is the current cwd.
        let requestOwner = request.sessionId.flatMap(callers.owner(ofSession:))
        if case .notify(let body, let title, let level) = request.command,
           let sessionId = request.sessionId,
           let owner = requestOwner,
           case .workspaceCheckout = owner {
            return notifyOwnedSession(sessionId, owner, body, title, level)
        }
        switch request.command {
        case .prCreate, .prStatus:
            if case .workspaceCheckout = requestOwner {
                return .error("The PR shepherd does not support Workspace checkouts yet. Use a regular worktree.")
            }
        default:
            break
        }
        let origin: Worktree
        let originOwner: SessionOwnerID?
        if let sessionId = request.sessionId,
           let resolved = await callers.worktree(ofSession: sessionId, cwd: request.cwd) {
            origin = resolved
            originOwner = requestOwner ?? .worktree(resolved.id)
        } else if let owner = requestOwner,
                  case .workspaceCheckout = owner {
            return .error("Unknown Alas terminal session.")
        } else if let cwd = request.cwd, let resolved = callers.worktree(owning: cwd) {
            origin = resolved
            originOwner = .worktree(resolved.id)
        } else if request.sessionId != nil {
            return .error("Unknown Alas terminal session.")
        } else {
            return .error("not inside an Alas worktree")
        }

        let projectWorktrees = service.visibleWorktrees().filter { $0.projectId == origin.projectId }
        let request = request.virtualizingPaths(like: origin.path.path)
        switch request.command {
        case .resolve:
            return .ok
        case .open(let paths):
            return service.open(paths: paths, fallbackWorktreeId: origin.id)
        case .openAt(let path, let line, let endLine):
            return service.openAt(
                path: path,
                line: line,
                endLine: endLine,
                fallbackWorktreeId: origin.id
            )
        case .notify(let body, let title, let level):
            return service.notify(
                sessionId: request.sessionId,
                owner: originOwner,
                origin: origin,
                body: body,
                title: title,
                level: level
            )
        case .worktree(.list):
            return service.list(origin: origin, projectWorktrees: projectWorktrees)
        case .worktree(.switch(let target)):
            return service.switch(target: target, projectWorktrees: projectWorktrees)
        case .worktree(.new(let branch, let base)):
            return await service.new(origin: origin, branch: branch, base: base, caller: caller)
        case .worktree(.delete(let target, let force, let keepBranch)):
            return await service.delete(target: target, projectWorktrees: projectWorktrees, force: force, keepBranch: keepBranch, caller: caller)
        case .workspace, .preview:
            preconditionFailure("Workspace commands are handled before generic origin resolution")
        case .review(.localChanges(let worktreeOverride)):
            switch service.reviewOrigin(origin: origin, override: worktreeOverride, projectWorktrees: projectWorktrees) {
            case .success(let reviewOrigin):
                return service.reviewLocal(origin: reviewOrigin)
            case .failure(let error):
                return .error(error.message)
            }
        case .review(.target(let target, let worktreeOverride)):
            switch service.reviewOrigin(origin: origin, override: worktreeOverride, projectWorktrees: projectWorktrees) {
            case .success(let reviewOrigin):
                return await service.reviewTarget(origin: reviewOrigin, target: target)
            case .failure(let error):
                return .error(error.message)
            }
        case .review(.comments(let sessionID, let state)):
            return service.reviewComments(
                origin: origin, sessionID: sessionID, filter: state, projectWorktrees: projectWorktrees
            )
        case .review(.reply(let commentID, let body)):
            return service.reviewReply(
                origin: origin, commentID: commentID, body: body, projectWorktrees: projectWorktrees
            )
        case .review(.resolve(let commentID, let reply, let reopen)):
            return service.reviewResolve(
                origin: origin, commentID: commentID, reply: reply, reopen: reopen, projectWorktrees: projectWorktrees
            )
        case .review(.commentAdd(let path, let startLine, let endLine, let side, let body, let sessionID)):
            return await service.reviewCommentAdd(
                origin: origin, path: path, startLine: startLine, endLine: endLine,
                side: side, body: body, sessionID: sessionID, projectWorktrees: projectWorktrees
            )
        case .review(.finish(let sessionID, let verdict, let summary)):
            return service.reviewFinish(
                origin: origin, sessionID: sessionID, verdict: verdict, summary: summary,
                projectWorktrees: projectWorktrees
            )
        case .agentList, .sessionList, .sessionNew, .sessionSend, .sessionAction:
            preconditionFailure("Session commands are handled before generic origin resolution")
        case .visualShow:
            preconditionFailure("visual_show is handled before generic origin resolution")
        case .prCreate(let params):
            guard let sessionId = request.sessionId, callers.acpOrigin(ofSession: sessionId) != nil else {
                return .error("pr_create is only available to ACP agent sessions.")
            }
            return await prCreate(sessionId, origin.id, params)
        case .prStatus:
            guard let sessionId = request.sessionId, callers.acpOrigin(ofSession: sessionId) != nil else {
                return .error("pr_status is only available to ACP agent sessions.")
            }
            return await prStatus(sessionId, origin.id)
        }
    }
}
