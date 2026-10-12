import AppKit
import SwiftUI

/// Strip between LOCAL ↔ RESULT or RESULT ↔ REMOTE. Draws a curved ribbon
/// joining each side hunk to its copy in RESULT — the panes scroll at
/// different rates through hunks of different heights, so the ribbon is
/// what shows the correspondence — and hosts the accept / reject controls
/// at the side hunk's top edge.
///
/// Positions come from `MergeScrollCoordinator` per-pane offsets and the
/// row ranges published by `MergeRegionVisualLayout`; the gutter does not
/// know about NSTextView.
struct MergeActionGutter: NSViewRepresentable {
    enum Side {
        case localToResult, resultToRemote
    }

    nonisolated static let width: CGFloat = 36

    let side: Side
    let conflictRanges: [MergeRegionVisualLayout.VisualConflictRange]
    let currentOrdinal: Int?
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let coordinator: MergeScrollCoordinator
    let onAccept: (Int) -> Void  // ordinal
    let onReject: (Int) -> Void
    @Environment(\.theme) var theme

    func makeNSView(context: Context) -> GutterView {
        let view = GutterView()
        // Ribbons and buttons of hunks scrolled out of view must not bleed
        // over the column headers.
        view.clipsToBounds = true
        return view
    }

    func updateNSView(_ view: GutterView, context: Context) {
        view.side = side
        view.conflictRanges = conflictRanges
        view.currentOrdinal = currentOrdinal
        view.rowHeight = MergePaneMetrics(fontFamily: codeFontFamily, fontSize: codeFontSize).rowHeight
        view.palette = MergePalette(theme: theme)
        view.rejectTint = NSColor(theme.color("fg-muted"))
        view.observe(coordinator)
        view.onAccept = onAccept
        view.onReject = onReject
        view.needsDisplay = true
        view.needsLayout = true
    }

    @MainActor
    final class GutterView: NSView {
        var side: Side = .localToResult
        var conflictRanges: [MergeRegionVisualLayout.VisualConflictRange] = []
        var currentOrdinal: Int?
        var rowHeight: CGFloat = 16
        var palette: MergePalette?
        var rejectTint: NSColor = .secondaryLabelColor
        var onAccept: ((Int) -> Void)?
        var onReject: ((Int) -> Void)?
        private weak var coordinator: MergeScrollCoordinator?
        private var scrollObserverID: UUID?
        private var buttons: [(accept: NSButton, reject: NSButton)] = []

        override var isFlipped: Bool { true }

