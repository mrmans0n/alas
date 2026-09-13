import SwiftUI

/// Geometry for the right pane's "bands": section headers, sub-headers, and
/// the review drawer. Each band floats inside the content column with rounded
/// corners rather than running edge-to-edge, so no band stops short against
/// the icon rail — the rail needs neither a fill nor a divider to explain
/// where the content ends.
///
/// The pane toolbar is deliberately not a band: it reads as chrome, like the
/// center pane's toolbar, and stays flush.
enum PaneBandLayout {
    /// Gap between a band and the content column's side edges.
    static let outerHorizontal: CGFloat = 6
    /// Gap between a band and its neighbours.
    static let outerVertical: CGFloat = 2
    /// Gap between the outermost band and the pane's own edge.
    static let paneEdge: CGFloat = 6
    static let cornerRadius: CGFloat = 6

    /// Inner horizontal padding that keeps a band's content at the same x it
    /// would sit at edge-to-edge, so header text stays aligned with the plain
    /// rows beneath it. Clamped at 0 for insets narrower than the outer gap.
    static func innerHorizontal(_ edgeToEdgeInset: CGFloat) -> CGFloat {
        max(0, edgeToEdgeInset - outerHorizontal)
    }
}

/// Geometry for the pane's bottom drawer (review readiness, or the git-gud
/// stack). Collapsed, the drawer is a bare status row under a hairline with
/// no fill of its own, so it weighs nothing against the bands above it.
/// Expanded, it becomes a floating band like a section header, so the body
/// and its row read as one surface.
struct PaneDrawerLayout: Equatable {
    let expanded: Bool

    var outerHorizontal: CGFloat { expanded ? PaneBandLayout.outerHorizontal : 0 }
    var cornerRadius: CGFloat { expanded ? PaneBandLayout.cornerRadius : 0 }
    var top: CGFloat { expanded ? PaneBandLayout.outerVertical : 0 }
    var bottom: CGFloat { expanded ? PaneBandLayout.paneEdge : PaneBandLayout.outerVertical }
    /// The hairline stands in for the missing edge when there is no fill.
    var showsHairline: Bool { !expanded }

    /// Same contract as `PaneBandLayout.innerHorizontal`: content stays at
    /// the same x whether or not the drawer is currently a card.
    func innerHorizontal(_ edgeToEdgeInset: CGFloat) -> CGFloat {
        max(0, edgeToEdgeInset - outerHorizontal)
    }

    /// The single curve every part of the toggle shares — container height,
    /// card fill, corner radius, chevron, and the body's transition — so
    /// they read as one gesture. A little bounce makes the drawer feel like
    /// it has weight; Reduce Motion drops the animation entirely.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.22)
    }

    /// Chevron angle for a "chev-right" glyph: rotated a quarter turn to
    /// point down when open, so the glyph turns instead of being swapped.
    var chevronAngle: Angle {
        .degrees(expanded ? 90 : 0)
    }
}

extension AnyTransition {
    /// The drawer body slides out from beneath its row while fading in. The
    /// drawer clips to its card shape, so the slide reads as an unfurl
    /// rather than the body arriving from outside.
    static let paneDrawerBody: AnyTransition = .move(edge: .top).combined(with: .opacity)
}

extension View {
    /// Pads and fills a header-style band. `horizontal` is the content inset
    /// measured from the column edge, which the band preserves by giving back
    /// whatever the outer gap takes.
    func paneBand(fill: Color, horizontal: CGFloat = 12, vertical: CGFloat = 7) -> some View {
        self
            .padding(.horizontal, PaneBandLayout.innerHorizontal(horizontal))
            .padding(.vertical, vertical)
            .background(fill, in: RoundedRectangle(cornerRadius: PaneBandLayout.cornerRadius))
            .padding(.horizontal, PaneBandLayout.outerHorizontal)
            .padding(.vertical, PaneBandLayout.outerVertical)
    }

    /// Chrome for a bottom drawer whose row and body are already padded with
    /// `layout.innerHorizontal`. Draws the card when expanded and the hairline
    /// when collapsed, and positions the result against the pane edge.
    func paneDrawer(_ layout: PaneDrawerLayout, fill: Color, hairline: Color) -> some View {
        self
            // Clip to the card so a body mid-transition is revealed by the
            // growing container instead of spilling past it.
            .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius))
            // The card and the hairline are always present and fade rather
            // than being inserted, so the toggle animates them instead of
            // popping them in.
            .background {
                RoundedRectangle(cornerRadius: layout.cornerRadius)
                    .fill(fill)
                    .opacity(layout.expanded ? 1 : 0)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(hairline)
                    .frame(height: 1)
                    .opacity(layout.showsHairline ? 1 : 0)
            }
            .padding(.horizontal, layout.outerHorizontal)
            .padding(.top, layout.top)
            .padding(.bottom, layout.bottom)
    }
}
