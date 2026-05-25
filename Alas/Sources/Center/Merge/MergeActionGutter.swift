import AppKit
import SwiftUI

/// Narrow vertical strip between LOCAL ↔ RESULT or RESULT ↔ REMOTE.
/// Two responsibilities:
/// 1. Draws a diagonal quadrilateral per conflict block, connecting
///    the hunk's row range in the side pane to the corresponding row
///    range inside RESULT.
/// 2. Hosts the accept (`»`/`«`) and reject (`×`) glyphs aligned with
///    each hunk's first visible row, positioned above the diagonal.
///
/// Layout positions are driven by `MergeScrollCoordinator` and the
/// per-pane row mappings published by `MergeRegionVisualLayout`. The
/// gutter does NOT know about NSTextView — it's a pure overlay
/// computed from `(row, height)` math.
struct MergeActionGutter: NSViewRepresentable {
    enum Side {
        case localToResult, resultToRemote
    }

    let side: Side
    let conflictRanges: [MergeRegionVisualLayout.VisualConflictRange]
    let coordinator: MergeScrollCoordinator
    let onAccept: (Int) -> Void  // ordinal
    let onReject: (Int) -> Void
    @Environment(\.theme) var theme

    func makeNSView(context: Context) -> GutterView {
        let view = GutterView()
        view.side = side
        view.coordinator = coordinator
        view.onAccept = onAccept
        view.onReject = onReject
        view.theme = theme
        return view
    }

    func updateNSView(_ view: GutterView, context: Context) {
        view.side = side
        view.conflictRanges = conflictRanges
        view.coordinator = coordinator
        view.onAccept = onAccept
        view.onReject = onReject
        view.theme = theme
        view.needsDisplay = true
        view.needsLayout = true
    }

    final class GutterView: NSView {
        var side: Side = .localToResult
        var conflictRanges: [MergeRegionVisualLayout.VisualConflictRange] = []
        var coordinator: MergeScrollCoordinator?
        var onAccept: ((Int) -> Void)?
        var onReject: ((Int) -> Void)?
        var theme: Theme?

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let coordinator else { return }
            let rowHeight = coordinator.rowHeight
            let scrollOffset = CGFloat(coordinator.logicalRow) * rowHeight
            let fill: NSColor = side == .localToResult
                ? NSColor.systemGreen.withAlphaComponent(0.22)
                : NSColor.systemBlue.withAlphaComponent(0.22)
            for range in conflictRanges {
                let (sourceStart, sourceEnd, resultStart, resultEnd) = endpoints(for: range)
                let leftTop = CGFloat(sourceStart) * rowHeight - scrollOffset
                let leftBottom = CGFloat(sourceEnd) * rowHeight - scrollOffset
                let rightTop = CGFloat(resultStart) * rowHeight - scrollOffset
                let rightBottom = CGFloat(resultEnd) * rowHeight - scrollOffset
                let path = NSBezierPath()
                if side == .localToResult {
                    path.move(to: NSPoint(x: 0, y: leftTop))
                    path.line(to: NSPoint(x: bounds.width, y: rightTop))
                    path.line(to: NSPoint(x: bounds.width, y: rightBottom))
                    path.line(to: NSPoint(x: 0, y: leftBottom))
                } else {
                    path.move(to: NSPoint(x: 0, y: rightTop))
                    path.line(to: NSPoint(x: bounds.width, y: leftTop))
                    path.line(to: NSPoint(x: bounds.width, y: leftBottom))
                    path.line(to: NSPoint(x: 0, y: rightBottom))
                }
                path.close()
                fill.setFill()
                path.fill()
            }
        }

        override func layout() {
            super.layout()
            subviews.forEach { $0.removeFromSuperview() }
            guard let coordinator else { return }
            let rowHeight = coordinator.rowHeight
            let scrollOffset = CGFloat(coordinator.logicalRow) * rowHeight
            for range in conflictRanges {
                let (sourceStart, _, _, _) = endpoints(for: range)
                let y = CGFloat(sourceStart) * rowHeight - scrollOffset
                let accept = makeButton(
                    glyph: side == .localToResult ? "chevron.right.2" : "chevron.left.2",
                    accent: NSColor.systemBlue
                ) { [weak self] in self?.onAccept?(range.conflictOrdinal) }
                accept.frame = NSRect(x: 4, y: y, width: 16, height: rowHeight)
                addSubview(accept)
                let reject = makeButton(glyph: "xmark", accent: NSColor.gray) {
                    [weak self] in self?.onReject?(range.conflictOrdinal)
                }
                reject.frame = NSRect(x: 4, y: y + rowHeight, width: 16, height: rowHeight)
                addSubview(reject)
            }
        }

        /// Endpoints for the diagonal path + glyph anchor. Returns the
        /// source-pane (LOCAL or REMOTE) range and the RESULT-pane
        /// range for this conflict. All values are RAW row indices —
        /// the caller converts to Y in points.
        ///
        /// `localRows` / `remoteRows` / `resultRows` are half-open
        /// `Range<Int>`, so `lowerBound` is inclusive and
        /// `upperBound` is exclusive (one past the last row).
        private func endpoints(for range: MergeRegionVisualLayout.VisualConflictRange) -> (Int, Int, Int, Int) {
            switch side {
            case .localToResult:
                return (range.localRows.lowerBound, range.localRows.upperBound,
                        range.resultRows.lowerBound, range.resultRows.upperBound)
            case .resultToRemote:
                return (range.remoteRows.lowerBound, range.remoteRows.upperBound,
                        range.resultRows.lowerBound, range.resultRows.upperBound)
            }
        }

        private func makeButton(glyph: String, accent: NSColor, action: @escaping () -> Void) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: glyph, accessibilityDescription: nil) ?? NSImage(),
                                  target: nil,
                                  action: nil)
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.contentTintColor = accent
            let handler = ActionHandler(closure: action)
            objc_setAssociatedObject(button, &ActionHandler.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            button.target = handler
            button.action = #selector(ActionHandler.fire)
            return button
        }

        private final class ActionHandler: NSObject {
            static var key: UInt8 = 0
            let closure: () -> Void
            init(closure: @escaping () -> Void) { self.closure = closure }
            @objc func fire() { closure() }
        }
    }
}
