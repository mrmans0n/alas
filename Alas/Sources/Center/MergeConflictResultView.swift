import AppKit
import SwiftUI

/// Editable RESULT column for the merge editor. Bound to the model's
/// `resultText`. Reuses `MergeConflictTextStorage` for syntax highlighting
/// and overlays per-hunk shading on conflict marker blocks so the user
/// can see at a glance which side each line belongs to (LOCAL / BASE /
/// REMOTE), and which lines are the markers themselves (non-editable).
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

        let textView = MergeConflictResultTextView()
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
        textView.textContainerInset = NSSize(width: 10, height: 6)
        textView.delegate = context.coordinator
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MergeConflictResultTextView else { return }
        // Re-render whenever text changed OR the showBase toggle changed since
        // last render (italic/muted attrs would otherwise persist after toggle-off).
        let current = textView.string
        let needsFullRender = current != text || context.coordinator.lastShowBase != showBase
        let classification = HunkClassification.compute(in: text)
        if needsFullRender {
            let attr = MergeConflictTextStorage.highlightedAttributedString(
                text: text,
                fileExtension: fileExtension,
                fontFamily: codeFontFamily,
                fontSize: codeFontSize,
                theme: theme
            )
            applyHunkShading(to: attr, classification: classification, theme: theme)
            textView.textStorage?.setAttributedString(attr)
            context.coordinator.lastShowBase = showBase
        } else {
            // Even when the string is unchanged, the conflict regions may have
            // shifted (a typed edit can resolve a marker). Re-apply shading.
            if let storage = textView.textStorage {
                applyHunkShading(to: storage, classification: classification, theme: theme)
            }
        }
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        textView.hunkBars = sideBars(for: classification, theme: theme)
        textView.markerLineRanges = classification.markerLineRanges
        context.coordinator.markerLineRanges = classification.markerLineRanges
        textView.needsDisplay = true

        // Scroll + select the current conflict when navigation lands on
        // a new ordinal OR when an accept removes a block and renumbers
        // (same ordinal points at a different block). The guard tuple
        // is (index, count); plain text edits don't change `count`, so
        // typing won't yank the user's cursor.
        let trigger = ReselectTrigger(index: currentConflictIndex, count: conflictCount)
        if trigger != context.coordinator.lastReselectTrigger {
            if let index = currentConflictIndex,
               let range = classification.conflictRange(at: index) {
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
        /// Marker line ranges from the most recent classification. Used by
        /// `shouldChangeTextIn:` to block edits that would touch a
        /// marker line.
        var markerLineRanges: [NSRange] = []

        init(_ text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }

        /// Blocks edits that would mutate a conflict marker line. The
        /// hunk content lines (between markers) stay fully editable —
        /// this is the user's working buffer. Marker lines themselves
        /// (`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>`) are structural;
        /// stray edits there silently break conflict-state parsing for
        /// Use LOCAL/REMOTE/BOTH and Mark resolved.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let storage = textView.string as NSString
            for marker in markerLineRanges {
                // `marker` includes the trailing newline when one
                // exists. We strip the newline so an insertion at the
                // exact end of the marker line (which would push the
                // marker down by inserting before it on the next line)
                // stays allowed. But when the buffer ends without a
                // trailing newline — common for files that never had
                // one — the final marker line has no newline to strip,
                // so we use the full range unchanged. Without this
                // check the last visible character of that final
                // marker (e.g. the last `>`) would fall outside the
                // protected range and could be edited or appended.
                let endsWithNewline =
                    marker.length > 0 &&
                    NSMaxRange(marker) <= storage.length &&
                    storage.character(at: NSMaxRange(marker) - 1) == 0x0A
                let body = endsWithNewline
                    ? NSRange(location: marker.location, length: marker.length - 1)
                    : marker
                if affectedCharRange.length == 0 {
                    // Insertion: block the entire closed range
                    // [body.location, NSMaxRange(body)] — anywhere on
                    // the marker line including the position right
                    // before its trailing newline. Without the inclusive
                    // upper bound, typing at end-of-marker-line would
                    // append text directly to the marker (e.g.
                    // `>>>>>>> feature` + 'x' → `>>>>>>> featurex`),
                    // corrupting it. Inserting at NSMaxRange(marker)
                    // (start of the next line) stays allowed.
                    if affectedCharRange.location >= body.location,
                       affectedCharRange.location <= NSMaxRange(body) {
                        return false
                    }
                } else {
                    // Deletion/replacement: protect the FULL marker
                    // range (including the trailing newline). Forward-
                    // delete at end of marker line or backspace at
                    // start of the line below both remove the trailing
                    // `\n` and merge the next content line into the
                    // marker — same corruption mode as editing the
                    // marker text itself.
                    if NSIntersectionRange(marker, affectedCharRange).length > 0 {
                        return false
                    }
                    // Backspace at start of marker line (selection
                    // ending exactly at marker.location) deletes the
                    // previous line's newline and merges the previous
                    // content line into the marker line. Same problem,
                    // different boundary.
                    if NSMaxRange(affectedCharRange) == marker.location {
                        return false
                    }
                }
            }
            return true
        }
    }

    /// Walks the marker classification and applies per-hunk background
    /// tints + italic/muted styling for BASE lines (when `showBase`).
    /// Does NOT clear .font / .foregroundColor outside of BASE lines so
    /// TreeSitter syntax styling on LOCAL/REMOTE content stays intact.
    private func applyHunkShading(
        to storage: NSMutableAttributedString,
        classification: HunkClassification,
        theme: Theme
    ) {
        storage.removeAttribute(.backgroundColor,
                                range: NSRange(location: 0, length: storage.length))
        let localTint = NSColor.systemGreen.withAlphaComponent(0.12)
        let remoteTint = NSColor.systemBlue.withAlphaComponent(0.12)
        let baseTint = NSColor(theme.color("fg-dim")).withAlphaComponent(0.10)
        let markerTint = NSColor(theme.color("warn")).withAlphaComponent(0.20)
        for line in classification.lines {
            let color: NSColor
            switch line.kind {
            case .markerBegin, .markerBase, .markerSeparator, .markerEnd:
                color = markerTint
            case .contentLocal:
                color = localTint
            case .contentBase:
                color = baseTint
            case .contentRemote:
                color = remoteTint
            }
            storage.addAttribute(.backgroundColor, value: color, range: line.range)
        }
        if showBase {
            let italic = CenterTypography
                .resolveCodeFont(family: codeFontFamily, size: codeFontSize)
                .italicVariant()
            let muted = NSColor(theme.color("fg-dim"))
            for line in classification.lines where line.kind == .contentBase {
                storage.addAttribute(.font, value: italic, range: line.range)
                storage.addAttribute(.foregroundColor, value: muted, range: line.range)
            }
        }
    }

    /// Pairs the line range of each hunk content line with the color of
    /// the side bar to draw alongside it. The NSTextView subclass uses
    /// these in `drawBackground(in:)` to paint a vertical stripe in the
    /// gutter so the side is identifiable even when the user scrolls
    /// past the markers.
    private func sideBars(
        for classification: HunkClassification,
        theme: Theme
    ) -> [MergeConflictResultTextView.HunkBar] {
        let localColor = NSColor.systemGreen.withAlphaComponent(0.85)
        let remoteColor = NSColor.systemBlue.withAlphaComponent(0.85)
        let baseColor = NSColor(theme.color("fg-dim")).withAlphaComponent(0.7)
        var bars: [MergeConflictResultTextView.HunkBar] = []
        for line in classification.lines {
            let color: NSColor?
            switch line.kind {
            case .contentLocal:        color = localColor
            case .contentRemote:       color = remoteColor
            case .contentBase:         color = showBase ? baseColor : nil
            case .markerBegin, .markerBase, .markerSeparator, .markerEnd:
                color = nil
            }
            if let color {
                bars.append(.init(range: line.range, color: color))
            }
        }
        return bars
    }
}

