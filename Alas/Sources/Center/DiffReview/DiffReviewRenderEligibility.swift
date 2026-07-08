import Foundation

enum DiffReviewRenderEligibility {
    private static let defaultNeighborCount = 8

    static func fileIDs(ordered: [DiffReviewFileID]) -> Set<DiffReviewFileID> {
        fileIDs(
            ordered: ordered,
            selected: ordered.first,
            required: [],
            neighborCount: defaultNeighborCount
        )
    }

    static func fileIDs(
        ordered: [DiffReviewFileID],
        selected: DiffReviewFileID?,
        required: Set<DiffReviewFileID>,
        neighborCount: Int = defaultNeighborCount
    ) -> Set<DiffReviewFileID> {
        guard !ordered.isEmpty else { return [] }

        var eligible = required
        if let selected, ordered.contains(selected) {
            eligible.formUnion(window(around: selected, ordered: ordered, neighborCount: neighborCount))
        } else if let first = ordered.first {
            eligible.formUnion(window(around: first, ordered: ordered, neighborCount: neighborCount))
        }

        return eligible.intersection(ordered)
    }

    private static func window(
        around selected: DiffReviewFileID,
        ordered: [DiffReviewFileID],
        neighborCount: Int
    ) -> Set<DiffReviewFileID> {
        guard let selectedIndex = ordered.firstIndex(of: selected) else { return [] }

        let clampedNeighborCount = max(0, neighborCount)
        let lowerBound = max(ordered.startIndex, selectedIndex - clampedNeighborCount)
        let upperBound = min(ordered.index(before: ordered.endIndex), selectedIndex + clampedNeighborCount)
        return Set(ordered[lowerBound...upperBound])
    }
}
