import AppKit
import SwiftUI

/// Narrow vertical strip between LOCAL ↔ RESULT or RESULT ↔ REMOTE.
/// Draws a small rounded rail per conflict block and hosts accept /
/// reject controls aligned to the same row coordinates.
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
        view.conflictRanges = conflictRanges
        view.coordinator = coordinator
        view.onAccept = onAccept
        view.onReject = onReject
        return view
    }

    func updateNSView(_ view: GutterView, context: Context) {
        view.side = side
        view.conflictRanges = conflictRanges
        view.coordinator = coordinator
        view.onAccept = onAccept
        view.onReject = onReject
        view.needsDisplay = true
        view.needsLayout = true
    }

    final class GutterView: NSView {
        var side: Side = .localToResult
        var conflictRanges: [MergeRegionVisualLayout.VisualConflictRange] = []
        var coordinator: MergeScrollCoordinator?
        var onAccept: ((Int) -> Void)?
        var onReject: ((Int) -> Void)?

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let coordinator else { return }
            let rowHeight = coordinator.rowHeight
            let scrollOffset = coordinator.scrollY
            let fill = side == .localToResult
                ? NSColor.systemGreen.withAlphaComponent(0.22)
                : NSColor.systemBlue.withAlphaComponent(0.22)
            let stroke = side == .localToResult
                ? NSColor.systemGreen.withAlphaComponent(0.58)
                : NSColor.systemBlue.withAlphaComponent(0.58)
            for range in conflictRanges {
                let pts = endpoints(for: range)
                let top = min(CGFloat(pts.leftStart), CGFloat(pts.rightStart)) * rowHeight + coordinator.contentTopInset - scrollOffset
                let bottom = max(CGFloat(pts.leftEnd), CGFloat(pts.rightEnd)) * rowHeight + coordinator.contentTopInset - scrollOffset
                let railHeight = max(rowHeight, bottom - top)
                let railX = side == .localToResult ? bounds.width - 10 : 4
                let rect = NSRect(x: railX, y: top, width: 6, height: railHeight)
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                fill.setFill()
                path.fill()
                stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        override func layout() {
            super.layout()
            subviews.forEach { $0.removeFromSuperview() }
            guard let coordinator else { return }
            let rowHeight = coordinator.rowHeight
            let scrollOffset = coordinator.scrollY
            for range in conflictRanges {
                let pts = endpoints(for: range)
                let y = CGFloat(pts.sourceStart) * rowHeight + coordinator.contentTopInset - scrollOffset
                let accept = makeButton(
                    glyph: side == .localToResult ? "chevron.right.2" : "chevron.left.2",
                    label: side == .localToResult
                        ? "Accept LOCAL conflict \(range.conflictOrdinal + 1)"
                        : "Accept REMOTE conflict \(range.conflictOrdinal + 1)",
                    accent: NSColor.systemBlue
                ) { [weak self] in self?.onAccept?(range.conflictOrdinal) }
                accept.frame = NSRect(x: 6, y: y, width: 16, height: rowHeight)
                addSubview(accept)
                let reject = makeButton(
                    glyph: "xmark",
                    label: side == .localToResult
                        ? "Reject LOCAL conflict \(range.conflictOrdinal + 1)"
                        : "Reject REMOTE conflict \(range.conflictOrdinal + 1)",
                    accent: NSColor.gray
                ) { [weak self] in self?.onReject?(range.conflictOrdinal) }
                reject.frame = NSRect(x: 6, y: y + rowHeight, width: 16, height: rowHeight)
                addSubview(reject)
            }
        }

        /// Left-edge and right-edge row ranges (half-open) for the
        /// visual hunk rail. "Left" is the column nearer x=0 in the
        /// gutter, "right" is nearer x=bounds.width.
        private func endpoints(for range: MergeRegionVisualLayout.VisualConflictRange) -> (
            leftStart: Int, leftEnd: Int,
            rightStart: Int, rightEnd: Int,
            sourceStart: Int  // for the button anchor — always the side-pane hunk
        ) {
            switch side {
            case .localToResult:
                return (
                    leftStart: range.localRows.lowerBound,
                    leftEnd: range.localRows.upperBound,
                    rightStart: range.resultLocalRows.lowerBound,
                    rightEnd: range.resultLocalRows.upperBound,
                    sourceStart: range.localRows.lowerBound
                )
            case .resultToRemote:
                return (
                    leftStart: range.resultRemoteRows.lowerBound,
                    leftEnd: range.resultRemoteRows.upperBound,
                    rightStart: range.remoteRows.lowerBound,
                    rightEnd: range.remoteRows.upperBound,
                    sourceStart: range.remoteRows.lowerBound
                )
            }
        }

        private func makeButton(glyph: String, label: String, accent: NSColor, action: @escaping () -> Void) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: glyph, accessibilityDescription: label) ?? NSImage(),
                                  target: nil,
                                  action: nil)
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.contentTintColor = accent
            button.setAccessibilityLabel(label)
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
