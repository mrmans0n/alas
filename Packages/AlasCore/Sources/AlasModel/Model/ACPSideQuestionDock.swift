import CoreGraphics
import Foundation

/// Where the `/btw` card sits in the chat surface.
public enum ACPSideQuestionDock: String, Codable, CaseIterable, Sendable {
    /// Above the composer, as the card first shipped.
    case composer
    /// Pinned to the top of the chat surface.
    case top
    /// A column beside the chat; the chat narrows to make room.
    case side
}

/// Sizing and drop-zone math for the `/btw` card, in the chat surface's
/// coordinates (origin top-left, y down).
public enum ACPSideQuestionDockLayout {
    public static let minHeight: CGFloat = 120
    public static let maxHeightFraction: CGFloat = 0.7
    public static let minSideWidth: CGFloat = 300
    public static let maxSideWidthFraction: CGFloat = 0.5
    public static let defaultHeight: CGFloat = 260
    public static let defaultSideWidth: CGFloat = 380
    /// The answer keeps at least this much room above a pinned prompt.
    public static let minAnswerHeight: CGFloat = 60

    private static let topBand: CGFloat = 0.25
    private static let sideBand: CGFloat = 0.3
    private static let composerBand: CGFloat = 0.3

    /// The drop zone for `dock`. Zones don't overlap; the rest of the surface
    /// is no zone, so a drop there keeps the current dock.
    public static func zone(for dock: ACPSideQuestionDock, in surface: CGSize) -> CGRect {
        let w = surface.width, h = surface.height
        switch dock {
        case .top:
            return CGRect(x: 0, y: 0, width: w, height: h * topBand)
        case .side:
            return CGRect(x: w * (1 - sideBand), y: h * topBand, width: w * sideBand, height: h * (1 - topBand))
        case .composer:
            return CGRect(x: 0, y: h * (1 - composerBand), width: w * (1 - sideBand), height: h * composerBand)
        }
    }

    public static func dock(at point: CGPoint, in surface: CGSize) -> ACPSideQuestionDock? {
        guard surface.width > 0, surface.height > 0 else { return nil }
        return ACPSideQuestionDock.allCases.first { zone(for: $0, in: surface).contains(point) }
    }

    public static func maxHeight(surfaceHeight: CGFloat) -> CGFloat {
        max(minHeight, surfaceHeight * maxHeightFraction)
    }

    public static func clampedHeight(_ height: CGFloat, surfaceHeight: CGFloat) -> CGFloat {
        min(max(height, minHeight), maxHeight(surfaceHeight: surfaceHeight))
    }

    public static func clampedSideWidth(_ width: CGFloat, surfaceWidth: CGFloat) -> CGFloat {
        min(max(width, minSideWidth), max(minSideWidth, surfaceWidth * maxSideWidthFraction))
    }

    /// Upper bounds for the card's scrolling answer and its pinned prompt.
    public struct BodyHeights: Equatable, Sendable {
        public let answer: CGFloat
        public let prompt: CGFloat

        public init(answer: CGFloat, prompt: CGFloat) {
            self.answer = answer
            self.prompt = prompt
        }
    }

    /// `cap` is the card height the user chose; `limit` is the most the card
    /// may grow to while the agent waits on the user; `chrome` is the header
    /// and footer. A pending prompt first grows the card past `cap`; at
    /// `limit` the answer gives way down to `minAnswerHeight`, and past that
    /// the prompt scrolls.
    public static func bodyHeights(cap: CGFloat, limit: CGFloat, chrome: CGFloat, promptIdeal: CGFloat) -> BodyHeights {
        let preferredAnswer = max(minAnswerHeight, cap - chrome)
        guard promptIdeal > 0 else { return BodyHeights(answer: preferredAnswer, prompt: 0) }
        let room = max(0, limit - chrome)
        let prompt = min(promptIdeal, max(0, room - minAnswerHeight))
        let answer = max(minAnswerHeight, min(preferredAnswer, room - prompt))
        return BodyHeights(answer: answer, prompt: prompt)
    }
}
