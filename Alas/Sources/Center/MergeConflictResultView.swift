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
            for marker in markerLineRanges {
                // `marker` includes the trailing newline; we don't want
                // to block an insertion at the exact end of the marker
                // line (which would push the marker down by inserting
                // before it on the next line). Strip the newline for
                // the intersection check.
                let body = marker.length > 0
                    ? NSRange(location: marker.location, length: marker.length - 1)
                    : marker
                if affectedCharRange.length == 0 {
                    // Insertion: block only when the cursor is strictly
                    // inside the marker body (not at its start or end).
                    if affectedCharRange.location > body.location,
                       affectedCharRange.location < NSMaxRange(body) {
                        return false
                    }
                } else if NSIntersectionRange(body, affectedCharRange).length > 0 {
                    return false
                }
                // Backspace into the marker line (selection at marker
                // start, deleting the previous newline) is also rejected
                // because deleting the newline would merge a content
                // line into the marker line.
                if affectedCharRange.length > 0,
                   affectedCharRange.location < marker.location,
                   NSMaxRange(affectedCharRange) > marker.location {
                    return false
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
            if line.hasPrefix("<<<<<<<") {
                state = .local
                blockStartLineIdx = idx
                lines.append(Line(range: range, kind: .markerBegin))
                markerLineRanges.append(range)
                continue
            }
            if state == .outside { continue }
            if line.hasPrefix("||||||| ") {
                state = .base
                lines.append(Line(range: range, kind: .markerBase))
                markerLineRanges.append(range)
                continue
            }
            if line.hasPrefix("=======") {
                state = .remote
                lines.append(Line(range: range, kind: .markerSeparator))
                markerLineRanges.append(range)
                continue
            }
            if line.hasPrefix(">>>>>>>") {
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
