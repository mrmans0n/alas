import Foundation

/// Which element takes a left click on an element without AXPress.
public enum ComputerUseClickTarget {
    public enum Choice: Equatable, Sendable {
        /// Press the element at this chain index.
        case press(Int)
        /// Select the row at this chain index.
        case selectRow(Int)
        /// Nothing in reach; the click goes as events.
        case none
    }

    /// Containers a click never climbs into: pressing one is not a click on the element.
    public static let stopRoles: Set<String> = [
        "AXRow", "AXOutline", "AXTable", "AXList", "AXBrowser", "AXScrollArea", "AXToolbar", "AXTabGroup",
        "AXSplitGroup", "AXWebArea", "AXPopover", "AXDrawer", "AXWindow", "AXSheet", "AXApplication",
    ]
    /// Elements that may be pressed, counting the element itself.
    public static let maxLevels = 4

    /// `chain` is the element, then its parent, and so on. Presses the nearest element with
    /// AXPress below the first stop role and within `maxLevels`; else selects the row when
    /// the stop is one.
    public static func choose(chain: [(role: String, actions: [String])]) -> Choice {
        let stop = chain.firstIndex { stopRoles.contains($0.role) }
        let candidates = chain.indices.prefix(min(stop ?? chain.count, maxLevels))
        if let press = candidates.first(where: { chain[$0].actions.contains("AXPress") }) {
            return .press(press)
        }
        if let stop, chain[stop].role == "AXRow" { return .selectRow(stop) }
        return .none
    }
}
