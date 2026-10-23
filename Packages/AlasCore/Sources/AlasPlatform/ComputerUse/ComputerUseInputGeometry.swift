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
