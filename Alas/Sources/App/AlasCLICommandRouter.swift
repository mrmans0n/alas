import Foundation

@MainActor
struct AlasCLICommandRouter {
    var sessionWorktreeId: (String) -> String?
    var originatingWorktree: (String) -> Worktree?
    var visibleWorktrees: () -> [Worktree]
    var openRelativeFile: (String, String) -> Void
    var openExternalFile: (URL, String) -> Void
    var focusWorktree: (Worktree) -> Void = { _ in }
    var createWorktree: (Worktree, String, String?) async -> AlasCLIResponse = { _, _, _ in
        .error("Creating worktrees from the terminal is not available yet.")
    }
    var deleteWorktree: (Worktree, Bool, Bool) async -> AlasCLIResponse = { _, _, _ in
        .error("Deleting worktrees from the terminal is not available yet.")
    }
    var openReviewChanges: (Worktree) -> Void = { _ in }
    var openProviderReview: (Worktree, String) async -> AlasCLIResponse = { _, _ in
        .error("Opening provider reviews from the terminal is not available yet.")
    }
    var draftCommentStore: () -> ReviewDraftCommentStore = { ReviewDraftCommentStore() }
    var reviewSessionStore: () -> ReviewSessionStore = { ReviewSessionStore() }
    var notifyReviewCommentsChanged: () -> Void = {
        NotificationCenter.default.post(name: .alasReviewDraftCommentsDidChangeExternally, object: nil)
    }
    var now: () -> Date = Date.init
    var gitStatus: (URL) async throws -> [ChangedFile] = { try await GitService().status(worktreePath: $0) }
    var activateApp: () -> Void

    private var service: AlasActionService {
        AlasActionService(
            visibleWorktrees: visibleWorktrees,
            openRelativeFile: openRelativeFile,
            openExternalFile: openExternalFile,
            focusWorktree: focusWorktree,
            createWorktree: createWorktree,
            deleteWorktreeAction: deleteWorktree,
            openReviewChanges: openReviewChanges,
            openProviderReview: openProviderReview,
            draftCommentStore: draftCommentStore,
            reviewSessionStore: reviewSessionStore,
            notifyReviewCommentsChanged: notifyReviewCommentsChanged,
            now: now,
            gitStatus: gitStatus,
            activateApp: activateApp
        )
    }

    func handle(_ request: AlasCLIRequest) async -> AlasCLIResponse {
        let service = self.service
        // Resolve the origin worktree: exact session first, else cwd.
        let origin: Worktree
        if let sessionId = request.sessionId,
           let worktreeId = sessionWorktreeId(sessionId),
           let resolved = originatingWorktree(worktreeId) {
            origin = resolved
        } else if request.sessionId != nil {
            return .error("Unknown Alas terminal session.")
        } else if let cwd = request.cwd, let resolved = service.resolveWorktree(forDirectory: cwd) {
            origin = resolved
        } else {
            return .error("not inside an Alas worktree")
        }

        let projectWorktrees = service.visibleWorktrees().filter { $0.projectId == origin.projectId }
        switch request.command {
        case .resolve:
            return .ok
        case .open(let paths):
            return service.open(paths: paths, fallbackWorktreeId: origin.id)
        case .worktree(.list):
            return service.list(origin: origin, projectWorktrees: projectWorktrees)
        case .worktree(.switch(let target)):
            return service.switch(target: target, projectWorktrees: projectWorktrees)
        case .worktree(.new(let branch, let base)):
            return await service.new(origin: origin, branch: branch, base: base)
        case .worktree(.delete(let target, let force, let keepBranch)):
            return await service.delete(target: target, projectWorktrees: projectWorktrees, force: force, keepBranch: keepBranch)
        case .review(.localChanges):
            return service.reviewLocal(origin: origin)
        case .review(.provider(let target)):
            return await service.reviewProvider(origin: origin, target: target)
        case .review(.comments(let sessionID, let state)):
            return service.reviewComments(origin: origin, sessionID: sessionID, filter: state)
        case .review(.reply(let commentID, let body)):
            return service.reviewReply(origin: origin, commentID: commentID, body: body)
        case .review(.resolve(let commentID, let reply, let reopen)):
            return service.reviewResolve(origin: origin, commentID: commentID, reply: reply, reopen: reopen)
        case .review(.commentAdd(let path, let startLine, let endLine, let side, let body, let sessionID)):
            return await service.reviewCommentAdd(
                origin: origin, path: path, startLine: startLine, endLine: endLine,
                side: side, body: body, sessionID: sessionID
            )
        }
    }
}
