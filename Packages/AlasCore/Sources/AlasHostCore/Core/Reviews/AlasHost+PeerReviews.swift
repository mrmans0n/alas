import Foundation
import AlasFoundation
import AlasModel
import AlasFeatures

extension ReviewsAPI {
    /// The worktree's draft reviews as a paired Mac lists them, newest first:
    /// each saved one not archived, and its local changes, listed but never
    /// saved, once they have comments or were opened.
    public func list(in worktree: Worktree) throws -> [HostReviewSummary] {
        let comments = try core.reviewDrafts.loadAll().filter { $0.sessionID.isFor(worktreeID: worktree.id) }
        var records = try core.reviewSessions.list(worktreeID: worktree.id).filter { $0.status != .archived }
        let localChanges = ReviewSessionTarget.localChanges(worktreeID: worktree.id, repositoryPath: worktree.path, scope: .all)
        if !records.contains(where: { $0.target.draftSessionID == localChanges.draftSessionID }) {
            let localComments = comments.filter { $0.sessionID == localChanges.draftSessionID }
            let opened = core.openedLocalChangesReviews[worktree.id]
            if !localComments.isEmpty || opened != nil {
                let createdAt = localComments.map(\.createdAt).min() ?? opened ?? Date()
                records.append(ReviewSessionRecord(
                    id: localChanges.id,
                    target: localChanges,
                    createdAt: createdAt,
                    updatedAt: localComments.map(\.updatedAt).max() ?? createdAt
                ))
            }
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }.map { record in
            HostReviewSummary(record: record, openCommentCount: comments.count {
                $0.sessionID == record.target.draftSessionID && $0.state == .active
            })
        }
    }

