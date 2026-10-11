import Foundation

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

    var isNewChat: Bool {
        if case .newChat = self { return true }
        return false
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

struct DiffReviewDraftCommentTargetID: Hashable, Equatable {
    let fileID: DiffReviewFileID
    let commentID: String

    static func targetID(commentID: String, fileID: DiffReviewFileID) -> DiffReviewDraftCommentTargetID {
        DiffReviewDraftCommentTargetID(fileID: fileID, commentID: commentID)
    }
}
