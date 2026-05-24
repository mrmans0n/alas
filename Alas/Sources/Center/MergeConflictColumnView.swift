import AppKit
import SwiftUI

/// Read-only column for LOCAL or REMOTE in the merge editor.
/// NSTextView-backed for fast highlighting and native scrolling.
struct MergeConflictColumnView: NSViewRepresentable {
    let text: String
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
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
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        textView.textContainerInset = NSSize(width: 6, height: 6)

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Avoid a full re-layout when the bound text hasn't changed (e.g., on
        // theme/config-only updates). The background color is cheap to set
        // unconditionally.
        let current = textView.string
        if current != text {
            let attr = MergeConflictTextStorage.highlightedAttributedString(
                text: text,
                fileExtension: fileExtension,
                fontFamily: codeFontFamily,
                fontSize: codeFontSize,
                theme: theme
            )
            textView.textStorage?.setAttributedString(attr)
        }
        textView.backgroundColor = NSColor(theme.color("bg-1"))
    }
}
