import AppKit
import SwiftUI

/// LOCAL or REMOTE pane in the 3-way merge editor. Renders that side's
/// version of the file with syntax highlighting, a full-width band per
/// conflict hunk, and intra-line change marks against the other side.
///
/// Read-only — users edit only in `MergeResultPane`. Scroll position
/// is driven externally by `MergeScrollCoordinator`.
struct MergeSidePane: NSViewRepresentable {
    enum Side: Equatable {
        case local, remote
    }

    let side: Side
    let rows: [MergeRegionVisualLayout.VisualRow]
    let bands: [MergeBand]
    let lineSpans: [[MergeSyntaxHighlighter.LineSpan]]
    let wordMarks: [Int: MergePaneText.WordMark]
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let coordinator: MergeScrollCoordinator
    @Environment(\.theme) var theme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MergeRulerScrollView()
        scroll.clipsToBounds = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = MergeCodeTextView.make(editable: false)
        scroll.documentView = textView
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = MergeSourceLineNumberRulerView(scrollView: scroll, theme: theme)
        context.coordinator.scrollBridge = MergePaneScrollBridge(
            scroll: scroll,
            source: side == .local ? .local : .remote,
            coordinator: coordinator
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MergeCodeTextView else { return }
        let metrics = MergePaneMetrics(fontFamily: codeFontFamily, fontSize: codeFontSize)
        let palette = MergePalette(theme: theme)
        // Scroll-only updates re-run updateNSView. Skip the O(file size)
        // attributed-string rebuild when nothing that affects text changed.
        let key = Coordinator.CacheKey(
            rows: rows,
            lineSpans: lineSpans,
            wordMarks: wordMarks,
            metrics: metrics,
            theme: theme
        )
        if context.coordinator.lastKey != key, let storage = textView.textStorage {
            let rendered = MergePaneText.render(rows: rows, endsWithNewline: true)
            let attributed = MergePaneText.attributedString(
                rendered: rendered,
                lineSpans: lineSpans,
                wordMarks: wordMarks,
                metrics: metrics,
                theme: theme,
                palette: palette
            )
            if storage.string == rendered.text {
                MergePaneText.applyAttributes(attributed, to: storage)
            } else {
                storage.setAttributedString(attributed)
            }
            context.coordinator.lastKey = key
        }
        textView.bands = bands
        textView.palette = palette
        textView.rowHeight = metrics.rowHeight
        textView.backgroundColor = palette.background
        textView.selectedTextAttributes = [.backgroundColor: EditorTheme(theme: theme).selection]
        if let ruler = scroll.verticalRulerView as? MergeSourceLineNumberRulerView {
            let thickness = ruler.ruleThickness
            ruler.update(rows: rows, bands: bands, rowHeight: metrics.rowHeight, theme: theme, palette: palette)
            if ruler.ruleThickness != thickness { scroll.tile() }
        }
        coordinator.rowHeight = metrics.rowHeight
        coordinator.contentTopInset = MergePaneMetrics.contentInset.height
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject {
        struct CacheKey: Equatable {
            let rows: [MergeRegionVisualLayout.VisualRow]
            let lineSpans: [[MergeSyntaxHighlighter.LineSpan]]
            let wordMarks: [Int: MergePaneText.WordMark]
            let metrics: MergePaneMetrics
            let theme: Theme
        }
        var lastKey: CacheKey?
        fileprivate var scrollBridge: MergePaneScrollBridge?
    }
}

/// Current AppKit lays the clip view out underneath a vertical ruler, which
/// hides the start of every line. Shift the clip view past the ruler, as
/// `DiffPaneTextDocumentView` does.
@MainActor
private final class MergeRulerScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView else { return }
        let rulerWidth = ruler.ruleThickness
        var clipFrame = contentView.frame
        guard clipFrame.minX < rulerWidth - 0.5 else { return }
        clipFrame.origin.x = rulerWidth
        clipFrame.size.width = max(bounds.width - rulerWidth, 1)
        contentView.frame = clipFrame
        ruler.frame = NSRect(x: 0, y: clipFrame.minY, width: rulerWidth, height: clipFrame.height)
    }
}

@MainActor
private final class MergeSourceLineNumberRulerView: NSRulerView {
    private var rows: [MergeRegionVisualLayout.VisualRow] = []
    private var bands: [MergeBand] = []
    private var theme: Theme
    private var palette: MergePalette
    private var rowHeight: CGFloat = 16
    private var boundsObserver: NSObjectProtocol?

    private let minimumThickness: CGFloat = 34
    private let horizontalPadding: CGFloat = 8

    init(scrollView: NSScrollView, theme: Theme) {
        self.theme = theme
        self.palette = MergePalette(theme: theme)
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = minimumThickness
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        observe(scrollView: scrollView)
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    func update(
        rows: [MergeRegionVisualLayout.VisualRow],
        bands: [MergeBand],
        rowHeight: CGFloat,
        theme: Theme,
        palette: MergePalette
    ) {
        guard rows != self.rows || bands != self.bands || rowHeight != self.rowHeight
            || theme != self.theme || palette != self.palette
        else { return }
        self.rows = rows
        self.bands = bands
        self.rowHeight = rowHeight
        self.theme = theme
        self.palette = palette
        updateThickness()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        palette.gutterBackground.setFill()
        bounds.fill()

        guard let scrollView, rowHeight > 0 else { return }
        let visible = scrollView.contentView.bounds
        let inset = MergePaneMetrics.contentInset.height
        let rowHeight = rowHeight
        MergeBandPainter.draw(
            bands,
            palette: palette,
            rowTop: { inset + CGFloat($0) * rowHeight - visible.minY },
            rowHeight: rowHeight,
            minX: bounds.minX,
            maxX: bounds.maxX,
            dirtyRect: bounds,
            accentBar: true
        )

        guard !rows.isEmpty else { return }
        let firstRow = max(0, Int(floor((visible.minY - inset) / rowHeight)))
        let lastRow = min(rows.count - 1, Int(ceil((visible.maxY - inset) / rowHeight)))
        guard firstRow <= lastRow else { return }

        let attributes = labelAttributes()
        let textHeight = ("8" as NSString).size(withAttributes: attributes).height
        for index in firstRow...lastRow {
            guard let number = rows[index].sourceLineNumber else { continue }
            let y = inset + CGFloat(index) * rowHeight - visible.minY
            let drawRect = NSRect(
                x: 0,
                y: y + max((rowHeight - textHeight) / 2, 0),
                width: ruleThickness - horizontalPadding,
                height: textHeight
            )
            NSString(string: String(number)).draw(in: drawRect, withAttributes: attributes)
        }
    }

    private func observe(scrollView: NSScrollView) {
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addMainActorObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        ) { [weak self] in
            self?.needsDisplay = true
        }
    }

    private func updateThickness() {
        let maxLine = rows.compactMap(\.sourceLineNumber).max() ?? 1
        let digits = String(maxLine).count
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: labelAttributes()).width)
        ruleThickness = max(minimumThickness, width + horizontalPadding * 2)
    }

    private func labelAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: palette.lineNumber,
            .paragraphStyle: paragraph,
        ]
    }

    isolated deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }
}
