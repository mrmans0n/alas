import Foundation
import Observation

@MainActor
@Observable
final class ReviewDraftCommentController {
    private let sessionID: ReviewDraftSessionID
    private let store: ReviewDraftCommentStore
    private let now: () -> Date

    private(set) var comments: [ReviewDraftComment] = []
    var errorMessage: String?

    init(
        sessionID: ReviewDraftSessionID,
        store: ReviewDraftCommentStore = .init(),
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionID = sessionID
        self.store = store
        self.now = now
    }

    func load() throws {
        do {
            comments = try store.load(sessionID: sessionID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func add(anchor: DiffReviewLineAnchor, fileID: DiffReviewFileID, bodyMarkdown: String) throws {
        let timestamp = now()
        let comment = ReviewDraftComment(
            id: UUID().uuidString,
            sessionID: sessionID,
            fileID: fileID,
            path: anchor.path,
            originalPath: nil,
            side: anchor.side,
            startLine: anchor.line,
            endLine: nil,
            selectedText: anchor.selectedText,
            bodyMarkdown: bodyMarkdown,
            state: .active,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        do {
            try store.save(comment)
            comments = try store.load(sessionID: sessionID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func edit(commentID: String, bodyMarkdown: String) throws {
        guard var comment = comments.first(where: { $0.id == commentID }) else { return }
        comment.bodyMarkdown = bodyMarkdown
        comment.updatedAt = now()
        try saveAndReload(comment)
    }

    func resolve(commentID: String) throws {
        guard var comment = comments.first(where: { $0.id == commentID }) else { return }
        comment.state = .resolved
        comment.updatedAt = now()
        try saveAndReload(comment)
    }

    func dismiss(commentID: String) throws {
        guard var comment = comments.first(where: { $0.id == commentID }) else { return }
        comment.state = .dismissed
        comment.updatedAt = now()
        try saveAndReload(comment)
    }

    func delete(commentID: String) throws {
        do {
            try store.delete(commentID: commentID, sessionID: sessionID)
            comments = try store.load(sessionID: sessionID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func saveAndReload(_ comment: ReviewDraftComment) throws {
        do {
            try store.save(comment)
            comments = try store.load(sessionID: sessionID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
