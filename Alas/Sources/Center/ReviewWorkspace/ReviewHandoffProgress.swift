import Foundation

extension Notification.Name {
    /// Posted after the CLI/MCP bridge mutates review draft comments so
    /// open review panes reload their controllers.
    static let alasReviewDraftCommentsDidChangeExternally =
        Notification.Name("alasReviewDraftCommentsDidChangeExternally")
}

/// Pure status recomputation for review feedback handoffs: a sent handoff
/// whose comments are all resolved becomes addressed; a sent/addressing
/// session whose handoffs are all addressed becomes addressed.
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
            guard handoff.status == .sent,
                  !handoff.commentIDs.isEmpty,
                  handoff.commentIDs.allSatisfy(isResolved) else { return handoff }
            var addressed = handoff
            addressed.status = .addressed
            changed = true
            return addressed
        }
        if !updated.handoffs.isEmpty,
           updated.handoffs.allSatisfy({ $0.status == .addressed }),
           updated.status == .sent || updated.status == .addressing {
            updated.status = .addressed
            changed = true
        }
        guard changed else { return nil }
        updated.updatedAt = now
        return updated
    }
}
