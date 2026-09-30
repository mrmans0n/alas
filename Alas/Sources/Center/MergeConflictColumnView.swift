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

    final class Coordinator {
        var renderedTheme: Theme?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        textView.backgroundColor = EditorTheme(theme: theme).bg
        textView.textContainerInset = NSSize(width: 6, height: 6)

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Avoid a full re-layout when neither the text nor the theme changed
        // (e.g., scroll-only or unrelated config updates). The background
        // color is cheap to set unconditionally.
        if MergeConflictTextStorage.needsRebuild(
            renderedText: textView.string,
            text: text,
            renderedTheme: context.coordinator.renderedTheme,
            theme: theme
        ) {
            let attr = MergeConflictTextStorage.highlightedAttributedString(
                text: text,
                fileExtension: fileExtension,
                fontFamily: codeFontFamily,
                fontSize: codeFontSize,
                theme: theme
            )
            textView.textStorage?.setAttributedString(attr)
            context.coordinator.renderedTheme = theme
        }
        textView.backgroundColor = EditorTheme(theme: theme).bg
    }
}
