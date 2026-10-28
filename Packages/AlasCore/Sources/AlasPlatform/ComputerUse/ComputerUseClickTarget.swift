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

    /// How far up from the element under the point the clicked element may be, for the point to
    /// count as on it: the hit is the element or one of its descendants (a button's label).
    public static let hitDescendantLevels = 8
    /// How far up from the clicked element the element under the point may be: a near ancestor
    /// still holds it (a 1×1 visually hidden control under its label's wrapper).
    public static let hitAncestorLevels = 2

    /// Whether the app's own hit test at the click's point found the clicked element there: the
    /// element itself or a descendant (`targetAboveHit`, the element's level above the hit, 0 for
    /// the hit itself), or a near ancestor (`hitAboveTarget`, the hit's level above the element).
    /// Anything else there (an overlay, a sticky header) would take the click instead.
    public static func hitReaches(targetAboveHit: Int?, hitAboveTarget: Int?) -> Bool {
        if let targetAboveHit, targetAboveHit <= hitDescendantLevels { return true }
        if let hitAboveTarget, hitAboveTarget <= hitAncestorLevels { return true }
        return false
    }

    /// Whether a click by ref may go as a pointer click at the element's visible centre instead of
    /// an AX press, which doesn't reach a Chrome page's content: a left single click (`leftSingle`)
    /// on an element in a web page (`inWebArea`) of a Chromium browser (`chromeBrowser`,
    /// `ComputerUseWebContent.chromeBundleIDs`; an Electron app's AX press works, with the pointer
    /// retry after it), while that centre is on screen (`centerOnScreen`) and the app's own hit
    /// test finds the element there (`hitOnElement`, `hitReaches`). Toggles and menu items too:
    /// no press went before it, so nothing is pressed twice.
    public static func pointerCandidate(
        leftSingle: Bool, inWebArea: Bool, chromeBrowser: Bool, centerOnScreen: Bool, hitOnElement: Bool
    ) -> Bool {
        leftSingle && inWebArea && chromeBrowser && centerOnScreen && hitOnElement
    }

    /// Whether a `pointerCandidate` click goes with the pointer once the route is known: only in
    /// the background (`route`), with the window made key without activating the app. Anywhere
    /// else it gets the AX press, as any click would, rather than an activation or a refusal.
    public static func pointerFirst(candidate: Bool, route: ComputerUseEventRoute) -> Bool {
        candidate && route == .background
    }
}
