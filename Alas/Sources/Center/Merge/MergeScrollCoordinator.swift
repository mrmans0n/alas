import Foundation
import Observation

/// Single source of truth for synchronized scrolling across the three
/// merge panes. Holds the exact pixel Y offset so trackpad scrolling
/// remains smooth; row indexes are derived only for navigation.
@MainActor
@Observable
final class MergeScrollCoordinator {
    enum Source: Equatable {
        case local, result, remote
    }

    /// Per-pane line height. All three panes use the same monospaced
    /// font at the same size, so a single number is enough. Set by the
    /// view once the font is known; defaults to 16pt.
    var rowHeight: CGFloat = 16
    var contentTopInset: CGFloat = 6

    private(set) var scrollY: CGFloat = 0
    private(set) var logicalRow: Int = 0

    /// Per-target scroll handlers. Each pane (LOCAL, RESULT, REMOTE)
    /// registers its own handler so the three subscribers don't stomp
    /// each other — a single-slot closure would have meant whichever
    /// pane registered last wins. `applyPaneY` dispatches to the
    /// handler for every target OTHER than the source of the scroll.
    var onSyncLocal: ((CGFloat) -> Void)?
    var onSyncResult: ((CGFloat) -> Void)?
    var onSyncRemote: ((CGFloat) -> Void)?

    /// Programmatic setter. Doesn't broadcast — the caller is
    /// presumed to be initialization or a non-scroll trigger.
    func setLogicalRow(_ row: Int) {
        logicalRow = max(0, row)
        scrollY = CGFloat(logicalRow) * rowHeight
    }

    /// Returns the Y offset (points) corresponding to the current
    /// logical row, suitable for an `NSClipView.scroll(to:)` call.
    func paneY() -> CGFloat {
        scrollY
    }

    /// Called by a pane's scroll observer when the user scrolls it.
    /// Updates `logicalRow` and broadcasts to the OTHER two panes via
    /// `onSync`. The source pane is excluded from the broadcast so it
    /// doesn't bounce its own value back.
    func applyPaneY(_ y: CGFloat, source: Source) {
        // floor() rather than rounded(): rounded() causes mid-row hysteresis
        // during slow trackpad scrolls (the value flickers between row N and
        // N+1 when y is near (N + 0.5) * rowHeight). floor matches the
        // conventional "the row at top of viewport is the logical row"
        // invariant.
        let nextY = max(0, y)
        guard abs(nextY - scrollY) > 0.5 else { return }
        scrollY = nextY
        let row = max(0, Int((nextY / max(rowHeight, 1)).rounded(.down)))
        logicalRow = row
        for target in [Source.local, .result, .remote] where target != source {
            switch target {
            case .local:  onSyncLocal?(nextY)
            case .result: onSyncResult?(nextY)
            case .remote: onSyncRemote?(nextY)
            }
        }
    }
}
