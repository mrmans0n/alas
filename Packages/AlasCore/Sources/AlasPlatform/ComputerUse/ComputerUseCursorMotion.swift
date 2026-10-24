import CoreGraphics
import Foundation

/// Timing and path math for the drawn agent cursor.
public enum ComputerUseCursorMotion {
    public static let jumpDuration = Duration.milliseconds(120)
    public static let rippleDuration = Duration.milliseconds(350)
    public static let outlineDuration = Duration.milliseconds(600)
    /// A fallback: the cursor stays up for the whole agent turn, whose end dismisses it.
    public static let idleFadeDelay = Duration.seconds(30)
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

    /// Where a glide in `window` starts, window-local: where the pointer last was in it, kept
    /// inside a window that shrank since, or the window's centre when it has never been there.
    public static func startPoint(
        in window: ComputerUseCursorWindowKey, size: CGSize, last: [ComputerUseCursorWindowKey: CGPoint]
    ) -> CGPoint {
        guard let point = last[window] else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        return CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }

    /// Converts a CG frame (top-left origin on the primary display) to AppKit's bottom-left one.
    public static func appKitFrame(fromCG frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// A window the cursor was in: a window id is only unique within its app's lifetime.
public struct ComputerUseCursorWindowKey: Hashable, Sendable {
    public var pid: Int32
    public var windowID: UInt32

    public init(pid: Int32, windowID: UInt32) {
        self.pid = pid
        self.windowID = windowID
    }
}

public enum ComputerUseCursorInputKind: Sendable { case click, scroll, type, key, drag }

public enum ComputerUseCursorCue: Equatable, Sendable {
    /// `outline`: the element the glide goes to, when it went by ref.
    case glide(to: CGPoint, outline: CGRect?, click: Bool)
    case jump(to: CGPoint, outline: CGRect?, click: Bool)
    case outline(CGRect)
    case hide
    case none

    /// An element is glided to the centre of its part inside `window`, when given; one wholly
    /// outside it gets no cue, so the pointer never leaves the panel.
    public static func cue(
        for kind: ComputerUseCursorInputKind, point: CGPoint?, elementFrame: CGRect?, window: CGRect? = nil
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
            if let point { return .glide(to: point, outline: nil, click: click) }
            if let frame = elementFrame {
                guard let window else {
                    return .glide(to: ComputerUseInputGeometry.center(of: frame), outline: frame, click: click)
                }
                guard let visible = ComputerUseInputGeometry.visibleCenter(
                    of: frame, clippedTo: [window], requireOwnCenter: false)
                else { return ComputerUseCursorCue.none }
                return .glide(to: visible, outline: frame, click: click)
            }
            return ComputerUseCursorCue.none
        }
    }
}
