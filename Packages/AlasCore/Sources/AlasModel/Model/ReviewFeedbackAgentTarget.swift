import Foundation
import AlasFoundation

public enum ReviewFeedbackAgentTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    case newChat(agentID: String, title: String)
    case existingSession(worktreeID: String, sessionID: String, title: String)

    public var id: String {
        switch self {
        case .newChat(let agentID, _):
            return "new:\(agentID)"
        case .existingSession(let worktreeID, let sessionID, _):
            return "existing:\(worktreeID):\(sessionID)"
        }
    }

    public var title: String {
        switch self {
        case .newChat(_, let title), .existingSession(_, _, let title):
            return title
        }
    }

    public var isNewChat: Bool {
        if case .newChat = self { return true }
        return false
    }
}

public struct DiffReviewDraftCommentScrollCommand: Equatable, Sendable {
    public let commentID: String
    public let fileID: DiffReviewFileID
    public let generation: Int

    public var targetID: DiffReviewDraftCommentTargetID {
        DiffReviewDraftCommentTargetID.targetID(commentID: commentID, fileID: fileID)
    }

    public init(commentID: String, fileID: DiffReviewFileID, generation: Int) {
        self.commentID = commentID
        self.fileID = fileID
        self.generation = generation
    }
}

public struct DiffReviewDraftCommentTargetID: Hashable, Equatable, Sendable {
    public let fileID: DiffReviewFileID
    public let commentID: String

    public static func targetID(commentID: String, fileID: DiffReviewFileID) -> DiffReviewDraftCommentTargetID {
        DiffReviewDraftCommentTargetID(fileID: fileID, commentID: commentID)
    }

    public init(fileID: DiffReviewFileID, commentID: String) {
        self.fileID = fileID
        self.commentID = commentID
    }
}
