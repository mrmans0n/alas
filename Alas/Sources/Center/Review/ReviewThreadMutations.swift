import Foundation

enum ReviewThreadMutations {
    static func applyReply(
        to threads: [ReviewThread],
        threadID: String,
        comment: ReviewComment
    ) -> [ReviewThread] {
        threads.map { $0.id == threadID ? $0.addingReply(comment) : $0 }
    }

    static func applyResolve(
        to threads: [ReviewThread],
        threadID: String
    ) -> [ReviewThread] {
        threads.map { $0.id == threadID ? $0.withResolved(true) : $0 }
    }

    static func applyUnresolve(
        to threads: [ReviewThread],
        threadID: String
    ) -> [ReviewThread] {
        threads.map { $0.id == threadID ? $0.withResolved(false) : $0 }
    }

    static func applyEdit(
        to threads: [ReviewThread],
        threadID: String,
        commentID: String,
        newBody: String
    ) -> [ReviewThread] {
        threads.map { thread in
            guard thread.id == threadID,
                  let comment = thread.comments.first(where: { $0.id == commentID })
            else { return thread }
            let updated = ReviewComment(
                id: comment.id,
                author: comment.author,
                body: newBody,
                url: comment.url,
                createdAt: comment.createdAt,
                viewerCanUpdate: comment.viewerCanUpdate,
                viewerCanDelete: comment.viewerCanDelete,
                isPending: comment.isPending
            )
            return thread.replacingComment(id: commentID, with: updated)
        }
    }

    static func applyDelete(
        to threads: [ReviewThread],
        threadID: String,
        commentID: String
    ) -> [ReviewThread] {
        threads.map { $0.id == threadID ? $0.removingComment(id: commentID) : $0 }
    }
}
