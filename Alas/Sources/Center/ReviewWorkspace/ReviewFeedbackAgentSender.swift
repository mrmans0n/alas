import AppKit
import Foundation

enum ReviewDraftCommentGrouping {
    static func commentsByFileID(_ comments: [ReviewDraftComment]) -> [DiffReviewFileID: [ReviewDraftComment]] {
        Dictionary(grouping: comments, by: \.fileID)
    }
}

/// A review turn: the instruction the agent receives, and the source that
/// makes the transcript show it as a review card.
struct ReviewFeedbackDelivery {
    let text: String
    let source: ACPDelegatedPromptSource
}

extension ReviewFeedbackDelivery {
    init(bundle: ReviewFeedbackBundle, messageID: UUID = UUID()) {
        self.init(
            text: bundle.promptMarkdown(),
            source: .reviewFeedback(card: bundle.card(), commentCount: bundle.activeComments.count, messageID: messageID))
    }
}

@MainActor
struct ReviewFeedbackAgentSender {
    var availableTargets: () -> [ReviewFeedbackAgentTarget]
    var send: (ReviewFeedbackDelivery, ReviewFeedbackAgentTarget, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void
    var agent: (ReviewFeedbackAgentTarget) -> AgentDefinition? = { _ in nil }

    static func production(appState: AppState, worktreeID: String) -> ReviewFeedbackAgentSender {
        ReviewFeedbackAgentSender(
            availableTargets: {
                var targets: [ReviewFeedbackAgentTarget] = []

                var sessionTabs = appState.tabs.tabs(forWorktree: worktreeID)
                if let checkout = selectedCheckout(appState: appState, worktreeID: worktreeID) {
                    sessionTabs += appState.tabs.tabs(for: .workspaceCheckout(checkout.id, checkout.executionLocation))
                }
                // Every open chat tab qualifies, attached or not: a restored tab
                // gets its session and writer lease only once its view mounts,
                // and that lease is not observable from the review UI, so gating
                // on it here hides chats the user can see. `send` attaches first.
                let sessionTargets = sessionTabs.compactMap { tab -> ReviewFeedbackAgentTarget? in
                    guard case .acpSession(let state) = tab else { return nil }
                    let agentName = appState.session(for: state.sessionId)
                        .flatMap { appState.agent(id: $0.agentId)?.displayName }
                    return .existingSession(
                        worktreeID: worktreeID,
                        sessionID: state.sessionId,
                        title: state.title.isEmpty ? agentName ?? "Existing chat" : state.title
                    )
                }
                targets.append(contentsOf: sessionTargets)

                let selectedID = appState.config.changes.aiToolId
                if let agent = Self.availableAgent(appState: appState, worktreeID: worktreeID, agentID: selectedID) {
                    targets.append(.newChat(agentID: agent.id, title: "New chat"))
                }
                return targets
            },
            send: { delivery, target, completion in
                switch target {
                case .newChat(let agentID, _):
                    guard Self.availableAgent(appState: appState, worktreeID: worktreeID, agentID: agentID) != nil else {
                        completion(.failure(ReviewFeedbackAgentSendError.rejected))
                        return
                    }
                    Task { @MainActor in
                        guard let opened = await Self.openNewChat(appState: appState, worktreeID: worktreeID, agentID: agentID) else {
                            completion(.failure(ReviewFeedbackAgentSendError.rejected))
                            return
                        }
                        await Self.deliver(delivery, appState: appState, sessionID: opened.sessionID, owner: opened.owner) { result in
                            if case .failure = result {
                                Self.keepAsDraft(delivery, appState: appState, sessionID: opened.sessionID)
                            }
                            completion(result)
                        }
                    }
                case .existingSession(let targetWorktreeID, let sessionID, _):
                    let owner = Self.sessionOwner(appState: appState, worktreeID: targetWorktreeID, sessionID: sessionID)
                    if case .workspaceCheckout = owner {
                        appState.activateHarnessSession(owner: owner, sessionId: sessionID)
                    } else if let resolved = Self.projectAndWorktree(appState: appState, worktreeID: targetWorktreeID) {
                        appState.activateHarnessSession(
                            projectId: resolved.project.id,
                            worktreeId: targetWorktreeID,
                            sessionId: sessionID
                        )
                    }
                    Task { @MainActor in
                        await Self.deliver(delivery, appState: appState, sessionID: sessionID, owner: owner, completion: completion)
                    }
                }
            },
            agent: { target in
                switch target {
                case .newChat(let agentID, _):
                    return Self.availableAgent(appState: appState, worktreeID: worktreeID, agentID: agentID)
                case .existingSession(_, let sessionID, _):
                    guard let session = appState.session(for: sessionID) else { return nil }
                    return appState.agent(id: session.agentId)
                }
            }
        )
    }

    /// A new chat that refuses the turn (its agent needs sign-in or setup)
    /// would otherwise sit empty: the feedback goes to its composer instead,
    /// to send once the agent is ready.
    private static func keepAsDraft(_ delivery: ReviewFeedbackDelivery, appState: AppState, sessionID: String) {
        guard let manager = appState.acpManager(forSession: sessionID),
              let session = manager.liveSession(for: sessionID),
              session.composerDraft.isEmpty
        else { return }
        manager.persistComposerDraft(ACPComposerDraft(segments: [.text(delivery.text)]), for: session)
    }

    /// Opens a chat for the review to go out in right away, in the focused
    /// checkout when there is one, else in the worktree.
    private static func openNewChat(
        appState: AppState, worktreeID: String, agentID: String
    ) async -> (sessionID: String, owner: SessionOwnerID)? {
        if let checkout = selectedCheckout(appState: appState, worktreeID: worktreeID) {
            guard let tab = await appState.openWorkspaceCheckoutACPSession(checkout: checkout, agentID: agentID) else { return nil }
            return (tab.sessionId, .workspaceCheckout(checkout.id, checkout.executionLocation))
        }
        guard let resolved = projectAndWorktree(appState: appState, worktreeID: worktreeID),
              let owner = appState.acpManager(for: resolved.worktree)?.owner
        else { return nil }
        appState.focusGlobalWorktree(id: resolved.worktree.id, projectId: resolved.project.id)
        guard let tab = appState.openNewACPSession(agentID: agentID, owner: owner, projectId: resolved.project.id) else { return nil }
        return (tab.sessionId, owner)
    }

    /// Reports success once the session takes the prompt, not when the turn
    /// ends: the agent resolves comments during that turn, so the handoff
    /// has to be on record first.
    private static func deliver(
        _ delivery: ReviewFeedbackDelivery,
        appState: AppState,
        sessionID: String,
        owner: SessionOwnerID,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) async {
        let report = ReportOnce(completion)
        await appState.prepareACPSessionForPrompt(sessionId: sessionID, owner: owner)
        await appState.sendPrompt(
            for: sessionID, text: delivery.text, attachments: [],
            delegatedSource: delivery.source, normalUserTurn: false,
            onAccepted: { report(.success(())) }
        ) { ended in
            report(ended ? .success(()) : .failure(ReviewFeedbackAgentSendError.rejected))
        }
    }

    /// Hands the first result to `completion` and drops the rest.
    @MainActor
    private final class ReportOnce {
        private var completion: (@MainActor (Result<Void, Error>) -> Void)?

        init(_ completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            self.completion = completion
        }

        func callAsFunction(_ result: Result<Void, Error>) {
            let completion = completion
            self.completion = nil
            completion?(result)
        }
    }

    private static func availableAgent(appState: AppState, worktreeID: String, agentID: String?) -> AgentDefinition? {
        if let checkout = selectedCheckout(appState: appState, worktreeID: worktreeID) {
            return appState.availableAgentForHandoff(id: agentID, checkout: checkout)
        }
        guard let resolved = projectAndWorktree(appState: appState, worktreeID: worktreeID) else { return nil }
        return appState.availableAgentForHandoff(id: agentID, worktree: resolved.worktree)
    }

    private static func selectedCheckout(appState: AppState, worktreeID: String) -> WorkspaceCheckout? {
        guard appState.checkoutFocusedWorktreeScope?.worktreeID == worktreeID else { return nil }
        return appState.selectedWorkspaceCheckout
    }

    /// The owner whose tab holds `sessionID`. A session that is not live yet
    /// is resolved from the open tabs of the focused checkout, else the worktree.
    private static func sessionOwner(appState: AppState, worktreeID: String, sessionID: String) -> SessionOwnerID {
        if let owner = appState.session(for: sessionID)?.owner { return owner }
        if let checkout = selectedCheckout(appState: appState, worktreeID: worktreeID) {
            let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
            let hasTab = appState.tabs.tabs(for: owner).contains { tab in
                guard case .acpSession(let state) = tab else { return false }
                return state.sessionId == sessionID
            }
            if hasTab { return owner }
        }
        return .worktree(worktreeID)
    }

    private static func projectAndWorktree(
        appState: AppState,
        worktreeID: String
    ) -> (project: ProjectConfig, worktree: Worktree)? {
        for project in appState.projectsManager.projects {
            if let worktree = appState.projectsManager.worktrees(projectId: project.id).first(where: { $0.id == worktreeID }) {
                return (project, worktree)
            }
        }
        return nil
    }
}

enum ReviewFeedbackAgentSendError: LocalizedError, Equatable {
    case rejected

