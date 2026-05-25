import AppKit
import SwiftUI

/// Editable RESULT column for the merge editor. Bound to the model's
/// `resultText`. Reuses `MergeConflictTextStorage` for syntax highlighting
/// and overlays yellow shading on conflict marker blocks so the user can
/// see at a glance which regions still need resolution.
struct MergeConflictResultView: NSViewRepresentable {
    @Binding var text: String
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let showBase: Bool
    /// Index of the conflict the user has navigated to (prev/next), or
    /// nil when none. The view scrolls to and selects that conflict's
    /// line range on every change so the navigation actually moves the
    /// cursor in the editor.
    let currentConflictIndex: Int?
    /// Structural-change signal. Paired with `currentConflictIndex` in
    /// the reselection guard so an accept that removes a conflict block
    /// (which leaves the index numerically the same while the underlying
    /// block at that ordinal changes) still triggers a reselect. Plain
    /// text edits inside the buffer don't change this count, so we
    /// don't scroll-jack the user mid-typing.
    let conflictCount: Int
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
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.allowsUndo = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.delegate = context.coordinator
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Re-render whenever text changed OR the showBase toggle changed since
        // last render (italic/muted attrs would otherwise persist after toggle-off).
        let current = textView.string
        let needsFullRender = current != text || context.coordinator.lastShowBase != showBase
        if needsFullRender {
            let attr = MergeConflictTextStorage.highlightedAttributedString(
                text: text,
                fileExtension: fileExtension,
                fontFamily: codeFontFamily,
                fontSize: codeFontSize,
                theme: theme
            )
            applyConflictShading(to: attr, text: text, theme: theme)
            textView.textStorage?.setAttributedString(attr)
            context.coordinator.lastShowBase = showBase
        } else {
            // Even when the string is unchanged, the conflict regions may have
            // shifted (a typed edit can resolve a marker). Re-apply shading.
            if let storage = textView.textStorage {
                applyConflictShading(to: storage, text: text, theme: theme)
            }
        }
        textView.backgroundColor = NSColor(theme.color("bg-1"))

        // Scroll + select the current conflict when navigation lands on
        // a new ordinal OR when an accept removes a block and renumbers
        // (same ordinal points at a different block). The guard tuple
        // is (index, count); plain text edits don't change `count`, so
        // typing won't yank the user's cursor.
        let trigger = ReselectTrigger(index: currentConflictIndex, count: conflictCount)
        if trigger != context.coordinator.lastReselectTrigger {
            if let index = currentConflictIndex,
               let range = Self.conflictRange(in: text, at: index) {
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            }
            context.coordinator.lastReselectTrigger = trigger
        }
    }

    /// Pair tracked across `updateNSView` invocations to decide whether
    /// to re-select the current conflict's range. See the call site.
    struct ReselectTrigger: Equatable {
        let index: Int?
        let count: Int
    }

    func makeCoordinator() -> Coordinator {
        Coordinator($text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        let text: Binding<String>
        /// Tracks the `showBase` value from the last full re-render so we can
        /// detect toggle changes and force a fresh attributed string build.
        var lastShowBase: Bool = false
        /// Pair we last reselected for, so we only re-scroll when the
        /// user actually navigates or a structural change (accept, agent
        /// apply) renumbers conflicts.
        var lastReselectTrigger: ReselectTrigger?
        init(_ text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }

    /// Returns the NSRange covering the Nth conflict block's lines in
    /// `text`, or nil when the index is out of bounds.
    private static func conflictRange(in text: String, at ordinal: Int) -> NSRange? {
        let regions = ConflictMarkerParser.parse(text)
        var seen = 0
        let nsString = text as NSString
        let lineRanges = computeLineRanges(in: nsString)
        for region in regions {
            guard case .conflict(let block) = region else { continue }
            if seen == ordinal {
                let lower = max(block.lineRangeInMerged.lowerBound, 0)
                let upper = min(block.lineRangeInMerged.upperBound, lineRanges.count - 1)
                guard upper >= lower, upper < lineRanges.count else { return nil }
                let start = lineRanges[lower].location
                let end = NSMaxRange(lineRanges[upper])
                return NSRange(location: start, length: end - start)
            }
            seen += 1
        }
        return nil
    }

    /// Applies a yellow background to each line range that falls inside a
    /// `<<<<<<< ... >>>>>>>` block in `text`. Also applies italic + muted
    /// attributes to BASE lines when `showBase` is true.
    /// Accepts any `NSMutableAttributedString` (including `NSTextStorage`,
    /// which IS-A `NSMutableAttributedString`).
    private func applyConflictShading(
        to storage: NSMutableAttributedString,
        text: String,
        theme: Theme
    ) {
        let regions = ConflictMarkerParser.parse(text)
        let highlight = NSColor(theme.color("warn")).withAlphaComponent(0.18)
        // We deliberately do NOT clear .font / .foregroundColor here. Clearing
        // them over conflict regions would strip the TreeSitter syntax styling
        // from LOCAL/REMOTE lines. The Coordinator's `lastShowBase` tracking in
        // `updateNSView` forces a full re-render whenever `showBase` toggles,
        // which is when stale BASE styling actually matters in practice.
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        let nsString = text as NSString
        let lineRanges = Self.computeLineRanges(in: nsString)
        for region in regions {
            if case .conflict(let block) = region {
                let lower = max(block.lineRangeInMerged.lowerBound, 0)
                let upper = min(block.lineRangeInMerged.upperBound, lineRanges.count - 1)
                guard upper >= lower, upper < lineRanges.count else { continue }
                let start = lineRanges[lower].location
                let end = NSMaxRange(lineRanges[upper])
                storage.addAttribute(.backgroundColor, value: highlight,
                                     range: NSRange(location: start, length: end - start))

                if showBase, block.base != nil {
                    applyBaseStyling(in: storage,
                                     fullText: nsString,
                                     lineRanges: lineRanges,
                                     conflictRange: lower ... upper,
                                     theme: theme)
                }
            }
        }
    }

    /// Walks the lines inside a conflict marker block and applies italic +
    /// muted-color attributes to the lines that fall between `||||||| ` and
    /// `=======` markers. Called only when `showBase == true`.
    private func applyBaseStyling(
        in storage: NSMutableAttributedString,
        fullText: NSString,
        lineRanges: [NSRange],
        conflictRange: ClosedRange<Int>,
        theme: Theme
    ) {
        var inBase = false
        let italic = CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize)
            .italicVariant()
        let muted = NSColor(theme.color("fg-dim"))
        for lineIdx in conflictRange {
            let lineRange = lineRanges[lineIdx]
            let lineText = fullText.substring(with: lineRange)
            if lineText.hasPrefix("||||||| ") {
                inBase = true
                continue
            }
            if lineText.hasPrefix("=======") {
                inBase = false
                continue
            }
            if inBase {
                storage.addAttribute(.font, value: italic, range: lineRange)
                storage.addAttribute(.foregroundColor, value: muted, range: lineRange)
            }
        }
    }

    /// NSRanges for each line (split on `\n`), preserving trailing-empty semantics.
    private static func computeLineRanges(in nsString: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = 0
        while index <= nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            if lineRange.length == 0 {
                ranges.append(NSRange(location: index, length: 0))
                break
            }
            ranges.append(lineRange)
            index = NSMaxRange(lineRange)
            if index >= nsString.length { break }
        }
        return ranges
    }
}

private extension NSFont {
    /// Returns the italic version of this font, falling back to self if the
    /// font has no italic face.
    func italicVariant() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.italic)
        )
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
