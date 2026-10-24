import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasSessions

extension AlasHost {
    /// Notices that ask for the user, as an agent sends them with `alas notify`.
    public var attention: AttentionAPI { AttentionAPI(core: core, changed: { [weak self] in self?.noteAttention($0) }) }
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
    /// Publishes events about attention, such as a relayed notice.
    var changed: @MainActor ([HostEvent]) -> Void = { _ in }

    /// Shows `body` as a notification from `source`. With `needsInput`, the
    /// sending session is also marked as waiting for its user. A host that
    /// relays notices hands a session's notice to its subscribers instead,
    /// and only logs one sent with no session.
    public func notify(_ body: String, title: String?, needsInput: Bool, from source: NoticeSource, caller: HostCaller) throws {
        let harness = core.harness
        let sessionID: String?
        let owner: SessionOwnerID?
        let noticeOwner: SessionOwnerID
        switch source {
        case .worktree(let worktree, let session, let worktreeOwner):
            caller.log("attention.notify", worktree.id)
            guard let resolved = core.projectAndWorktree(withWorktreeId: worktree.id) else { throw AttentionRefusal.unknownWorktree }
            sessionID = session
            owner = worktreeOwner
            noticeOwner = worktreeOwner ?? .worktree(worktree.id)
            guard !core.environment.relaysNotices else { break }
            harness.notifications.notifyAlas(
                body: body, title: title, agent: agent(of: session),
                projectId: resolved.project.id, worktreeId: resolved.worktree.id,
                sessionId: session ?? worktree.id, owner: owner
            )
        case .checkoutSession(let session, let checkoutOwner):
            caller.log("attention.notify", session)
            sessionID = session
            owner = checkoutOwner
            noticeOwner = checkoutOwner
            guard !core.environment.relaysNotices else { break }
            harness.notifications.notifyAlas(body: body, title: title, agent: agent(of: session), sessionId: session, owner: checkoutOwner)
        }
        guard let sessionID else { return }
        // A relaying host reports the wait from `noticeAwaitingClears` instead.
        guard core.environment.relaysNotices else {
            if needsInput {
                harness.setExternalActivity(
                    sessionId: sessionID, owner: owner, agent: agent(of: sessionID), state: .awaitingInput, body: body, requiresUserInput: true
                )
            }
            return
        }
        if needsInput, let session = core.sessionManagers.values.lazy.compactMap({ $0.liveSession(for: sessionID) }).first {
            // Cleared by the user's next prompt, which every turn starts
            // with, rather than by any change: the agent usually asks
            // mid-turn, and the end of that turn is no answer.
            // ponytail: a notice from a session with no live agent is never reported waiting; it can't happen from MCP, which needs one
            let clear = session.transcript.$streamingState.signal.observe { [weak core] state in
                if state == .sending { core?.noticeAwaitingClears[sessionID] = nil }
            }
            core.noticeAwaitingClears[sessionID] = NoticeAwaitingInput(transcript: session.transcript, clear: clear)
        }
        changed([.notice(HostNotice(id: UUID(), owner: noticeOwner, sessionID: sessionID, agent: agent(of: sessionID).rawValue, title: title, body: body))])
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

extension AlasCoreContext {
    /// A session's state as Remote clients see it: waiting for its user
    /// while a relayed notice asks for input and no turn runs.
    func reportedStreamingState(of sessionID: String, live: ACPSession.StreamingState?) -> ACPSession.StreamingState? {
        guard let waiting = noticeAwaitingClears[sessionID] else { return live }
        let transcript = sessionManagers.values.lazy.compactMap { $0.liveSession(for: sessionID) }.first?.transcript
        guard let transcript, waiting.transcript === transcript else {
            // The session was dropped, and may have come back as another:
            // nothing watches for its next prompt any more.
            noticeAwaitingClears[sessionID] = nil
            return live
        }
        return live == .idle ? .awaitingInput : live
    }
}

/// A relayed notice's wait for input, ended by `clear` at its session's next prompt.
struct NoticeAwaitingInput {
    weak var transcript: ACPTranscript?
    let clear: ChangeSubscription
}
