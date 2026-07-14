import Foundation

/// Pure math for divider drags: anchor-at-drag-start width resolution and
/// pixel-grid alignment. Kept free of SwiftUI so it can be unit tested.
enum PaneDragMath {
    /// Width of a pane whose divider has moved `translation` points since
    /// drag start. Anchoring on the start width (instead of accumulating
    /// per-event deltas) keeps the divider tracking the cursor exactly,
    /// even after overshooting past a min/max bound and dragging back.
    /// Non-finite inputs are guarded the same way `ThreePaneSizing` guards
    /// its inputs: a non-finite translation is ignored, a non-finite start
    /// width falls back to `min`.
    static func resolvedWidth(
        startWidth: Double,
        translation: Double,
        min minValue: Double,
        max maxValue: Double
    ) -> Double {
        let base = startWidth.isFinite ? startWidth : minValue
        let offset = translation.isFinite ? translation : 0
        return min(maxValue, max(minValue, base + offset))
    }

    /// Round `value` to the display's backing pixel grid so panes never sit
    /// on fractional pixels (subpixel shimmer during drags). Returns the
    /// value unchanged when it or the scale is not a positive finite number.
    static func pixelAligned(_ value: Double, scale: Double) -> Double {
        guard value.isFinite, scale.isFinite, scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }
}
