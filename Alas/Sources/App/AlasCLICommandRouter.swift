import Foundation

@MainActor
struct AlasCLICommandRouter {
    var sessionWorktreeId: (String) -> String?
    var sessionOwner: (String) -> SessionOwnerID? = { _ in nil }
    var sessionCwdWorktree: (String, String) -> Worktree? = { _, _ in nil }
    var resolveACPSessionOrigin: (String) -> ACPOrchestrationSessionOrigin? = { _ in nil }
    var originatingWorktree: (String) -> Worktree?
    var visibleWorktrees: () -> [Worktree]
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var openRelativeFileAtLines: (String, String, ClosedRange<Int>) -> Void = { _, _, _ in }
    var openExternalFileAtLines: (URL, String, ClosedRange<Int>) -> Void = { _, _, _ in }
    var focusWorktree: (Worktree) -> Void = { _ in }
    var createWorktree: (Worktree, String, String?) async -> AlasCLIResponse = { _, _, _ in
        .error("Creating worktrees from the terminal is not available yet.")
    }
    var deleteWorktree: (Worktree, Bool, Bool) async -> AlasCLIResponse = { _, _, _ in
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
    var now: () -> Date = Date.init
    var gitStatus: (URL) async throws -> [ChangedFile] = { try await GitService().status(worktreePath: $0) }
    var providerReviewOriginalPath: (ReviewDraftSessionID, String) async -> String? = { _, _ in nil }
    var notifySession: (String?, SessionOwnerID?, Worktree, String, String?, AlasCLINotifyLevel) -> AlasCLIResponse = { _, _, _, _, _, _ in
        .error("Notifications from the terminal are not available yet.")
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
    var workspaceCommand: (AlasCLIRequest.WorkspaceCommand) async -> AlasCLIResponse = { _ in
        .error("Workspace automation is not available yet.")
    }
    var activateApp: () -> Void

    private var service: AlasActionService {
        AlasActionService(
            visibleWorktrees: visibleWorktrees,
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
            now: now,
            gitStatus: gitStatus,
            providerReviewOriginalPath: providerReviewOriginalPath,
            notifySession: notifySession,
            listDelegatedSessions: listDelegatedSessions,
            createDelegatedSession: createDelegatedSession,
            sendDelegatedSessionMessage: sendDelegatedSessionMessage,
            activateApp: activateApp
        )
    }

    func handle(_ request: AlasCLIRequest) async -> AlasCLIResponse {
        let service = self.service
        switch request.command {
        case .workspace(let command):
            return await workspaceCommand(command)
        case .sessionList, .sessionNew, .sessionSend:
            guard let sessionId = request.sessionId,
                  let acpOrigin = resolveACPSessionOrigin(sessionId) else {
                return .error("session commands require an originating ACP session")
            }

            switch request.command {
            case .sessionList:
                return await service.sessionList(origin: acpOrigin)
            case .sessionNew(let prompt, let agentID, let worktree):
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
                        worktree: target
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
            default:
                preconditionFailure("Session command switch must be exhaustive")
            }
        default:
            break
        }

        // Resolve the origin worktree: exact legacy session first, else cwd.
        // Checkout-owned terminal sessions intentionally do not collapse to a
        // synthetic worktree ID; their repository target is the current cwd.
        let origin: Worktree
        let originOwner: SessionOwnerID?
        if let sessionId = request.sessionId,
           let worktreeId = sessionWorktreeId(sessionId),
           let resolved = originatingWorktree(worktreeId) {
            origin = resolved
            originOwner = sessionOwner(sessionId) ?? .worktree(resolved.id)
        } else if let sessionId = request.sessionId,
                  let cwd = request.cwd,
                  let resolved = sessionCwdWorktree(sessionId, cwd) {
            origin = resolved
            originOwner = sessionOwner(sessionId)
        } else if let cwd = request.cwd, let resolved = service.resolveWorktree(forDirectory: cwd) {
            origin = resolved
            originOwner = .worktree(resolved.id)
        } else if request.sessionId != nil {
            return .error("Unknown Alas terminal session.")
        } else {
            return .error("not inside an Alas worktree")
        }

        let projectWorktrees = service.visibleWorktrees().filter { $0.projectId == origin.projectId }
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
            return await service.new(origin: origin, branch: branch, base: base)
        case .worktree(.delete(let target, let force, let keepBranch)):
            return await service.delete(target: target, projectWorktrees: projectWorktrees, force: force, keepBranch: keepBranch)
        case .workspace:
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
        case .sessionList, .sessionNew, .sessionSend:
            preconditionFailure("Session commands are handled before generic origin resolution")
        }
    }
}
