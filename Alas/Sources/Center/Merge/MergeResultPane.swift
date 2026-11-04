import AppKit
import SwiftUI

/// Editable center pane in the 3-way merge editor. Renders a derived
/// document from the parsed conflict regions: for each conflict, the
/// LOCAL hunk is shown directly above the REMOTE hunk, each in its own
/// band. Marker text never appears. Edits inside a hunk modify that hunk's
/// stored content; edits outside conflicts modify the surrounding
/// `.text` regions.
struct MergeResultPane: NSViewRepresentable {
    let rows: [MergeRegionVisualLayout.VisualRow]
    let bands: [MergeBand]
    let lineSpans: [[MergeSyntaxHighlighter.LineSpan]]
    let wordMarks: [Int: MergePaneText.WordMark]
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let coordinator: MergeScrollCoordinator
    /// Whether the model's last region ends with a newline. When false,
    /// the final visual row is rendered without its trailing `\n` so the
    /// buffer matches the file's EOF-newline state. Without this,
    /// no-EOF-newline files get a phantom `\n` added on writeback.
    let endsWithNewline: Bool
    /// Pushed by the view when the user types. Receives the full new
    /// buffer text so the model can reconcile inserts AND deletes, and the
    /// selection from before the edit, which undo puts back.
    let onEditFullText: (String, NSRange?) -> Void
    let editHistory: MergeConflictTabModel
    /// A change gives this pane the keyboard: an accept came from a gutter button, and ⌘Z
    /// should undo it next.
    let focusToken: Int
    @Environment(\.theme) var theme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = MergeCodeTextView.make(editable: true)
        textView.delegate = context.coordinator
        scroll.documentView = textView
        context.coordinator.scrollBridge = MergePaneScrollBridge(scroll: scroll, source: .result, coordinator: coordinator)
        context.coordinator.onEditFullText = onEditFullText
        context.coordinator.lastFocusToken = focusToken
        context.coordinator.lastSelectionRestoreCount = editHistory.selectionRestoreCount
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MergeCodeTextView else { return }
        context.coordinator.onEditFullText = onEditFullText
        textView.editHistory = editHistory
        context.coordinator.editHistory = editHistory
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            textView.window?.makeFirstResponder(textView)
        }
        let metrics = MergePaneMetrics(fontFamily: codeFontFamily, fontSize: codeFontSize)
        let palette = MergePalette(theme: theme)
        // Scroll-only updates re-run updateNSView. Skip the O(file size)
        // build+set when nothing that affects rendering changed, so
        // synchronized scrolling stays smooth on large files.
        let key = Coordinator.CacheKey(
            rows: rows,
            lineSpans: lineSpans,
            wordMarks: wordMarks,
            endsWithNewline: endsWithNewline,
            metrics: metrics,
            theme: theme
        )
        if context.coordinator.lastKey != key, let storage = textView.textStorage {
            let rendered = MergePaneText.render(rows: rows, endsWithNewline: endsWithNewline)
            let attributed = MergePaneText.attributedString(
                rendered: rendered,
                lineSpans: lineSpans,
                wordMarks: wordMarks,
                metrics: metrics,
                theme: theme,
                palette: palette
            )
            if storage.string == rendered.text {
                // The model echoed the user's own edit back: restyle in
                // place so the cursor survives.
                MergePaneText.applyAttributes(attributed, to: storage)
            } else {
                let oldSelection = textView.selectedRange()
                storage.setAttributedString(attributed)
                let clampedLocation = min(oldSelection.location, storage.length)
                textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
            }
            context.coordinator.lastKey = key
        }
        // After the text above: the selection is an offset into the restored text.
        if context.coordinator.lastSelectionRestoreCount != editHistory.selectionRestoreCount {
            context.coordinator.lastSelectionRestoreCount = editHistory.selectionRestoreCount
            if let selection = editHistory.restoredSelection {
                let length = (textView.string as NSString).length
                let location = min(selection.location, length)
                let restored = NSRange(location: location, length: min(selection.length, length - location))
                textView.setSelectedRange(restored)
                textView.scrollRangeToVisible(restored)
            }
        }
        let editorTheme = EditorTheme(theme: theme)
        textView.typingAttributes = metrics.baseAttributes(foreground: editorTheme.defaultFG)
        textView.insertionPointColor = editorTheme.defaultFG
        textView.selectedTextAttributes = [.backgroundColor: editorTheme.selection]
        textView.bands = bands
        textView.palette = palette
        textView.rowHeight = metrics.rowHeight
        textView.backgroundColor = palette.background
        coordinator.rowHeight = metrics.rowHeight
        coordinator.contentTopInset = MergePaneMetrics.contentInset.height
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        struct CacheKey: Equatable {
            let rows: [MergeRegionVisualLayout.VisualRow]
            let lineSpans: [[MergeSyntaxHighlighter.LineSpan]]
            let wordMarks: [Int: MergePaneText.WordMark]
            let endsWithNewline: Bool
            let metrics: MergePaneMetrics
            let theme: Theme
        }

        var lastFocusToken = 0
        var lastSelectionRestoreCount = 0
        weak var editHistory: MergeConflictTabModel?
        private var selectionBeforeEdit: NSRange?
        var onEditFullText: ((String, NSRange?) -> Void)?
        var lastKey: CacheKey?
        fileprivate var scrollBridge: MergePaneScrollBridge?

        /// Called by AppKit when the user types. Emits the full new
        /// buffer text — the model is responsible for diffing back to
        /// `regions`, which handles both inserts and deletes.
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            onEditFullText?(tv.string, selectionBeforeEdit)
            selectionBeforeEdit = nil
        }

        func textView(
            _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?
        ) -> Bool {
            selectionBeforeEdit = selectionBeforeEdit ?? textView.selectedRange()
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            editHistory?.noteResultSelection(tv.selectedRange())
        }
    }
}
