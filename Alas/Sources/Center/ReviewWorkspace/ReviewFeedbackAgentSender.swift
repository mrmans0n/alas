import AppKit
import Foundation

enum ReviewDraftCommentGrouping {
    static func commentsByFileID(_ comments: [ReviewDraftComment]) -> [DiffReviewFileID: [ReviewDraftComment]] {
        Dictionary(grouping: comments, by: \.fileID)
    }
}

enum ReviewFeedbackAgentTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    case newChat(agentID: String, title: String)
    case existingSession(worktreeID: String, sessionID: String, title: String)

    var id: String {
        switch self {
        case .newChat(let agentID, _):
            return "new:\(agentID)"
        case .existingSession(let worktreeID, let sessionID, _):
            return "existing:\(worktreeID):\(sessionID)"
        }
    }

    var title: String {
        switch self {
        case .newChat(_, let title), .existingSession(_, _, let title):
            return title
        }
    }
}

@MainActor
struct ReviewFeedbackAgentSender {
    var availableTargets: () -> [ReviewFeedbackAgentTarget]
    var send: (String, ReviewFeedbackAgentTarget, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void

    static func production(appState: AppState, worktreeID: String) -> ReviewFeedbackAgentSender {
        ReviewFeedbackAgentSender(
            availableTargets: {
                var targets: [ReviewFeedbackAgentTarget] = []
                let agentID = appState.config.changes.aiToolId
                if agentID != "none", appState.agent(id: agentID) != nil {
                    targets.append(.newChat(agentID: agentID, title: "New chat"))
                }

                let sessionTargets = appState.tabs.tabs(forWorktree: worktreeID).compactMap { tab -> ReviewFeedbackAgentTarget? in
                    guard case .acpSession(let state) = tab,
                          appState.session(for: state.sessionId) != nil,
                          appState.isWriter(for: state.sessionId)
                    else { return nil }
                    return .existingSession(
                        worktreeID: worktreeID,
                        sessionID: state.sessionId,
                        title: state.title.isEmpty ? "Existing chat" : state.title
                    )
                }
                targets.append(contentsOf: sessionTargets)
                return targets
            },
            send: { prompt, target, completion in
                switch target {
                case .newChat(let agentID, _):
                    appState.openNewACPSession(agentID: agentID, initialPrompt: prompt)
                    completion(.success(()))
                case .existingSession(_, let sessionID, _):
                    appState.sendPrompt(for: sessionID, text: prompt, attachments: []) { accepted in
                        completion(accepted ? .success(()) : .failure(ReviewFeedbackAgentSendError.rejected))
                    }
                }
            }
        )
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
        let prompt = bundle.promptMarkdown()
        sender.send(prompt, target) { result in
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
                    canShowSendToAgent: hasCurrentSendTarget,
                    canSendToAgent: comment.isActive && hasCurrentSendTarget
                )
            },
            edit: { comment, bodyMarkdown in
                try? controller?.edit(commentID: comment.id, bodyMarkdown: bodyMarkdown)
            },
            delete: { comment in
                try? controller?.delete(commentID: comment.id)
            },
            resolve: { comment in
                try? controller?.resolve(commentID: comment.id)
            },
            dismiss: { comment in
                try? controller?.dismiss(commentID: comment.id)
            },
            copyPrompt: { bundle in
                ReviewFeedbackPromptActions.copyPrompt(bundle, pasteboard: pasteboard)
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

struct DiffReviewDraftCommentScrollCommand: Equatable {
    let commentID: String
    let fileID: DiffReviewFileID
    let generation: Int

    var targetID: DiffReviewDraftCommentTargetID {
        DiffReviewDraftCommentTargetID.targetID(commentID: commentID, fileID: fileID)
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

struct DiffReviewDraftCommentTargetID: Hashable, Equatable {
    let fileID: DiffReviewFileID
    let commentID: String

    static func targetID(commentID: String, fileID: DiffReviewFileID) -> DiffReviewDraftCommentTargetID {
        DiffReviewDraftCommentTargetID(fileID: fileID, commentID: commentID)
    }
}
