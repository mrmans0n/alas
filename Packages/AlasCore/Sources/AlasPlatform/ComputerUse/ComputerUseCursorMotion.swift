import CoreGraphics
import Foundation

/// Timing and path math for the drawn agent cursor.
public enum ComputerUseCursorMotion {
    public static let jumpDuration = Duration.milliseconds(120)
    public static let rippleDuration = Duration.milliseconds(350)
    public static let outlineDuration = Duration.milliseconds(600)
    public static let idleFadeDelay = Duration.seconds(3)
    public static let fadeDuration = Duration.milliseconds(300)

    /// 300 ms for a short hop, growing linearly to 400 ms at 1500 points and beyond.
    public static func glideDuration(from: CGPoint, to: CGPoint) -> Duration {
        let distance = hypot(to.x - from.x, to.y - from.y)
        let extra = min(Double(distance) / 1500, 1) * 100
        return .milliseconds(Int((300 + extra).rounded()))
    }

    /// Cubic ease-in-out; `t` is clamped to 0...1.
    public static func eased(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    public static func position(from: CGPoint, to: CGPoint, progress t: Double) -> CGPoint {
        let e = CGFloat(eased(t))
        return CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
    }

    /// Converts a CG frame (top-left origin on the primary display) to AppKit's bottom-left one.
    public static func appKitFrame(fromCG frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

public enum ComputerUseCursorInputKind: Sendable { case click, scroll, type, key, drag }

public enum ComputerUseCursorCue: Equatable, Sendable {
    case glide(to: CGPoint, click: Bool)
    case jump(to: CGPoint, outline: CGRect?, click: Bool)
    case outline(CGRect)
    case hide
    case none

    public static func cue(
        for kind: ComputerUseCursorInputKind, point: CGPoint?, elementFrame: CGRect?
    ) -> ComputerUseCursorCue {
        switch kind {
        case .drag:
            return .hide
        case .key:
            return ComputerUseCursorCue.none
        case .type:
            return elementFrame.map { .outline($0) } ?? ComputerUseCursorCue.none
        case .click, .scroll:
            let click = kind == .click
            if let point { return .glide(to: point, click: click) }
            if let frame = elementFrame {
                return .jump(to: ComputerUseInputGeometry.center(of: frame), outline: frame, click: click)
            }
            return ComputerUseCursorCue.none
        }
    }
}
