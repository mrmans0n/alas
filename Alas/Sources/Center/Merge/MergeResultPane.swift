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
    /// Whether the model's last region ends with a newline. When
    /// false, `buildAttributedString` skips the trailing `\n` on the
    /// final visual row so the NSTextView buffer matches the file's
    /// EOF-newline state. Without this, no-EOF-newline files get a
    /// phantom `\n` added on writeback.
    let endsWithNewline: Bool
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
        // Scroll-only updates re-run updateNSView via observable
        // coordinator state. Skip the O(file size) build+set when
        // none of the inputs that affect rendering have changed,
        // so synchronized scrolling stays smooth on large files.
        let fg = NSColor(theme.color("fg"))
        let fgDim = NSColor(theme.color("fg-dim"))
        let key = Coordinator.CacheKey(
            rows: rows,
            conflictRanges: conflictRanges,
            hunkPairs: hunkPairs.map { "\($0.local)\u{0}\($0.remote)" },
            wordDiffMode: wordDiffMode,
            endsWithNewline: endsWithNewline,
            fileExtension: fileExtension,
            fontFamily: codeFontFamily,
            fontSize: codeFontSize,
            theme: theme,
            fg: fg,
            fgDim: fgDim
        )
        if context.coordinator.lastKey != key, let textStorage = textView.textStorage {
            let renderedText = MergeResultPaneRenderPlan.renderedText(
                rows: rows,
                endsWithNewline: endsWithNewline
            )
            // When the model echoes the user's buffer back verbatim,
            // keep typing synchronous work to text comparison only.
            // Syntax + overlay attributes are recomputed after the
            // highlight debounce below, preserving cursor/undo state.
            if textStorage.string == renderedText.text {
                context.coordinator.scheduleHighlight(
                    text: renderedText.text,
                    key: key,
                    theme: theme,
                    fileExtension: fileExtension,
                    fontFamily: codeFontFamily,
                    fontSize: codeFontSize,
                    rows: rows,
                    conflictRanges: conflictRanges,
                    hunkPairs: hunkPairs,
                    wordDiffMode: wordDiffMode,
                    endsWithNewline: endsWithNewline,
                    debounce: true
                )
            } else {
                let newAttr = buildAttributedString(theme: theme, syntaxSpans: [])
                let oldSelection = textView.selectedRange()
                context.coordinator.replaceTextStorage(with: newAttr)
                let clampedLocation = min(oldSelection.location, textStorage.length)
                textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
                context.coordinator.resetHighlightSession()
                context.coordinator.scheduleHighlight(
                    text: newAttr.string,
                    key: key,
                    theme: theme,
                    fileExtension: fileExtension,
                    fontFamily: codeFontFamily,
                    fontSize: codeFontSize,
                    rows: rows,
                    conflictRanges: conflictRanges,
                    hunkPairs: hunkPairs,
                    wordDiffMode: wordDiffMode,
                    endsWithNewline: endsWithNewline,
                    debounce: false
                )
            }
            context.coordinator.lastKey = key
        }
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        coordinator.rowHeight = lineHeight()
        coordinator.contentTopInset = textView.textContainerInset.height
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.editorUndoManager.removeAllActions()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let editorUndoManager = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }

        struct CacheKey: Equatable {
            let rows: [MergeRegionVisualLayout.VisualRow]
            let conflictRanges: [MergeRegionVisualLayout.VisualConflictRange]
            let hunkPairs: [String]
            let wordDiffMode: MergeWordDiff.Mode
            let endsWithNewline: Bool
            let fileExtension: String
            let fontFamily: String
            let fontSize: CGFloat
            let theme: Theme
            let fg: NSColor
            let fgDim: NSColor
        }
        weak var textView: NSTextView?
        var rows: [MergeRegionVisualLayout.VisualRow] = []
        var onEditFullText: ((String) -> Void)?
        var lastKey: CacheKey?
        private var coordinator: MergeScrollCoordinator?
        private var token: NSObjectProtocol?
        private var pendingTextEdits: [EditorTextEdit] = []
        private var highlightTask: Task<Void, Never>?
        private var highlightGeneration = 0
        private let highlightSession = TreeSitterHighlighter.Session()
        private var isReplacingTextStorage = false
        private var needsHighlightSessionReset = false

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
                coord.onSyncResult = { @MainActor [weak scroll] y in
                    guard let scroll else { return }
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

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if !isReplacingTextStorage {
                pendingTextEdits.append(EditorTextEdit(
                    location: affectedCharRange.location,
                    oldLength: affectedCharRange.length,
                    replacementText: replacementString ?? ""
                ))
            }
            return true
        }

        func replaceTextStorage(with attributedString: NSAttributedString) {
            isReplacingTextStorage = true
            textView?.textStorage?.setAttributedString(attributedString)
            isReplacingTextStorage = false
        }

        func resetHighlightSession() {
            highlightTask?.cancel()
            pendingTextEdits.removeAll()
            highlightGeneration += 1
            needsHighlightSessionReset = true
        }

        func scheduleHighlight(
            text: String,
            key: CacheKey,
            theme: Theme,
            fileExtension: String,
            fontFamily: String,
            fontSize: CGFloat,
            rows: [MergeRegionVisualLayout.VisualRow],
            conflictRanges: [MergeRegionVisualLayout.VisualConflictRange],
            hunkPairs: [(local: String, remote: String)],
            wordDiffMode: MergeWordDiff.Mode,
            endsWithNewline: Bool,
            debounce: Bool
        ) {
            highlightTask?.cancel()
            highlightGeneration += 1
            let generation = highlightGeneration
            let session = highlightSession
            let edits = pendingTextEdits
            let editCount = edits.count
            let resetSession = needsHighlightSessionReset
            highlightTask = Task(priority: .userInitiated) { [weak self] in
                if debounce {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                guard !Task.isCancelled else { return }
                if resetSession {
                    await session.reset()
                    await MainActor.run {
                        guard let self, self.highlightGeneration == generation else { return }
                        self.needsHighlightSessionReset = false
                    }
                }
                let spans = await session.highlight(source: text, fileExtension: fileExtension, edits: edits)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.highlightGeneration == generation,
                          self.lastKey == key,
                          let textStorage = self.textView?.textStorage,
                          textStorage.string == text else { return }
                    let highlighted = MergeResultPane.buildAttributedString(
                        rows: rows,
                        conflictRanges: conflictRanges,
                        hunkPairs: hunkPairs,
                        wordDiffMode: wordDiffMode,
                        codeFontFamily: fontFamily,
                        codeFontSize: fontSize,
                        endsWithNewline: endsWithNewline,
                        theme: theme,
                        syntaxSpans: spans
                    )
                    let fullRange = NSRange(location: 0, length: textStorage.length)
                    textStorage.beginEditing()
                    highlighted.enumerateAttributes(in: fullRange) { attrs, range, _ in
                        textStorage.setAttributes(attrs, range: range)
                    }
                    textStorage.endEditing()
                    if editCount > 0 {
                        self.pendingTextEdits.removeFirst(min(editCount, self.pendingTextEdits.count))
                    }
                }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
            highlightTask?.cancel()
        }
    }

    private func lineHeight() -> CGFloat {
        let font = CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize)
        return ceil(font.ascender + abs(font.descender) + font.leading)
    }

    private func buildAttributedString(theme: Theme, syntaxSpans: [HighlightSpan]) -> NSAttributedString {
        Self.buildAttributedString(
            rows: rows,
            conflictRanges: conflictRanges,
            hunkPairs: hunkPairs,
            wordDiffMode: wordDiffMode,
            codeFontFamily: codeFontFamily,
            codeFontSize: codeFontSize,
            endsWithNewline: endsWithNewline,
            theme: theme,
            syntaxSpans: syntaxSpans
        )
    }

    fileprivate static func buildAttributedString(
        rows: [MergeRegionVisualLayout.VisualRow],
        conflictRanges: [MergeRegionVisualLayout.VisualConflictRange],
        hunkPairs: [(local: String, remote: String)],
        wordDiffMode: MergeWordDiff.Mode,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        endsWithNewline: Bool,
        theme: Theme,
        syntaxSpans: [HighlightSpan]
    ) -> NSMutableAttributedString {
        let localTint = NSColor.systemGreen.withAlphaComponent(0.14)
        let remoteTint = NSColor.systemBlue.withAlphaComponent(0.14)
        let wordLocalTint = NSColor.systemGreen.withAlphaComponent(0.35)
        let wordRemoteTint = NSColor.systemBlue.withAlphaComponent(0.35)
        let renderedText = MergeResultPaneRenderPlan.renderedText(rows: rows, endsWithNewline: endsWithNewline)
        let font = CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize)
        let editorTheme = EditorTheme(theme: theme)
        let result = NSMutableAttributedString(
            string: renderedText.text,
            attributes: [
                .font: font,
                .foregroundColor: editorTheme.defaultFG,
                .paragraphStyle: CenterTypography.paragraphStyle()
            ]
        )
        for span in syntaxSpans {
            guard NSMaxRange(span.range) <= result.length else { continue }
            result.addAttributes(editorTheme.attributes(for: span.capture), range: span.range)
        }
        let rowKinds = MergeResultPaneRenderPlan.rowKinds(conflictRanges: conflictRanges)
        let italicFont = CenterTypography
            .resolveCodeFont(family: codeFontFamily, size: codeFontSize)
            .italicVariant()
        for (i, row) in rows.enumerated() {
            let range = renderedText.rowRanges[i]
            switch rowKinds[i] {
            case .local(let ordinal, let withinIndex), .remote(let ordinal, let withinIndex):
                let isLocal: Bool
                if case .local = rowKinds[i] {
                    isLocal = true
                } else {
                    isLocal = false
                }
                let tint = isLocal ? localTint : remoteTint
                result.addAttribute(.backgroundColor, value: tint, range: range)
                if wordDiffMode != .off, ordinal < hunkPairs.count {
                    let pair = hunkPairs[ordinal]
                    let pairLines = (isLocal ? pair.local : pair.remote).components(separatedBy: "\n")
                    let otherLines = (isLocal ? pair.remote : pair.local).components(separatedBy: "\n")
                    let mine = withinIndex < pairLines.count ? pairLines[withinIndex] : ""
                    let other = withinIndex < otherLines.count ? otherLines[withinIndex] : ""
                    let diff = MergeWordDiff.diff(local: isLocal ? mine : other,
                                                  remote: isLocal ? other : mine,
                                                  mode: wordDiffMode)
                    let changed = isLocal ? diff.localChanged : diff.remoteChanged
                    let wordTint = isLocal ? wordLocalTint : wordRemoteTint
                    let rowContentLen = (row.content as NSString).length
                    for r in changed where NSMaxRange(r) <= rowContentLen {
                        let abs = NSRange(location: range.location + r.location, length: r.length)
                        result.addAttribute(.backgroundColor, value: wordTint, range: abs)
                    }
                }
            case .base:
                let baseTint = NSColor(theme.color("fg-dim")).withAlphaComponent(0.10)
                result.addAttribute(.backgroundColor, value: baseTint, range: range)
                result.addAttribute(.foregroundColor, value: NSColor(theme.color("fg-dim")), range: range)
                result.addAttribute(.font, value: italicFont, range: range)
            case nil:
                break
            }
        }
        return result
    }
}

