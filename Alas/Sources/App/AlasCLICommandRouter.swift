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
    var workspaceCommand: (AlasCLIRequest.WorkspaceCommand) async -> AlasCLIResponse = { _ in
        .error("Workspace automation is not available yet.")
    }
    var previewCommand: (WebPreviewCommand, SessionOwnerID, String?) async -> AlasCLIResponse = { _, _, _ in
        .error("Preview automation is not available.")
    }
    var activateApp: () -> Void
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
            activateApp: activateApp
        )
    }

    /// The one-line reply to `visual_show`; the MCP bridge reads `presentation` to word its result.
    static func visualShowReply(id: UUID, presentation: ACPVisualAid.Presentation) -> String {
        #"{"visual_id":"\#(id.uuidString)","presentation":"\#(presentation.rawValue)"}"#
    }

    func handle(_ request: AlasCLIRequest) async -> AlasCLIResponse {
        let service = self.service
        let callers = host.callers
        // Attributed to the session only once the host knows it.
        let caller: HostCaller = request.sessionId.flatMap { id in callers.owner(ofSession: id).map { _ in .session(id: id) } } ?? .cli
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
        case .visualShow(let title, let html, let question, let presentation):
            guard let sessionId = request.sessionId, callers.acpOrigin(ofSession: sessionId) != nil else {
                return .error("visual_show is only available to ACP agent sessions")
            }
            let resolved = ACPVisualAid.resolvePresentation(requested: presentation, hasQuestion: question != nil)
            let visual = ACPVisualAid(
                id: UUID(), title: title, html: html, question: question,
                presentation: resolved, answer: nil, createdAt: Date()
            )
            do {
                try await host.sessions.showVisualAid(visual, in: sessionId, caller: caller)
                return .text([Self.visualShowReply(id: visual.id, presentation: resolved)])
            } catch {
                return .error("This session can't show visuals right now.")
            }
        case .agentList, .sessionList, .sessionNew, .sessionSend, .sessionAction:
            guard let sessionId = request.sessionId,
                  callers.acpOrigin(ofSession: sessionId) != nil else {
                return .error("session commands require an originating ACP session")
            }
            // Anchor worktree selectors on the caller's host, like the origin path below.
            let request = await callers.worktree(ofSession: sessionId, cwd: nil)
                .map { request.virtualizingPaths(like: $0.path.path) } ?? request

            switch request.command {
            case .agentList(let worktree):
                return await host.delegation.agents(worktree: worktree, caller: caller)
            case .sessionList:
                return await host.delegation.list(caller: caller)
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
                return await host.delegation.create(
                    ACPDelegatedSessionNewRequest(
                        prompt: prompt,
                        agentId: agentID,
                        worktree: target,
                        modelSelection: ACPDelegatedModelSelection(model: model, reasoning: reasoning),
                        role: role
                    ),
                    caller: caller
                )
            case .sessionSend(let sessionID, let prompt):
                return await host.delegation.send(
                    ACPDelegatedSessionMessageRequest(targetSessionId: sessionID, prompt: prompt), caller: caller
                )
            case .sessionAction(let action):
                return await host.delegation.perform(action, caller: caller)
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
            return notify(body, title: title, level: level, from: .checkoutSession(sessionId, owner: owner), caller: caller)
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
            return notify(
                body, title: title, level: level,
                from: .worktree(origin, sessionID: request.sessionId, owner: originOwner), caller: caller
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
            return host.reviews.comments(
                origin: origin, sessionID: sessionID, filter: state, projectWorktrees: projectWorktrees
            )
        case .review(.reply(let commentID, let body)):
            return host.reviews.reply(
                origin: origin, commentID: commentID, body: body, projectWorktrees: projectWorktrees
            )
        case .review(.resolve(let commentID, let reply, let reopen)):
            return host.reviews.resolve(
                origin: origin, commentID: commentID, reply: reply, reopen: reopen, projectWorktrees: projectWorktrees
            )
        case .review(.commentAdd(let path, let startLine, let endLine, let side, let body, let sessionID)):
            return await host.reviews.addComment(
                origin: origin, path: path, startLine: startLine, endLine: endLine,
                side: side, body: body, sessionID: sessionID, projectWorktrees: projectWorktrees
            )
        case .review(.finish(let sessionID, let verdict, let summary)):
            return host.reviews.finish(
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

    private func notify(_ body: String, title: String?, level: AlasCLINotifyLevel, from source: NoticeSource, caller: HostCaller) -> AlasCLIResponse {
        do {
            try host.attention.notify(body, title: title, needsInput: level == .attention, from: source, caller: caller)
            return .ok
        } catch {
            return .error("Unknown worktree.")
        }
    }
}
