import CoreGraphics
import Foundation

/// Pure geometry for synthesized pointer input.
public enum ComputerUseInputGeometry {
    /// Maps a screenshot pixel to a global point using the frame and scale the screenshot was
    /// taken with. nil when the window moved or resized since the screenshot (the pixel may now
    /// show something else, even inside the window), or when the point falls outside it.
    public static func globalPoint(
        pixel: CGPoint, screenshotFrame: CGRect, scale: CGFloat, currentFrame: CGRect
    ) -> CGPoint? {
        guard scale > 0, !screenshotStale(screenshotFrame: screenshotFrame, currentFrame: currentFrame) else { return nil }
        let point = CGPoint(
            x: screenshotFrame.minX + pixel.x / scale,
            y: screenshotFrame.minY + pixel.y / scale
        )
        return currentFrame.contains(point) ? point : nil
    }

    /// The element under a point, and the process it belongs to.
    public struct PointHit: Sendable, Equatable {
        public var pid: Int32
        /// Global points; nil when it couldn't be read.
        public var frame: CGRect?

        public init(pid: Int32, frame: CGRect?) {
            self.pid = pid
            self.frame = frame
        }
    }

    public enum PointRoute: Sendable, Equatable {
        /// Events posted to the app, as for any point.
        case events
        /// Content another process draws in the window (a System Settings pane is an extension's):
        /// events posted to the app never reach it, so the input goes as AX on the element there.
        case ax
        /// What is at the point is another process's, outside the window: refused.
        case covered
    }

    /// How an x/y click or scroll at `point` reaches it, from the target app's own hit test
    /// (`appHit`), which sees its windows even under other apps'. There is no system-wide hit
    /// test: it names whatever is on top, Alas's own windows included.
    /// Another process's element counts as in the window when the point is in the window and the
    /// element's frame holds the point (a row half scrolled out still does); one whose frame
    /// can't be read counts as in it.
    public static func pointRoute(point: CGPoint, targetPID: Int32, window: CGRect, appHit: PointHit?) -> PointRoute {
        guard let appHit, appHit.pid != targetPID else { return .events }
        guard window.contains(point) else { return .covered }
        return appHit.frame.map { holds($0, point) } ?? true ? .ax : .covered
    }

    /// Whether an app's own hit test at `point` found an element there. It answers with its menu
    /// bar, or an element elsewhere, for a point it has nothing at (a window AeroSpace parked off
    /// screen): that counts as no hit, and the element is found from the window instead. One
    /// whose frame can't be read counts as a hit.
    public static func isRealHit(role: String?, frame: CGRect?, point: CGPoint) -> Bool {
        guard role != "AXMenuBar" else { return false }
        return frame.map { holds($0, point) } ?? true
    }

    /// Whether a CG window is the one backing a sheet: untitled, with the frame of an AXSheet in
    /// one of its app's windows (`frameTolerance`). The sheet is reached through its parent window,
    /// so the backing window isn't listed on its own: no AX window answers for it.
    public static func isSheetBacking(title: String?, frame: CGRect, sheetFrames: [CGRect]) -> Bool {
        guard title == nil else { return false }
        return sheetFrames.contains { sheet in
            abs(sheet.minX - frame.minX) <= frameTolerance && abs(sheet.minY - frame.minY) <= frameTolerance
                && abs(sheet.width - frame.width) <= frameTolerance && abs(sheet.height - frame.height) <= frameTolerance
        }
    }

    /// Whether `point` is on one of `displays` (CG global, top-left frames). A window AeroSpace
    /// parks on a hidden workspace sits off every display but a 1-point sliver: input posted at
    /// a point off screen reaches nothing.
    public static func pointIsOnScreen(_ point: CGPoint, displays: [CGRect]) -> Bool {
        displays.contains { $0.contains(point) }
    }

    public enum OffScreenInput: Sendable, Equatable {
        /// Posted as events, as for any window.
        case events
        /// Delivered through AX: a menu item with the key's shortcut, or text set in the element.
        case ax
        /// Posted keys reach no window off screen: refused rather than reported delivered.
        case refuse
    }

    /// How a key or typed text reaches a window, once no sheet or dialog button took it. An
    /// off-screen window (another Space, an AeroSpace workspace) only takes it through AX, and only
    /// while it is its app's focused window (`targetIsFocusedWindow`; always true for text typed by
    /// ref), so a menu item or the focused element can't belong to another of the app's windows.
    public static func offScreenInput(
        windowOnScreen: Bool, targetIsFocusedWindow: Bool, deliveredThroughAX: Bool
    ) -> OffScreenInput {
        if windowOnScreen { return .events }
        return targetIsFocusedWindow && deliveredThroughAX ? .ax : .refuse
    }

    /// Whether a window's frame is on screen: its centre is on a display, or at least
    /// `onScreenShare` of its area is. The 1-point sliver AeroSpace leaves of a parked window isn't.
    public static func frameIsOnScreen(_ frame: CGRect, displays: [CGRect]) -> Bool {
        if pointIsOnScreen(center(of: frame), displays: displays) { return true }
        let area = frame.width * frame.height
        guard area > 0 else { return false }
        let shown = displays.reduce(CGFloat(0)) { sum, display in
            let overlap = display.intersection(frame)
            return overlap.isNull ? sum : sum + overlap.width * overlap.height
        }
        return shown / area >= onScreenShare
    }

