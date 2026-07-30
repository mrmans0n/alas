import Foundation

struct DiffReviewRenderRow: Identifiable, Equatable {
    let index: Int
    let id: DiffReviewFileID
    let showsBottomSpacing: Bool
    let automaticallyRendersDiff: Bool
}

/// Keeps the review stream deterministic by deciding automatic eligibility in
/// the loaded-file order.
enum DiffReviewRenderEligibility {
    static func fileIDs(ordered: [DiffReviewFileID]) -> Set<DiffReviewFileID> {
        Set(ordered)
    }

    static func renderRows(ordered fileIDs: [DiffReviewFileID]) -> [DiffReviewRenderRow] {
        let lastIndex = fileIDs.indices.last
        return fileIDs.indices.map { index in
            DiffReviewRenderRow(
                index: index,
                id: fileIDs[index],
                showsBottomSpacing: index != lastIndex,
                automaticallyRendersDiff: true
            )
        }
    }

    static func renderRows(
        ordered fileIDs: [DiffReviewFileID],
        renderedRowCounts: [Int?],
        maxAutomaticallyRenderedRows: Int
    ) -> [DiffReviewRenderRow] {
        precondition(fileIDs.count == renderedRowCounts.count)

        let lastIndex = fileIDs.indices.last
        var automaticallyRenderedRows = 0
        var hasExceededAggregateBudget = false

        return fileIDs.indices.map { index in
            let renderedRowCount = renderedRowCounts[index]
            let isIndividuallyOverBudget = renderedRowCount.map(DiffReviewRenderBudget.isOverBudget) ?? false
            let automaticallyRendersDiff: Bool

            if let renderedRowCount, !isIndividuallyOverBudget {
                let remainingRows = maxAutomaticallyRenderedRows - automaticallyRenderedRows
                automaticallyRendersDiff = !hasExceededAggregateBudget && renderedRowCount <= remainingRows

                if automaticallyRendersDiff {
                    automaticallyRenderedRows += renderedRowCount
                } else {
                    hasExceededAggregateBudget = true
                }
            } else {
                automaticallyRendersDiff = true
            }

            return DiffReviewRenderRow(
                index: index,
                id: fileIDs[index],
                showsBottomSpacing: index != lastIndex,
                automaticallyRendersDiff: automaticallyRendersDiff
            )
        }
    }
}
