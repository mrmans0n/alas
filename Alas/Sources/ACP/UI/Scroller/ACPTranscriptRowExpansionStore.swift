import Foundation

/// Which tool-call and thought rows the user has expanded, by stable id.
/// Owned by the transcript scroller's Coordinator so the state outlives any
/// one mounted view: a native row hands the click here and comes back as the
/// expanded SwiftUI card, and a SwiftUI card reports its own toggles so that
/// collapsing it returns the row to native drawing.
@MainActor
final class ACPTranscriptRowExpansionStore {
    private(set) var expanded: Set<String> = []

    /// Fired after a change, so the Coordinator rebuilds its specs, as
    /// `ACPToolCallGroupExpansionSeeds.onChange` does.
    var onChange: (() -> Void)?

    func setExpanded(_ value: Bool, stableID: String) {
        let changed = value ? expanded.insert(stableID).inserted : expanded.remove(stableID) != nil
        if changed { onChange?() }
    }
}
