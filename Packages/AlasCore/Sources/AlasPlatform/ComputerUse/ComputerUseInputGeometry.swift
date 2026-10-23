import CoreGraphics
import Foundation

/// Pure geometry for synthesized pointer input.
public enum ComputerUseInputGeometry {
    /// Maps a screenshot pixel to a global point using the frame and scale the screenshot was
    /// taken with. nil when the result falls outside `currentFrame`, because the window moved
    /// or resized since the screenshot.
    public static func globalPoint(
        pixel: CGPoint, screenshotFrame: CGRect, scale: CGFloat, currentFrame: CGRect
    ) -> CGPoint? {
        guard scale > 0 else { return nil }
        let point = CGPoint(
            x: screenshotFrame.minX + pixel.x / scale,
            y: screenshotFrame.minY + pixel.y / scale
        )
        return currentFrame.contains(point) ? point : nil
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

    /// The id of the window a system-wide press or drop at `point` lands in: the frontmost one
    /// over it that shows, at any layer. Above the normal layer, `appPID`'s own windows don't
    /// count (the drag image of its drag follows the cursor). `windows` run front to back.
    public static func topmostWindow(at point: CGPoint, in windows: [ScreenWindow], appPID: Int32? = nil) -> UInt32? {
        windows.first { window in
            guard window.frame.contains(point), window.alpha > 0 else { return false }
            return window.layer == 0 || window.pid != appPID
        }?.id
    }

    public static func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    public enum DragPoint: Sendable, Equatable { case start, end }

    /// Which of a drag's points another window covers, start first; nil when the start window is
    /// topmost at the start and the drop window at the end, as `topmostWindow` hit-tests for the
    /// dragging app `appPID`. `windows` run front to back.
    public static func coveredDragPoint(
        start: CGPoint, in startWindow: UInt32, end: CGPoint, in endWindow: UInt32,
        windows: [ScreenWindow], appPID: Int32
    ) -> DragPoint? {
        if topmostWindow(at: start, in: windows, appPID: appPID) != startWindow { return .start }
        if topmostWindow(at: end, in: windows, appPID: appPID) != endWindow { return .end }
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