enum MergeResultPaneRenderPlan {
    enum RowKind: Equatable {
        case local(ordinal: Int, withinIndex: Int)
        case base
        case remote(ordinal: Int, withinIndex: Int)
    }

    struct RenderedText: Equatable {
        let text: String
        let rowRanges: [NSRange]
    }

    static func renderedText(
        rows: [MergeRegionVisualLayout.VisualRow],
        endsWithNewline: Bool
    ) -> RenderedText {
        var text = ""
        var rowRanges: [NSRange] = []
        for (i, row) in rows.enumerated() {
            let isLastRow = i == rows.count - 1
            let suffix = (isLastRow && !endsWithNewline) ? "" : "\n"
            let start = (text as NSString).length
            text += row.content + suffix
            let length = (text as NSString).length - start
            rowRanges.append(NSRange(location: start, length: length))
        }
        return RenderedText(text: text, rowRanges: rowRanges)
    }

    static func rowKinds(
        conflictRanges: [MergeRegionVisualLayout.VisualConflictRange]
    ) -> [Int: RowKind] {
        var kinds: [Int: RowKind] = [:]
        for range in conflictRanges {
            for row in range.resultLocalRows {
                kinds[row] = .local(
                    ordinal: range.conflictOrdinal,
                    withinIndex: row - range.resultLocalRows.lowerBound
                )
            }
            for row in range.baseRows {
                kinds[row] = .base
            }
            for row in range.resultRemoteRows {
                kinds[row] = .remote(
                    ordinal: range.conflictOrdinal,
                    withinIndex: row - range.resultRemoteRows.lowerBound
                )
            }
        }
        return kinds
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
