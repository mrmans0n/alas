import Foundation

/// One row in the follow-a-stack-entry picker.
struct GGFollowEntryCandidate: Equatable, Identifiable, Sendable {
    let position: Int
    let title: String
    let sha: String
    let ggID: String?
    let prNumber: Int?
    let prState: GGPRState?
    let ciStatus: GGCIStatus?

    var id: String { ggID ?? sha }

    /// Only a commit carrying a `GG-ID` trailer has an identity stable enough
    /// to follow. Commits without one are shown so the stack reads correctly,
    /// but cannot be picked.
    var isSelectable: Bool { ggID != nil }

    init(entry: GGStackEntry) {
        position = entry.position
        title = entry.title
        sha = entry.sha
        ggID = entry.ggId
        prNumber = entry.prNumber
        prState = entry.prState
        ciStatus = entry.ciStatus
    }
}

struct GGFollowEntryModel: Equatable, Sendable {
    var candidates: [GGFollowEntryCandidate]
    var selectedID: String?

    var selected: GGFollowEntryCandidate? {
        guard let selectedID else { return nil }
        return candidates.first { $0.id == selectedID }
    }

    var canFollow: Bool { selected?.isSelectable == true }

    /// Tip first, matching how commits are listed everywhere else in Alas.
    /// Preselection prefers the entry already followed, then the entry whose
    /// commit the tab is displaying, then the tip.
    static func make(
        entries: [GGStackEntry],
        currentGGID: String?,
        displayedSHA: String?
    ) -> GGFollowEntryModel {
        let candidates = entries
            .sorted { $0.position > $1.position }
            .map(GGFollowEntryCandidate.init(entry:))
        return GGFollowEntryModel(
            candidates: candidates,
            selectedID: preselection(
                candidates: candidates,
                currentGGID: currentGGID,
                displayedSHA: displayedSHA
            )
        )
    }

    private static func preselection(
        candidates: [GGFollowEntryCandidate],
        currentGGID: String?,
        displayedSHA: String?
    ) -> String? {
        if let currentGGID,
           let match = candidates.first(where: { $0.ggID == currentGGID }) {
            return match.id
        }
        if let displayedSHA, !displayedSHA.isEmpty,
           let match = candidates.first(where: {
               $0.isSelectable && ($0.sha.hasPrefix(displayedSHA) || displayedSHA.hasPrefix($0.sha))
           }) {
            return match.id
        }
        return candidates.first(where: \.isSelectable)?.id
    }
}

enum GGFollowEntryLoadState: Equatable, Sendable {
    case loading
    case loaded(GGFollowEntryModel)
    /// The branch is not a gg stack right now.
    case offStack
    case failed(String)
}
