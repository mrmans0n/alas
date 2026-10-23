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

    /// The id of the frontmost window containing `point`; `windows` run front to back.
    public static func topmostWindow(at point: CGPoint, in windows: [(id: UInt32, frame: CGRect)]) -> UInt32? {
        windows.first { $0.frame.contains(point) }?.id
    }

    public static func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    public enum DragPoint: Sendable, Equatable { case start, end }

    /// Which of a drag's points another window covers, start first; nil when the start window is
    /// topmost at the start and the drop window at the end. `windows` run front to back.
    public static func coveredDragPoint(
        start: CGPoint, in startWindow: UInt32, end: CGPoint, in endWindow: UInt32,
        windows: [(id: UInt32, frame: CGRect)]
    ) -> DragPoint? {
        if topmostWindow(at: start, in: windows) != startWindow { return .start }
        if topmostWindow(at: end, in: windows) != endWindow { return .end }
        return nil
    }

    /// Whether a window's frame moved or resized by more than `tolerance` points: a drag that
    /// grabbed the window itself rather than an item in it.
    public static func windowMoved(from before: CGRect, to after: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(before.minX - after.minX) > tolerance || abs(before.minY - after.minY) > tolerance
            || abs(before.width - after.width) > tolerance || abs(before.height - after.height) > tolerance
    }

    /// The centre of the part of `frame` inside every clip (a scroll area, the window); nil when
    /// `frame`'s own centre is outside one, so the element is scrolled or moved out of view.
    public static func visibleCenter(of frame: CGRect, clippedTo clips: [CGRect]) -> CGPoint? {
        let own = center(of: frame)
        guard clips.allSatisfy({ $0.contains(own) }) else { return nil }
        return center(of: clips.reduce(frame) { $0.intersection($1) })
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
