import Foundation

/// Geometry for placing two NSImages of potentially differing dimensions
/// onto a shared "union" canvas, top-left aligned, then fitting the union
/// into a viewport at a common scale. Used by overlay and swipe modes.
///
/// The two images are rendered at their natural pixel sizes (scaled by a
/// single factor), so a size change between revisions is visible. The
/// union canvas (= `max(W) × max(H)`) is then centered in the viewport.
///
/// All sizes are in points / display units, not pixels.
struct UnionCanvasGeometry: Equatable {
    let beforeSize: CGSize
    let afterSize: CGSize
    let viewport: CGSize

    init(before: CGSize, after: CGSize, viewport: CGSize) {
        self.beforeSize = before
        self.afterSize = after
        self.viewport = viewport
    }

    var unionSize: CGSize {
        CGSize(
            width: max(beforeSize.width, afterSize.width),
            height: max(beforeSize.height, afterSize.height)
        )
    }

    /// The common scale that fits the union canvas inside the viewport,
    /// preserving aspect ratio. Returns 1.0 when the union or viewport is
    /// degenerate so callers don't divide by zero downstream.
    var scale: CGFloat {
        let u = unionSize
        guard u.width > 0, u.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return 1.0 }
        return min(viewport.width / u.width, viewport.height / u.height)
    }

    var scaledUnionSize: CGSize {
        let u = unionSize
        return CGSize(width: u.width * scale, height: u.height * scale)
    }

    /// Top-left position of the union canvas inside the viewport so the
    /// canvas is centered.
    var origin: CGPoint {
        let s = scaledUnionSize
        return CGPoint(
            x: (viewport.width - s.width) / 2,
            y: (viewport.height - s.height) / 2
        )
    }
}
