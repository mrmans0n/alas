import SwiftUI

/// Motion for collapsing and expanding the window's side panes.
///
/// The pane's frame shrinks toward its window edge at full speed while its
/// content lags behind and fades, so the divider visibly overtakes what it
/// hides: the pane reads as sinking under the window edge (or under the
/// right rail) rather than being wiped away. The layout animates the frame;
/// this type supplies the curve and the content transition.
enum PaneCollapseMotion {
    /// How far the content travels, as a fraction of the pane width, while
    /// the pane edge travels the full width. Below one so the content lags.
    static let parallaxFraction: Double = 0.45

    /// The fade finishes ahead of the slide so the content is gone before the
    /// pane edge arrives and nothing pops at the end.
    static let fadeDuration: Double = 0.22

    /// The same curve the pane drawers use, so every collapse in the window
    /// shares one feel. Reduce Motion drops the animation entirely, which
    /// leaves the long-standing instant toggle.
    static func animation(reduceMotion: Bool) -> Animation? {
        PaneDrawerLayout.animation(reduceMotion: reduceMotion)
    }

    /// Horizontal offset the content sits at when fully collapsed toward
    /// `edge`, given the pane's expanded `width`.
    static func parallaxOffset(edge: HorizontalEdge, width: Double) -> Double {
        let distance = width * parallaxFraction
        switch edge {
        case .leading: return -distance
        case .trailing: return distance
        }
    }

    /// Transition for a pane's content while the pane collapses toward `edge`.
    /// Under Reduce Motion the content appears and disappears in place.
    static func transition(edge: HorizontalEdge, width: Double, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .offset(x: CGFloat(parallaxOffset(edge: edge, width: width)))
            .combined(with: .opacity.animation(.easeOut(duration: fadeDuration)))
    }
}
