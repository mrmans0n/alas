import Foundation

/// Non-gg counterpart of the stack-entry chip: a branch has at most one
/// PR/MR, so the Commits header shows a single chip for it, styled and
/// colored exactly like the per-commit chip a gg stack gets.
extension GGStackChipModel {
    static func model(for request: ReviewRequest) -> GGStackChipModel {
        let kind = request.provider
        let reference = "\(kind.reviewRequestNumberPrefix)\(request.number)"
        let label = reference + (request.reviewDecision == .approved ? " ✓" : "")
        let token: String
        switch request.state {
        case .open: token = request.isDraft ? "fg-muted" : "add"
        case .merged: token = "accent"
        case .closed: token = "del"
        }
        return GGStackChipModel(
            label: label,
            colorToken: token,
            helpLabel: "Open \(kind.reviewRequestLabel) \(reference)"
        )
    }
}

extension GGCIStatus {
    /// Collapses a review request's checks into the single state `GGCIDot`
    /// renders. `nil` when there are no checks, so no dot is drawn.
    static func rollup(of request: ReviewRequest) -> GGCIStatus? {
        guard let bucket = request.worstCheckBucket else { return nil }
        switch bucket {
        case .pass, .skipping: return .success
        case .fail: return .failed
        case .pending: return .pending
        case .cancel: return .canceled
        case .unknown: return .unknown
        }
    }
}
