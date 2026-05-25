import AppKit
import SwiftUI

/// Editable center pane in the 3-way merge editor. Renders a derived
/// document from the parsed conflict regions: for each conflict, the
/// LOCAL hunk is shown directly above the REMOTE hunk, both tinted.
/// Marker text never appears. Edits inside a hunk modify that hunk's
/// stored content; edits outside conflicts modify the surrounding
/// `.text` regions.
struct MergeResultPane: NSViewRepresentable {
    let rows: [MergeRegionVisualLayout.VisualRow]
    let conflictRanges: [MergeRegionVisualLayout.VisualConflictRange]
    /// Stored hunk strings for word-diff highlighting. Indexed by
    /// `VisualConflictRange.conflictOrdinal`.
    let hunkPairs: [(local: String, remote: String)]
    let wordDiffMode: MergeWordDiff.Mode
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let coordinator: MergeScrollCoordinator
    /// Pushed by the view when the user types. Receives `(rowIndex,
    /// newRowContent)` and is responsible for translating back to a
    /// region edit on the model.
    let onEditRow: (Int, String) -> Void
    @Environment(\.theme) var theme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.observeScroll(scroll, into: coordinator)
        context.coordinator.onEditRow = onEditRow
        context.coordinator.rows = rows
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.onEditRow = onEditRow
        context.coordinator.rows = rows
        textView.textStorage?.setAttributedString(
            buildAttributedString(theme: theme)
        )
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        coordinator.rowHeight = lineHeight()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var rows: [MergeRegionVisualLayout.VisualRow] = []
        var onEditRow: ((Int, String) -> Void)?
        private var coordinator: MergeScrollCoordinator?
        private var token: NSObjectProtocol?

        func observeScroll(_ scroll: NSScrollView, into coord: MergeScrollCoordinator) {
            self.coordinator = coord
            scroll.contentView.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak scroll, weak coord] _ in
                guard let scroll, let coord, self != nil else { return }
                let y = scroll.contentView.bounds.origin.y
                coord.applyPaneY(y, source: .result)
            }
            MainActor.assumeIsolated {
                coord.onSyncResult = { @MainActor [weak coord, weak scroll] row in
                    guard let scroll, let coord else { return }
                    let y = CGFloat(row) * coord.rowHeight
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        /// Line-by-line content comparison against `rows`. Emits an
        /// `onEditRow(i, newContent)` for every visible row whose
        /// content differs from `rows[i].content`. This does NOT track
        /// structural changes (inserts, deletes, reorders) — a single
        /// inserted line cascades into per-row "edits" for every row
        /// below the insertion point because the row alignment shifts.
        /// Callers handle this by rebuilding from a snapshot rather
        /// than treating individual `onEditRow` calls as authoritative.
        /// Task 11's setRowContent on the model is designed against
        /// this contract.
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let lines = (tv.string + "\n").components(separatedBy: "\n").dropLast()
            for (i, line) in lines.enumerated() {
                guard i < rows.count else { break }
                if rows[i].content != line {
                    onEditRow?(i, line)
                }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    private func lineHeight() -> CGFloat {
        let font = CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize)
        return ceil(font.ascender + abs(font.descender) + font.leading)
    }

    private func buildAttributedString(theme: Theme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let localTint = NSColor.systemGreen.withAlphaComponent(0.14)
        let remoteTint = NSColor.systemBlue.withAlphaComponent(0.14)
        let wordLocalTint = NSColor.systemGreen.withAlphaComponent(0.35)
        let wordRemoteTint = NSColor.systemBlue.withAlphaComponent(0.35)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            .foregroundColor: NSColor(theme.color("fg")),
        ]
        // Build row-index -> (isLocal, ordinal, withinIndex) so we can
        // color hunks and apply word diff to changed ranges.
        var rowKind: [Int: (isLocal: Bool, ordinal: Int, withinIndex: Int)] = [:]
        for range in conflictRanges {
            let local = hunkPairs[range.conflictOrdinal].local
            let localLineCount = local.isEmpty
                ? 0
                : (local.components(separatedBy: "\n").last == ""
                    ? local.components(separatedBy: "\n").count - 1
                    : local.components(separatedBy: "\n").count)
            for (offset, row) in range.resultRows.enumerated() {
                if offset < localLineCount {
                    rowKind[row] = (true, range.conflictOrdinal, offset)
                } else {
                    rowKind[row] = (false, range.conflictOrdinal, offset - localLineCount)
                }
            }
        }
        for (i, row) in rows.enumerated() {
            let line = NSMutableAttributedString(string: row.content + "\n", attributes: baseAttrs)
            if let kind = rowKind[i] {
                let tint = kind.isLocal ? localTint : remoteTint
                line.addAttribute(.backgroundColor, value: tint,
                                  range: NSRange(location: 0, length: line.length))
                if wordDiffMode != .off {
                    let pair = hunkPairs[kind.ordinal]
                    let pairLines = (kind.isLocal ? pair.local : pair.remote).components(separatedBy: "\n")
                    let otherLines = (kind.isLocal ? pair.remote : pair.local).components(separatedBy: "\n")
                    let mine = kind.withinIndex < pairLines.count ? pairLines[kind.withinIndex] : ""
                    let other = kind.withinIndex < otherLines.count ? otherLines[kind.withinIndex] : ""
                    let diff = MergeWordDiff.diff(local: kind.isLocal ? mine : other,
                                                  remote: kind.isLocal ? other : mine,
                                                  mode: wordDiffMode)
                    let changed = kind.isLocal ? diff.localChanged : diff.remoteChanged
                    let wordTint = kind.isLocal ? wordLocalTint : wordRemoteTint
                    let lineUTF16Length = (row.content as NSString).length
                    for r in changed where NSMaxRange(r) <= lineUTF16Length {
                        line.addAttribute(.backgroundColor, value: wordTint, range: r)
                    }
                }
            }
            result.append(line)
        }
        return result
    }
}
