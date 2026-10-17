import Foundation

extension AlasHost {
    /// Notices that ask for the user, as an agent sends them with `alas notify`.
    public var attention: AttentionAPI { AttentionAPI(core: core) }
}

/// Where a notice comes from, which is what clicking it opens.
public enum NoticeSource: Equatable, Sendable {
    /// A worktree, and the session in it that sent the notice, if one did.
    case worktree(Worktree, sessionID: String?, owner: SessionOwnerID?)
    /// A session of a Workspace checkout, which no project worktree stands for.
    case checkoutSession(String, owner: SessionOwnerID)
}

public enum AttentionRefusal: Error, Equatable, Sendable {
    /// The worktree is not listed by any project.
    case unknownWorktree
}

@MainActor
public struct AttentionAPI {
    let core: AlasCoreContext

    /// Shows `body` as a notification from `source`. With `needsInput`, the
    /// sending session is also marked as waiting for its user.
    public func notify(_ body: String, title: String?, needsInput: Bool, from source: NoticeSource, caller: HostCaller) throws {
        let harness = core.harness
        let sessionID: String?
        let owner: SessionOwnerID?
        switch source {
        case .worktree(let worktree, let session, let worktreeOwner):
            caller.log("attention.notify", worktree.id)
            guard let resolved = core.projectAndWorktree(withWorktreeId: worktree.id) else { throw AttentionRefusal.unknownWorktree }
            sessionID = session
            owner = worktreeOwner
            harness.notifications.notifyAlas(
                body: body, title: title, agent: agent(of: session),
                projectId: resolved.project.id, worktreeId: resolved.worktree.id,
                sessionId: session ?? worktree.id, owner: owner
            )
        case .checkoutSession(let session, let checkoutOwner):
            caller.log("attention.notify", session)
            sessionID = session
            owner = checkoutOwner
            harness.notifications.notifyAlas(body: body, title: title, agent: agent(of: session), sessionId: session, owner: checkoutOwner)
        }
        if needsInput, let sessionID {
            harness.setExternalActivity(
                sessionId: sessionID, owner: owner, agent: agent(of: sessionID), state: .awaitingInput, body: body, requiresUserInput: true
            )
        }
    }

    /// The agent behind session `sessionID`, as its hooks or its ACP session
    /// report it; Codex when nothing does.
    private func agent(of sessionID: String?) -> AgentKind {
        guard let sessionID else { return .codex }
        let harness = core.harness
        if let activity = harness.activityBySession[sessionID] { return activity.agent }
        if let kind = harness.activeHarnessBySession[sessionID] ?? harness.harnessBySession[sessionID] { return kind.asAgentKind }
        for manager in core.sessionManagers.values {
            if let session = manager.liveSession(for: sessionID) { return AgentKind(acpAgentID: session.agentId) }
        }
        return .codex
    }
}
