import Foundation

struct DiffReviewRenderRow: Identifiable, Equatable {
    let index: Int
    let id: DiffReviewFileID
    let showsBottomSpacing: Bool
}

/// Keeps the review stream deterministic: every loaded file is render-eligible,
/// and SwiftUI's `LazyVStack` is the only virtualization layer.
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
                showsBottomSpacing: index != lastIndex
            )
        }
    }
}
