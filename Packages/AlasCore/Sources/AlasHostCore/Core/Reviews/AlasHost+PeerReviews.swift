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
            if !localComments.isEmpty || core.openedLocalChangesReviews.contains(worktree.id) {
                records.append(ReviewSessionRecord(
                    id: localChanges.id,
                    target: localChanges,
                    createdAt: localComments.map(\.createdAt).min() ?? Date(),
                    updatedAt: localComments.map(\.updatedAt).max() ?? Date()
                ))
            }
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }.map { record in
            HostReviewSummary(record: record, openCommentCount: comments.count {
                $0.sessionID == record.target.draftSessionID && $0.state == .active
            })
        }
    }

    /// Review `sessionID` of the worktree with every comment, those on files
    /// that no longer differ included.
    public func read(_ sessionID: String, in worktree: Worktree) throws -> HostReview {
        guard let parsed = ReviewDraftSessionID(rawValue: sessionID), parsed.isFor(worktreeID: worktree.id),
              let summary = try list(in: worktree).first(where: { $0.sessionID == sessionID }) else {
            throw HostError.notFound(what: "review \(sessionID)")
        }
        return HostReview(summary: summary, comments: try core.reviewDrafts.load(sessionID: parsed))
    }
}