/// NSTextView subclass that paints a vertical color bar in the gutter
/// for each conflict-hunk line range, so the user can see which side
/// (LOCAL / BASE / REMOTE) a given line belongs to even when scrolled
/// past the markers themselves.
final class MergeConflictResultTextView: NSTextView {
    struct HunkBar {
        let range: NSRange
        let color: NSColor
    }

    var hunkBars: [HunkBar] = []
    /// Mirror of `Coordinator.markerLineRanges`, also stored on the
    /// view so `drawBackground` can flag the marker rows visually
    /// (subtle left indicator) without having to ask the delegate.
    var markerLineRanges: [NSRange] = []

    /// Width of the side bar in points. Fits inside the
    /// `textContainerInset.width` so it doesn't visually clip glyphs.
    private let barWidth: CGFloat = 3
    /// Inset from the view's left edge to the bar's left edge.
    private let barLeftInset: CGFloat = 3

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager,
              let textContainer
        else { return }
        let origin = textContainerOrigin
        for bar in hunkBars {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: bar.range,
                actualCharacterRange: nil
            )
            var boundingRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            boundingRect = boundingRect.offsetBy(dx: origin.x, dy: origin.y)
            let barRect = NSRect(
                x: barLeftInset,
                y: boundingRect.minY,
                width: barWidth,
                height: boundingRect.height
            )
            bar.color.setFill()
            barRect.fill()
        }
    }
}

