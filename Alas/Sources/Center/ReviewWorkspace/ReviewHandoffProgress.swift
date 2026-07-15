import Foundation

extension Notification.Name {
    /// Posted after the CLI/MCP bridge mutates review draft comments so
    /// open review panes reload their controllers.
    static let alasReviewDraftCommentsDidChangeExternally =
        Notification.Name("alasReviewDraftCommentsDidChangeExternally")
}

/// Pure status recomputation for review feedback handoffs: a sent handoff
/// whose comments are all resolved becomes addressed, and demotes back to
/// sent if a comment is later reopened; a sent/addressing session whose
/// handoffs are all addressed becomes addressed, and demotes back to sent
/// once any handoff no longer is. An archived session's own `status` is
/// left alone either way (its individual handoffs can still flip), since
/// archiving is a terminal, user-chosen state this recomputation shouldn't
/// resurrect.
enum ReviewHandoffProgress {
    /// Returns the updated record when anything changed, else nil.
    static func recomputingAddressed(
        record: ReviewSessionRecord,
        isResolved: (String) -> Bool,
        now: Date
    ) -> ReviewSessionRecord? {
        var changed = false
        var updated = record
        updated.handoffs = record.handoffs.map { handoff in
            guard !handoff.commentIDs.isEmpty else { return handoff }
            let allResolved = handoff.commentIDs.allSatisfy(isResolved)
            if handoff.status == .sent, allResolved {
                var addressed = handoff
                addressed.status = .addressed
                changed = true
                return addressed
            }
            if handoff.status == .addressed, !allResolved {
                var reopened = handoff
                reopened.status = .sent
                changed = true
                return reopened
            }
            return handoff
        }
        if !updated.handoffs.isEmpty {
            let allAddressed = updated.handoffs.allSatisfy { $0.status == .addressed }
            if allAddressed, updated.status == .sent || updated.status == .addressing {
                updated.status = .addressed
                changed = true
            } else if !allAddressed, updated.status == .addressed {
                updated.status = .sent
                changed = true
            }
        }
        guard changed else { return nil }
        updated.updatedAt = now
        return updated
    }
}
