import AppKit
import Observation

/// Single source of truth for synchronized scrolling across the three
/// merge panes. Holds a logical row index that all three panes derive
/// their actual scroll Y from. When one pane scrolls (user touched its
/// trackpad), it pushes the new Y; the coordinator converts to a
/// logical row and broadcasts the corresponding Y to the others. A
/// reentry counter prevents the broadcast from being re-interpreted as
/// a fresh scroll and causing a feedback loop.
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

    private(set) var logicalRow: Int = 0

    /// Called when the coordinator needs the other panes to scroll to
    /// match. The Source argument names the pane the new value is for
    /// — the SOURCE of the update is never broadcast back to itself.
    /// Set by `MergeView3Way` to wire up the actual `NSScrollView`
    /// adjustments.
    var onSync: ((Source, Int) -> Void)?

    /// Programmatic setter. Doesn't broadcast — the caller is
    /// presumed to be initialization or a non-scroll trigger.
    func setLogicalRow(_ row: Int) {
        logicalRow = max(0, row)
    }

    /// Returns the Y offset (points) corresponding to the current
    /// logical row, suitable for an `NSClipView.scroll(to:)` call.
    func paneY() -> CGFloat {
        CGFloat(logicalRow) * rowHeight
    }

    /// Called by a pane's scroll observer when the user scrolls it.
    /// Updates `logicalRow` and broadcasts to the OTHER two panes via
    /// `onSync`. The source pane is excluded from the broadcast so it
    /// doesn't bounce its own value back.
    func applyPaneY(_ y: CGFloat, source: Source) {
        let row = max(0, Int((y / max(rowHeight, 1)).rounded()))
        guard row != logicalRow else { return }
        logicalRow = row
        for target in [Source.local, .result, .remote] where target != source {
            onSync?(target, row)
        }
    }
}
