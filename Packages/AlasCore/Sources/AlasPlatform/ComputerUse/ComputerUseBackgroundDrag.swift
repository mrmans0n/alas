import CoreGraphics
import Foundation

/// Pure decisions for a drag that stays inside the app in the background, and falls back to the
/// foreground drag once a native drag-and-drop session starts.
public enum ComputerUseBackgroundDrag {
    public enum Route: Sendable, Equatable {
        case background
        case foreground
    }

    /// Interpolated pointer moves in a drag, and the pause between them.
    public static let steps = 12
    public static let stepDelay = Duration.milliseconds(16)
    /// How often the window list is read while waiting for a drop to land.
    public static let sessionPoll = Duration.milliseconds(50)
    /// How long after a cross-window drop the start window is still read with the drag image
    /// gone: a moved item's source window refreshes a moment after the drop.
    public static let sourceSettle = Duration.milliseconds(500)

    /// A drag goes in the background only between two on-screen points of one window, and not
    /// when the caller asked for the direct (foreground) drag. The front takes the drags the
    /// background can't finish: one into another window (a drop there needs the system's drag and
    /// drop), one that starts on a list or table item (`startsInItem`: a file-style item drag,
    /// which Finder runs without a drag-layer window the fallback could see), and any drag in a
    /// Chromium or Electron app, which reads the pressed button from the hardware, so a posted
    /// drag reaches the page as a press and one move.
    public static func route(
        startOnScreen: Bool, endOnScreen: Bool, crossWindow: Bool, startsInItem: Bool, chromium: Bool, direct: Bool
    ) -> Route {
        let background = !direct && startOnScreen && endOnScreen && !crossWindow && !startsInItem && !chromium
        return background ? .background : .foreground
    }

    /// An element of the agent's latest read of the window, as `startsInItem` weighs it.
    public struct ReadElement: Sendable, Equatable {
        /// Global points.
        public var frame: CGRect
        /// Nesting depth in the window's tree.
        public var depth: Int
        /// It is an `AXRow`, or inside one.
        public var inRow: Bool

        public init(frame: CGRect, depth: Int, inRow: Bool) {
            self.frame = frame
            self.depth = depth
            self.inRow = inRow
        }
    }

    /// Whether a drag starting at `point` starts on a list or table item: the deepest elements of
    /// the latest read that contain the point include a row or something inside one. Rows share
    /// their depth with the table's columns, whose frames span every row, so any of the deepest
    /// counts. Nothing read there (no read, or none containing the point) is no item.
    public static func startsInItem(at point: CGPoint, elements: [ReadElement]) -> Bool {
        let containing = elements.filter { $0.frame.contains(point) }
        guard let deepest = containing.map(\.depth).max() else { return false }
        return containing.contains { $0.depth == deepest && $0.inRow }
    }

    /// Whether a native drag session began: the source app shows a window at the dragging layer or
    /// above (the drag image) that wasn't there before the drag.
    public static func startedSession(
        before: Set<UInt32>, now: [ComputerUseInputGeometry.ScreenWindow], sourcePID: Int32
    ) -> Bool {
        now.contains { window in
            window.pid == sourcePID && window.layer >= ComputerUseInputGeometry.draggingLayer && !before.contains(window.id)
        }
    }

    /// Whether the source app shows a drag-layer window now.
    public static func sessionActive(_ windows: [ComputerUseInputGeometry.ScreenWindow], sourcePID: Int32) -> Bool {
        windows.contains { $0.pid == sourcePID && $0.layer >= ComputerUseInputGeometry.draggingLayer }
    }

    /// Whether to keep waiting for a drop to land. Stops at the deadline; once the drop shows and
    /// the start window changed or isn't involved; and once it shows with no drag session active
    /// past `sourceSettle` (a copy drag leaves the start window as it was, while a move's source
    /// refreshes within the settle).
    public static func keepsPolling(
        dropped: Bool, startChanged: Bool, crossWindow: Bool, sessionActive: Bool,
        waited: Duration, deadline: Duration
    ) -> Bool {
        guard waited < deadline else { return false }
        guard dropped else { return true }
        return !startChanged && crossWindow && (sessionActive || waited < sourceSettle)
    }
}