        func observe(_ coordinator: MergeScrollCoordinator) {
            guard self.coordinator !== coordinator else { return }
            if let scrollObserverID, let previous = self.coordinator {
                previous.removeScrollObserver(scrollObserverID)
            }
            self.coordinator = coordinator
            scrollObserverID = coordinator.addScrollObserver { [weak self] in
                self?.needsDisplay = true
                self?.needsLayout = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let palette else { return }
            palette.gutterBackground.setFill()
            bounds.fill()
            let kind: MergeBand.Kind = side == .localToResult ? .local : .remote
            let width = bounds.width
            for range in conflictRanges {
                let ends = endpoints(for: range)
                guard max(ends.left.upperBound, ends.right.upperBound) >= dirtyRect.minY,
                      min(ends.left.lowerBound, ends.right.lowerBound) <= dirtyRect.maxY
                else { continue }
                let isCurrent = range.conflictOrdinal == currentOrdinal
                let top = NSBezierPath()
                top.move(to: NSPoint(x: 0, y: ends.left.lowerBound))
                top.curve(
                    to: NSPoint(x: width, y: ends.right.lowerBound),
                    controlPoint1: NSPoint(x: width / 2, y: ends.left.lowerBound),
                    controlPoint2: NSPoint(x: width / 2, y: ends.right.lowerBound)
                )
                let bottom = NSBezierPath()
                bottom.move(to: NSPoint(x: width, y: ends.right.upperBound))
                bottom.curve(
                    to: NSPoint(x: 0, y: ends.left.upperBound),
                    controlPoint1: NSPoint(x: width / 2, y: ends.right.upperBound),
                    controlPoint2: NSPoint(x: width / 2, y: ends.left.upperBound)
                )
                let ribbon = NSBezierPath()
                ribbon.append(top)
                ribbon.line(to: NSPoint(x: width, y: ends.right.upperBound))
                ribbon.append(bottom)
                ribbon.close()
                palette.fill(for: kind, isCurrent: isCurrent).setFill()
                ribbon.fill()
                palette.border(for: kind, isCurrent: isCurrent).setStroke()
                top.lineWidth = 1
                bottom.lineWidth = 1
                top.stroke()
                bottom.stroke()
            }
        }

        override func layout() {
            super.layout()
            syncButtonCount()
            for (index, range) in conflictRanges.enumerated() where index < buttons.count {
                let ends = endpoints(for: range)
                let anchor = side == .localToResult ? ends.left : ends.right
                // Both controls share the hunk's first row, accept nearest its
                // side pane, so adjacent one-line hunks never overlap.
                let y = anchor.lowerBound + (rowHeight - 16) / 2
                let acceptX: CGFloat = side == .localToResult ? 2 : bounds.width - 18
                let rejectX: CGFloat = side == .localToResult ? 18 : bounds.width - 34
                buttons[index].accept.frame = NSRect(x: acceptX, y: y, width: 16, height: 16)
                buttons[index].reject.frame = NSRect(x: rejectX, y: y, width: 16, height: 16)
                let tint = palette?.color(for: side == .localToResult ? .local : .remote) ?? .controlAccentColor
                buttons[index].accept.contentTintColor = tint
                buttons[index].reject.contentTintColor = rejectTint
                let ordinal = range.conflictOrdinal
                (buttons[index].accept.target as? ActionHandler)?.closure = { [weak self] in self?.onAccept?(ordinal) }
                (buttons[index].reject.target as? ActionHandler)?.closure = { [weak self] in self?.onReject?(ordinal) }
                let sideName = side == .localToResult ? "LOCAL" : "REMOTE"
                buttons[index].accept.setAccessibilityLabel("Accept \(sideName) for conflict \(ordinal + 1)")
                buttons[index].accept.toolTip = "Accept \(sideName) for this conflict"
                buttons[index].reject.setAccessibilityLabel("Reject \(sideName) for conflict \(ordinal + 1)")
                buttons[index].reject.toolTip = "Reject \(sideName): keep the other side"
            }
        }

        /// Top and bottom y of the hunk on each edge of the gutter, in
        /// gutter coordinates. "Left" is the edge nearer x = 0.
        private func endpoints(for range: MergeRegionVisualLayout.VisualConflictRange) -> (
            left: ClosedRange<CGFloat>, right: ClosedRange<CGFloat>
        ) {
            let (leftPane, leftRows, rightPane, rightRows): (
                MergeScrollCoordinator.Source, Range<Int>, MergeScrollCoordinator.Source, Range<Int>
            ) = switch side {
            case .localToResult: (.local, range.localRows, .result, range.resultLocalRows)
            case .resultToRemote: (.result, range.resultRemoteRows, .remote, range.remoteRows)
            }
            return (span(leftRows, in: leftPane), span(rightRows, in: rightPane))
        }

        private func span(_ rows: Range<Int>, in pane: MergeScrollCoordinator.Source) -> ClosedRange<CGFloat> {
            let offset = coordinator?.offset(for: pane) ?? 0
            let top = MergePaneMetrics.contentInset.height + CGFloat(rows.lowerBound) * rowHeight - offset
            return top ... top + CGFloat(rows.count) * rowHeight
        }

        private func syncButtonCount() {
            while buttons.count > conflictRanges.count {
                let removed = buttons.removeLast()
                removed.accept.removeFromSuperview()
                removed.reject.removeFromSuperview()
            }
            while buttons.count < conflictRanges.count {
                let accept = makeButton(glyph: side == .localToResult ? "chevron.right.2" : "chevron.left.2")
                let reject = makeButton(glyph: "xmark")
                addSubview(accept)
                addSubview(reject)
                buttons.append((accept, reject))
            }
        }

        private func makeButton(glyph: String) -> NSButton {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            let image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) ?? NSImage()
            let handler = ActionHandler()
            let button = NSButton(image: image, target: handler, action: #selector(ActionHandler.fire))
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.imagePosition = .imageOnly
            objc_setAssociatedObject(button, &ActionHandler.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return button
        }

        @MainActor
        private final class ActionHandler: NSObject {
            // Used only as a stable address for objc_setAssociatedObject; the value is never read.
            nonisolated(unsafe) static var key: UInt8 = 0
            var closure: @MainActor () -> Void = {}
            @objc func fire() { closure() }
        }

        isolated deinit {
            if let scrollObserverID, let coordinator {
                coordinator.removeScrollObserver(scrollObserverID)
            }
        }
    }
}