    var errorDescription: String? {
        switch self {
        case .rejected:
            "Agent rejected the prompt."
        }
    }
}

enum ReviewFeedbackPromptActions {
    static func copyPrompt(
        _ bundle: ReviewFeedbackBundle,
        pasteboard: (String) -> Void = copyReviewPrompt
    ) {
        pasteboard(bundle.promptMarkdown())
    }

    @MainActor
    static func sendToAgent(
        _ bundle: ReviewFeedbackBundle,
        target: ReviewFeedbackAgentTarget,
        sender: ReviewFeedbackAgentSender
    ) {
        sendToAgent(
            bundle,
            target: target,
            sender: sender,
            sessionID: nil,
            recordHandoff: nil
        )
    }

    @MainActor
    static func sendToAgent(
        _ bundle: ReviewFeedbackBundle,
        target: ReviewFeedbackAgentTarget,
        sender: ReviewFeedbackAgentSender,
        sessionID: ReviewSessionID?,
        recordHandoff: ((ReviewFeedbackHandoff) -> Void)?,
        recordSendFailure: ((Error) -> Void)? = nil,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> String = { UUID().uuidString }
    ) {
        let delivery = ReviewFeedbackDelivery(bundle: bundle)
        let prompt = delivery.text
        sender.send(delivery, target) { result in
            switch result {
            case .success:
                guard let sessionID, let recordHandoff else { return }
                let commentIDs = bundle.activeComments.map(\.id).sorted()
                recordHandoff(
                    ReviewFeedbackHandoff(
                        id: makeID(),
                        sessionID: sessionID,
                        commentIDs: commentIDs,
                        target: target,
                        createdAt: now(),
                        promptRevision: ReviewFeedbackHandoff.revisionKey(commentIDs: commentIDs, prompt: prompt),
                        status: .sent
                    )
                )
            case .failure(let error):
                recordSendFailure?(error)
            }
        }
    }

