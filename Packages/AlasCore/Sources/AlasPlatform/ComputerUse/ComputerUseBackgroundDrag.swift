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

    /// A drag goes in the background only between two on-screen points, and not when the caller
    /// asked for the direct (foreground) drag.
    public static func route(startOnScreen: Bool, endOnScreen: Bool, direct: Bool) -> Route {
        !direct && startOnScreen && endOnScreen ? .background : .foreground
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
    /// (a copy drag leaves the start window as it was).
    public static func keepsPolling(
        dropped: Bool, startChanged: Bool, crossWindow: Bool, sessionActive: Bool,
        waited: Duration, deadline: Duration
    ) -> Bool {
        guard waited < deadline else { return false }
        guard dropped else { return true }
        return !startChanged && crossWindow && sessionActive
    }
}
