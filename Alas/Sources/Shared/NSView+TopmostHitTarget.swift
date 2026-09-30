import AppKit

extension NSView {
    /// Whether this view (or one of its subviews) is what the window would
    /// hit-test at `locationInWindow`.
    ///
    /// Tracking areas keep delivering `mouseMoved` to their owner even when a
    /// sibling drawn on top — e.g. a SwiftUI overlay in the same hosting view —
    /// covers it, so hover-driven views must check this before reacting.
    /// A view outside any window is treated as topmost.
    func isTopmostHitTarget(atWindowLocation locationInWindow: NSPoint) -> Bool {
        guard let contentView = window?.contentView else { return true }
        let point = contentView.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
        guard let hit = contentView.hitTest(point) else { return false }
        return hit.isDescendant(of: self)
    }
}