    public static let onScreenShare: CGFloat = 0.25

    /// Whether `frame` holds `point`, within `frameTolerance`.
    public static func holds(_ frame: CGRect, _ point: CGPoint) -> Bool {
        frame.insetBy(dx: -frameTolerance, dy: -frameTolerance).contains(point)
    }

    /// Points a frame may miss the point by and still count as holding it.
    static let frameTolerance: CGFloat = 2

    /// Whether the window's frame no longer is the one its screenshot was taken with.
    public static func screenshotStale(screenshotFrame: CGRect, currentFrame: CGRect) -> Bool {
        windowMoved(from: screenshotFrame, to: currentFrame, tolerance: 0.5)
    }

    /// An on-screen window as WindowServer hit-tests it, at any layer.
    public struct ScreenWindow: Sendable, Equatable {
        public var id: UInt32
        public var pid: Int32
        /// 0 for normal windows; floating panels, banners, the Dock and drag images sit above.
        public var layer: Int
        public var alpha: Double
        public var frame: CGRect

        public init(id: UInt32, pid: Int32 = 0, layer: Int = 0, alpha: Double = 1, frame: CGRect) {
            self.id = id
            self.pid = pid
            self.layer = layer
            self.alpha = alpha
            self.frame = frame
        }
    }

    /// `kCGMainMenuWindowLevel`: the menu bar, and above it status items, the Dock and pop-up menus.
    public static let menuBarLayer = 24

    /// Whether an app's window at `layer` is one it is driven in: normal windows, floating panels
    /// (3) and modal panels (8), such as an open panel. The menu bar and everything above it, and
    /// the desktop's negative layers, are not.
    public static func isAppWindowLayer(_ layer: Int) -> Bool {
        (0 ..< menuBarLayer).contains(layer)
    }

    /// `kCGDraggingWindowLevel`. From it up sit windows no press or drop lands in: drag images,
    /// the software cursor, display shields, the login window.
    public static let draggingLayer = 500

    /// The id of the window a system-wide press or drop at `point` lands in: the frontmost one
    /// over it that shows, below `draggingLayer`. `windows` run front to back; ids in `ignoring` (Alas's own overlay) are skipped.
    public static func topmostWindow(
        at point: CGPoint, in windows: [ScreenWindow], ignoring: Set<UInt32> = []
    ) -> UInt32? {
        windows.first { window in
            !ignoring.contains(window.id) && window.frame.contains(point) && window.alpha > 0 && window.layer < draggingLayer
        }?.id
    }

    public static func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    public enum DragPoint: Sendable, Equatable { case start, end }

    /// Which of a drag's points another window covers, start first; nil when the start window is
    /// topmost at the start and the drop window at the end, as `topmostWindow` hit-tests.
    /// `windows` run front to back.
    public static func coveredDragPoint(
        start: CGPoint, in startWindow: UInt32, end: CGPoint, in endWindow: UInt32,
        windows: [ScreenWindow], ignoring: Set<UInt32> = []
    ) -> DragPoint? {
        if topmostWindow(at: start, in: windows, ignoring: ignoring) != startWindow { return .start }
        if topmostWindow(at: end, in: windows, ignoring: ignoring) != endWindow { return .end }
        return nil
    }

    /// Whether a window's frame moved or resized by more than `tolerance` points: a drag that
    /// grabbed the window itself rather than an item in it.
    public static func windowMoved(from before: CGRect, to after: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(before.minX - after.minX) > tolerance || abs(before.minY - after.minY) > tolerance
            || abs(before.width - after.width) > tolerance || abs(before.height - after.height) > tolerance
    }

    /// The centre of the part of `frame` inside every clip (a scroll area, the window); nil when
    /// none of it shows, or with `requireOwnCenter` when `frame`'s own centre is outside a clip.
    public static func visibleCenter(
        of frame: CGRect, clippedTo clips: [CGRect], requireOwnCenter: Bool = true
    ) -> CGPoint? {
        let own = center(of: frame)
        if requireOwnCenter, !clips.allSatisfy({ $0.contains(own) }) { return nil }
        let visible = clips.reduce(frame) { $0.intersection($1) }
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return center(of: visible)
    }

    /// Whether any of `frame` shows inside every clip, as inspect reports `visible`: an element
    /// without a size counts as shown, since there is nothing to tell by.
    public static func isShown(_ frame: CGRect, clippedTo clips: [CGRect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return true }
        return visibleCenter(of: frame, clippedTo: clips, requireOwnCenter: false) != nil
    }

    /// `steps` evenly spaced points from `from` (excluded) to `to` (included).
    public static func interpolate(from: CGPoint, to: CGPoint, steps: Int) -> [CGPoint] {
        guard steps >= 1 else { return [to] }
        return (1 ... steps).map { step in
            guard step < steps else { return to }
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
    }
}
