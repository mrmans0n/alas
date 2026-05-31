import AppKit
import SwiftUI

/// LOCAL or REMOTE pane in the 3-way merge editor. Renders the full
/// file for that side with per-hunk tint and blank padding rows so
/// corresponding conflict hunks stay vertically aligned across the
/// three panes (see `MergeRegionVisualLayout`).
///
/// Read-only — users edit only in `MergeResultPane`. Scroll position
/// is driven externally by `MergeScrollCoordinator`.
struct MergeSidePane: NSViewRepresentable {
    enum Side: Equatable {
        case local, remote
    }

    let side: Side
    let rows: [MergeRegionVisualLayout.VisualRow]
    /// Conflict ranges in THIS pane's row space (`localRows` if
    /// `.local`, `remoteRows` if `.remote`).
    let hunkRanges: [Range<Int>]
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let coordinator: MergeScrollCoordinator
    @Environment(\.theme) var theme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
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
        scroll.documentView = textView
        context.coordinator.textView = textView
        // Forward scroll changes to the coordinator.
        context.coordinator.observeScroll(scroll, side: side, into: coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Scroll-only updates re-run updateNSView via observable
        // coordinator state. Skip the O(file size) attributed-string
        // rebuild when none of the inputs that affect rendering have
        // changed — only the bg color tracks the theme cheaply.
        let bg = NSColor(theme.color("bg-1"))
        let fg = NSColor(theme.color("fg"))
        let key = Coordinator.CacheKey(
            rows: rows,
            hunkRanges: hunkRanges,
            side: side,
            fontFamily: codeFontFamily,
            fontSize: codeFontSize,
            fg: fg
        )
        if context.coordinator.lastKey != key {
            let attr = buildAttributedString(theme: theme)
            textView.textStorage?.setAttributedString(attr)
            context.coordinator.lastKey = key
        }
        textView.backgroundColor = bg
        context.coordinator.coordinator = coordinator
        context.coordinator.side = side
        context.coordinator.lastRowHeight = lineHeight()
        coordinator.rowHeight = lineHeight()
        coordinator.contentTopInset = textView.textContainerInset.height
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        struct CacheKey: Equatable {
            let rows: [MergeRegionVisualLayout.VisualRow]
            let hunkRanges: [Range<Int>]
            let side: Side
            let fontFamily: String
            let fontSize: CGFloat
            let fg: NSColor
        }
        weak var textView: NSTextView?
        var side: Side = .local
        var coordinator: MergeScrollCoordinator?
        var lastRowHeight: CGFloat = 16
        var lastKey: CacheKey?
        private var token: NSObjectProtocol?

        func observeScroll(_ scroll: NSScrollView, side: Side, into coord: MergeScrollCoordinator) {
            self.side = side
            self.coordinator = coord
            scroll.contentView.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let y = scroll.contentView.bounds.origin.y
                self.coordinator?.applyPaneY(y, source: self.side == .local ? .local : .remote)
            }
            let mySource: MergeScrollCoordinator.Source = (side == .local) ? .local : .remote
            MainActor.assumeIsolated {
                let handler: @MainActor (CGFloat) -> Void = { [weak scroll] y in
                    guard let scroll else { return }
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                switch mySource {
                case .local: coord.onSyncLocal = handler
                case .remote: coord.onSyncRemote = handler
                case .result: break // unreachable; this pane is always local or remote
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
        let tint: NSColor
        switch side {
        case .local:  tint = NSColor.systemGreen.withAlphaComponent(0.14)
        case .remote: tint = NSColor.systemBlue.withAlphaComponent(0.14)
        }
        let pad = NSAttributedString(string: "\n", attributes: [
            .font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            .foregroundColor: NSColor.clear,
            .backgroundColor: NSColor.clear,
        ])
        for (i, row) in rows.enumerated() {
            if row.isPadding {
                result.append(pad)
                continue
            }
            let content = row.content + "\n"
            let inHunk = hunkRanges.contains { $0.contains(i) }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
                .foregroundColor: NSColor(theme.color("fg")),
            ]
            let line = NSMutableAttributedString(string: content, attributes: attrs)
            if inHunk {
                line.addAttribute(.backgroundColor, value: tint,
                                  range: NSRange(location: 0, length: line.length))
            }
            result.append(line)
        }
        return result
    }
}
