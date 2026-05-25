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
    /// Pushed by the view when the user types. Receives the full new
    /// buffer text so the model can reconcile inserts AND deletes
    /// correctly. Replaces the old per-row `onEditRow` callback which
    /// silently dropped deletions (only iterating `lines.count` rows).
    let onEditFullText: (String) -> Void
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
        context.coordinator.onEditFullText = onEditFullText
        context.coordinator.rows = rows
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.onEditFullText = onEditFullText
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
        var onEditFullText: ((String) -> Void)?
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

        /// Called by AppKit when the user types. Emits the full new
        /// buffer text — the model is responsible for diffing back to
        /// `regions`. This handles both inserts and deletes correctly,
        /// unlike the per-row diff approach which silently dropped
        /// deletions (only iterating `lines.count` rows).
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            onEditFullText?(tv.string)
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
            } else if conflictRanges.first(where: { $0.baseRows.contains(i) }) != nil {
                let baseTint = NSColor(theme.color("fg-dim")).withAlphaComponent(0.10)
                line.addAttribute(.backgroundColor, value: baseTint,
                                  range: NSRange(location: 0, length: line.length))
                line.addAttribute(.foregroundColor, value: NSColor(theme.color("fg-dim")),
                                  range: NSRange(location: 0, length: line.length))
                if let italicFont = (baseAttrs[.font] as? NSFont)?.italicVariant() {
                    line.addAttribute(.font, value: italicFont,
                                      range: NSRange(location: 0, length: line.length))
                }
            }
            result.append(line)
        }
        return result
    }
}

private extension NSFont {
    func italicVariant() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.italic)
        )
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