/// Per-line classification of every line in the buffer relative to the
/// conflict-marker grammar. The view uses this to know where to apply
/// background tints, where to draw side bars, and which line ranges to
/// block from editing.
private struct HunkClassification {
    enum Kind {
        case markerBegin
        case markerBase
        case markerSeparator
        case markerEnd
        case contentLocal
        case contentBase
        case contentRemote
    }

    struct Line {
        let range: NSRange
        let kind: Kind
    }

    let lines: [Line]
    /// NSRanges for the conflict-block lines (markers + content) per
    /// unresolved conflict, in document order. Used by `conflictRange`
    /// to support prev/next navigation.
    let conflictBlocks: [NSRange]
    /// Just the marker-line NSRanges, used to block edits on those
    /// lines via `shouldChangeTextIn`.
    let markerLineRanges: [NSRange]

    func conflictRange(at ordinal: Int) -> NSRange? {
        guard ordinal >= 0, ordinal < conflictBlocks.count else { return nil }
        return conflictBlocks[ordinal]
    }

    static func compute(in text: String) -> HunkClassification {
        let nsString = text as NSString
        let lineRanges = computeLineRanges(in: nsString)
        var lines: [Line] = []
        var conflictBlocks: [NSRange] = []
        var markerLineRanges: [NSRange] = []
        // State machine across lines: scan for begin → optional base → separator → end.
        // When inside, every line is classified; outside, we don't emit a Line
        // (those lines have no tint).
        enum State { case outside, local, base, remote }
        var state = State.outside
        var blockStartLineIdx = 0
        for (idx, range) in lineRanges.enumerated() {
            let line = nsString.substring(with: range)
            // Match `ConflictMarkerParser` exactly: begin/base/end have
            // a trailing space + label; mid is the literal `=======`
            // (so a content line like "======= Section" doesn't get
            // misclassified as a separator). Strip the trailing newline
            // for the mid exact match because `line` includes it.
            let trimmed = line.hasSuffix("\n") ? String(line.dropLast()) : line
            // Only treat `<<<<<<< ` as a marker when we're OUTSIDE a
            // conflict. `ConflictMarkerParser` doesn't recurse, so a
            // line with that prefix appearing inside LOCAL/BASE/REMOTE
            // content (e.g. a docstring or test fixture about merge
            // markers) is content, not a marker. Recursing here would
            // misclassify those lines as non-editable AND corrupt
            // navigation by overwriting `blockStartLineIdx` mid-block.
            if state == .outside, line.hasPrefix("<<<<<<< ") {
                state = .local
                blockStartLineIdx = idx
                lines.append(Line(range: range, kind: .markerBegin))
                markerLineRanges.append(range)
                continue
            }
            if state == .outside { continue }
            // Match `ConflictMarkerParser`'s state restrictions:
            //  - baseMarker is only valid before the separator (i.e.
            //    while still in LOCAL). A `||||||| ` line that appears
            //    in REMOTE content is content, not a marker.
            //  - midMarker is only valid before REMOTE starts (in
            //    LOCAL or BASE). A `=======` line that appears in
            //    REMOTE content is content, not a marker.
            if state == .local, line.hasPrefix("||||||| ") {
                state = .base
                lines.append(Line(range: range, kind: .markerBase))
                markerLineRanges.append(range)
                continue
            }
            if (state == .local || state == .base), trimmed == "=======" {
                state = .remote
                lines.append(Line(range: range, kind: .markerSeparator))
                markerLineRanges.append(range)
                continue
            }
            if line.hasPrefix(">>>>>>> ") {
                lines.append(Line(range: range, kind: .markerEnd))
                markerLineRanges.append(range)
                let start = lineRanges[blockStartLineIdx].location
                let end = NSMaxRange(range)
                conflictBlocks.append(NSRange(location: start, length: end - start))
                state = .outside
                continue
            }
            switch state {
            case .local:   lines.append(Line(range: range, kind: .contentLocal))
            case .base:    lines.append(Line(range: range, kind: .contentBase))
            case .remote:  lines.append(Line(range: range, kind: .contentRemote))
            case .outside: break // unreachable — guarded above
            }
        }
        return HunkClassification(
            lines: lines,
            conflictBlocks: conflictBlocks,
            markerLineRanges: markerLineRanges
        )
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