    private static func copyReviewPrompt(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }
}

@MainActor
enum ReviewDraftWorkspaceActions {
    static func make(
        controller: ReviewDraftCommentController?,
        sender: ReviewFeedbackAgentSender,
        sessionID: ReviewSessionID? = nil,
        recordHandoff: ((ReviewFeedbackHandoff) -> Void)? = nil,
        recordSendFailure: ((Error) -> Void)? = nil,
        worktreeID: String? = nil,
        now: @escaping () -> Date = Date.init,
        sessionStore: @escaping () -> ReviewSessionStore = { ReviewSessionStore() },
        acknowledgeCommentAttention: @escaping (ReviewDraftComment) -> Void = { _ in },
        notifyExternalChange: @escaping () -> Void = {
            NotificationCenter.default.post(name: .alasReviewDraftCommentsDidChangeExternally, object: nil)
        },
        pasteboard: @escaping (String) -> Void = { prompt in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(prompt, forType: .string)
        }
    ) -> ReviewDraftCommentActions {
        return ReviewDraftCommentActions(
            availability: { comment in
                let hasCurrentSendTarget = !sender.availableTargets().isEmpty
                return ReviewDraftCommentActionAvailability(
                    canEdit: comment.isActive,
                    canDelete: true,
                    canResolve: comment.isActive,
                    canDismiss: comment.isActive,
                    canCopyPrompt: comment.isActive,
                    canShowSendToAgent: true,
                    canSendToAgent: comment.isActive && hasCurrentSendTarget
                )
            },
            edit: { comment, bodyMarkdown in
                try? controller?.edit(commentID: comment.id, bodyMarkdown: bodyMarkdown)
            },
            delete: { comment in
                guard let controller else { return }
                do {
                    try controller.delete(commentID: comment.id)
                    acknowledgeCommentAttention(comment)
                } catch {}
            },
            resolve: { comment in
                guard let controller else { return }
                do {
                    try controller.resolve(commentID: comment.id)
                    acknowledgeCommentAttention(comment)
                } catch {
                    return
                }
                guard let worktreeID else { return }
                try? ReviewHandoffProgress.recomputeAndPersist(
                    worktreeID: worktreeID,
                    sessionStore: sessionStore(),
                    isResolved: { id in controller.persistedComment(withID: id)?.state == .resolved },
                    now: now()
                )
                // Mirror the CLI/MCP resolve path: notify open review panes so a
                // tab whose in-memory record was just recomputed on disk reloads
                // it, instead of later persisting a stale record and clobbering
                // the freshly written addressed status back to sent.
                notifyExternalChange()
            },
            dismiss: { comment in
                guard let controller else { return }
                do {
                    try controller.dismiss(commentID: comment.id)
                    acknowledgeCommentAttention(comment)
                } catch {}
            },
            copyPrompt: { bundle in
                ReviewFeedbackPromptActions.copyPrompt(bundle, pasteboard: pasteboard)
            },
            agent: { target in
                sender.agent(target)
            },
            agentTargets: {
                sender.availableTargets()
            },
            sendToAgent: { bundle, target in
                ReviewFeedbackPromptActions.sendToAgent(
                    bundle,
                    target: target,
                    sender: sender,
                    sessionID: sessionID,
                    recordHandoff: recordHandoff,
                    recordSendFailure: recordSendFailure
                )
            }
        )
    }
}

struct DiffReviewDraftCommentScrollController: Equatable {
    private(set) var generation = 0

    mutating func command(commentID: String, fileID: DiffReviewFileID) -> DiffReviewDraftCommentScrollCommand {
        generation += 1
        return DiffReviewDraftCommentScrollCommand(
            commentID: commentID,
            fileID: fileID,
            generation: generation
        )
    }
}