    /// Lists the worktree's local-changes review, as an agent opening it in
    /// the app shows it, and notices the paired Macs the first time.
    public func openLocalChanges(in worktree: Worktree) {
        guard core.openedLocalChangesReviews[worktree.id] == nil else { return }
        core.openedLocalChangesReviews[worktree.id] = Date()
        didChange(worktreeID: worktree.id)
        let session = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all)
        noticeOpened(in: worktree, label: "local changes", sessionID: session.rawValue)
    }

    /// Review `sessionID` of the worktree with every comment, those on files
    /// that no longer differ included. The local-changes review reads before
    /// it is listed, with no comments and nothing saved, so a Mac may start it.
    public func read(_ sessionID: String, in worktree: Worktree) throws -> HostReview {
        guard let parsed = ReviewDraftSessionID(rawValue: sessionID), parsed.isFor(worktreeID: worktree.id) else {
            throw HostError.notFound(what: "review \(sessionID)")
        }
        if let summary = try list(in: worktree).first(where: { $0.sessionID == sessionID }) {
            return HostReview(summary: summary, comments: try core.reviewDrafts.load(sessionID: parsed))
        }
        let localChanges = ReviewSessionTarget.localChanges(worktreeID: worktree.id, repositoryPath: worktree.path, scope: .all)
        guard parsed == localChanges.draftSessionID else { throw HostError.notFound(what: "review \(sessionID)") }
        let now = Date()
        let record = ReviewSessionRecord(id: localChanges.id, target: localChanges, createdAt: now, updatedAt: now)
        return HostReview(summary: HostReviewSummary(record: record, openCommentCount: 0), comments: [])
    }

    /// A paired Mac's change to review `sessionID` of the worktree, made as
    /// the user, as the review pane makes it locally.
    public func mutate(_ mutation: HostReviewMutation, sessionID: String, in worktree: Worktree, caller: HostCaller) async throws {
        caller.log("reviews.mutate", sessionID)
        let localChanges = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all)
        guard let session = ReviewDraftSessionID(rawValue: sessionID), session.isFor(worktreeID: worktree.id) else {
            throw HostError.notFound(what: "review \(sessionID)")
        }
        // The local-changes review is listed only once it has comments, so
        // a Mac may file its first.
        if session != localChanges, try !list(in: worktree).contains(where: { $0.sessionID == sessionID }) {
            throw HostError.notFound(what: "review \(sessionID)")
        }
        let store = core.reviewDrafts
        func existing(_ commentID: String, whenActive: Bool = true) throws -> ReviewDraftComment {
            guard let comment = try store.find(commentID: commentID), comment.sessionID.rawValue == sessionID else {
                throw HostError.notFound(what: "review comment \(commentID)")
            }
            guard !whenActive || comment.isActive else {
                throw HostError.invalidRequest(reason: "This comment is no longer open.")
            }
            return comment
        }
        let now = Date()
        switch mutation {
        case .add(let fileID, let path, let originalPath, let anchor, let body):
            try store.save(try await comment(
                fileID: fileID, path: path, originalPath: originalPath, anchor: anchor, body: body,
                session: session, worktree: worktree, now: now
            ))
        case .edit(let commentID, let body):
            try Self.checkSize(body)
            var comment = try existing(commentID)
            comment.bodyMarkdown = body
            comment.updatedAt = now
            try store.save(comment)
        case .delete(let commentID):
            _ = try existing(commentID, whenActive: false)
            try store.delete(commentID: commentID, sessionID: session)
        case .resolve(let commentID):
            var comment = try existing(commentID)
            comment.state = .resolved
            comment.resolvedBy = .user
            comment.updatedAt = now
            try store.save(comment)
            // Best-effort, as for an agent's resolve: the comment is saved.
            try? ReviewHandoffProgress.recomputeAndPersist(
                worktreeID: worktree.id,
                sessionStore: core.reviewSessions,
                isResolved: { id in (try? store.find(commentID: id))?.state == .resolved },
                now: now
            )
        case .dismiss(let commentID):
            var comment = try existing(commentID)
            comment.state = .dismissed
            comment.updatedAt = now
            try store.save(comment)
        }
        didChange(worktreeID: worktree.id)
    }

    /// The comment a Mac adds, on a file of the review in the namespace it
    /// was filed on, so it lands where the review shows that file.
    private func comment(
        fileID: DiffReviewFileID, path: String, originalPath: String?, anchor: ReviewDraftCommentAnchor, body: String,
        session: ReviewDraftSessionID, worktree: Worktree, now: Date
    ) async throws -> ReviewDraftComment {
        switch anchor {
        case .file:
            break
        case .line(_, let startLine, let endLine, let selectedText):
            guard startLine > 0, (endLine ?? startLine) > 0 else {
                throw HostError.invalidRequest(reason: "A review comment's lines start at 1.")
            }
            try Self.checkSize(selectedText ?? "")
        case .image:
            throw HostError.invalidRequest(reason: "Only file and line comments can be added from a paired Mac.")
        }
        guard [.localChanges, .commit, .trackedCommit, .commitRange, .branch, .reviewRequest].contains(session.sourceKind) else {
            throw HostError.invalidRequest(reason: "Not available from this Mac yet.")
        }
        for text in [body, path, fileID.namespace, originalPath ?? ""] { try Self.checkSize(text) }
        guard let relativePath = Self.worktreeRelativePath(path, worktreeRoot: worktree.path), !relativePath.isEmpty,
              fileID.path == relativePath else {
            throw HostError.invalidRequest(reason: "review comment path must point at a file inside the worktree")
        }
        // ponytail: only local changes check the path is one the review
        // shows; a commit or range comment on another path is kept, unseen.
        let resolution = await fileIDNamespace(
            for: session, path: relativePath, worktreePath: worktree.path, requested: fileID.namespace
        )
        if case .failed(let message) = resolution { throw HostError.invalidRequest(reason: message) }
        return ReviewDraftComment(
            id: UUID().uuidString, sessionID: session, fileID: fileID, path: relativePath, originalPath: originalPath,
            anchor: anchor, bodyMarkdown: body, state: .active, createdAt: now, updatedAt: now, author: .user
        )
    }

    /// Bounds what a Mac stores in the host's review drafts.
    static func checkSize(_ text: String) throws {
        guard text.utf8.count <= 64 * 1024 else {
            throw HostError.invalidRequest(reason: "This review comment is too long.")
        }
    }
}
