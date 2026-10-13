import AppKit
import CoreText

/// A split or stacked hunk drawn with CoreText in one view: no text views,
/// scroll views, or rulers. A stacked hunk is one full-width pane, held as the
/// new side. `ALAS_DIFF_CORETEXT=0` falls back to the text-view rows.
@MainActor
final class DiffSplitCoreTextRowView: NSView, AppKitDiffRowView {
    enum Side { case old, new }

    /// Which edges of the review's file card this row carries.
    struct CardEdges: Equatable {
        var top = false
        var bottom = false
        static let middle = CardEdges()
    }

    /// The hunk card around the code: its header, and how it joins
    /// neighbouring hunks.
    struct HunkChrome {
        struct Action {
            let symbol: String
            let tooltip: String
            let perform: @MainActor () -> Void
        }

        var header: String
        var headerFont: NSFont
        var fusion: DiffPaneHunkFusionState
        var actions: [Action] = []
    }

    /// Commenting on lines: what the gutter may select, and the comment
    /// whose lines are highlighted.
    struct ReviewLines {
        var allowsSelection = true
        var activeHighlight: DiffReviewCommentHighlight?
        var onSelect: @MainActor (DiffReviewLineAnchor) -> Void = { _ in }
    }

    /// Selected code on one side, as UTF-16 offsets into its rows' lines.
    /// Like the text-view panes, a selection stays on one side.
    struct TextSelection: Equatable {
        struct Position: Comparable {
            var row: Int
            var index: Int

            static func < (lhs: Position, rhs: Position) -> Bool {
                (lhs.row, lhs.index) < (rhs.row, rhs.index)
            }
        }

        let side: Side
        var anchor: Position
        var focus: Position

        var start: Position { min(anchor, focus) }
        var end: Position { max(anchor, focus) }
        var isEmpty: Bool { anchor == focus }

        /// The selected offsets within `row`, whose line is `length` long,
        /// and whether the selection runs on past the line's end.
        func span(inRow row: Int, length: Int) -> (range: Range<Int>, continues: Bool)? {
            guard row >= start.row, row <= end.row else { return nil }
            let lower = row == start.row ? min(start.index, length) : 0
            let upper = row == end.row ? min(end.index, length) : length
            return (lower..<max(lower, upper), row < end.row)
        }

        /// The selected text, rows joined by newlines as the panes' documents are.
        func text(in lines: [String]) -> String {
            guard !isEmpty else { return "" }
            return (start.row...end.row).compactMap { row -> String? in
                guard lines.indices.contains(row) else { return nil }
                let line = lines[row] as NSString
                guard let span = span(inRow: row, length: line.length) else { return nil }
                return line.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
            }.joined(separator: "\n")
        }
    }

    /// A gutter drag in progress, in rows of one side.
    struct GutterSelection: Equatable {
        let side: Side
        let start: Int
        var current: Int
    }

    static let verticalInset: CGFloat = 8
    static let textInset: CGFloat = 10
    static let headerVerticalPadding: CGFloat = 8
    static let headerHorizontalPadding: CGFloat = 13
    static let headerButtonSize = NSSize(width: 22, height: 20)
    static let headerButtonSpacing: CGFloat = 8
    static let hunkCornerRadius: CGFloat = 7
    /// How far an expansion pill reaches past its text, as `expandPillRect` pads it.
    static let expansionPillPadding: CGFloat = 12
    static let cardCornerRadius: CGFloat = 8

    var representedRowID: String?
    var onIntrinsicSizeInvalidated: ((String) -> Void)?
    private(set) var lastMeasuredWidth: CGFloat?
    private(set) var lineHeight: CGFloat = 16
    var cardEdges = CardEdges.middle {
        didSet { if cardEdges != oldValue { invalidateTiles() } }
    }

    /// A line number, measured once.
    private struct Label {
        let line: CTLine
        let width: CGFloat
        init(_ line: CTLine) {
            self.line = line
            width = CTLineGetTypographicBounds(line, nil, nil, nil)
        }
    }

    private struct SideLines {
        var code: [CTLine] = []
        /// Source of `code`, kept to break lines when wrapping.
        var attributed: [NSAttributedString] = []
        var codeStrings: [String] = []
        var labels: [Label?] = []
        var tones: [DiffPaneLineTone] = []
        var metadata: [DiffPaneTextDocumentBuilder.LineMetadata] = []
        /// Lines whose paragraph style sets their own height, such as the
        /// context-expansion rows, keyed by line.
        var customMetrics: [Int: TextKitMetrics] = [:]
        /// First-line head indents, keyed by line.
        var indents: [Int: CGFloat] = [:]
        var widest: CGFloat = 0
        /// Line-number gutter width, as `DiffPaneLineNumberRulerView` sizes it.
        var gutterWidth: CGFloat = 42
    }

    private var old = SideLines()
    private var new = SideLines()
    private(set) var isStacked = false
    private(set) var wraps = false
    private var review = ReviewLines()
    private(set) var textSelection: TextSelection? {
        didSet {
            guard textSelection != oldValue else { return }
            // Only the rows either selection covers, so a drag does not
            // redraw every tile of a long hunk on each event.
            let rows = [oldValue, textSelection].compactMap { $0 }.flatMap { [$0.start.row, $0.end.row] }
            guard let first = rows.min(), let last = rows.max() else { return }
            let tops = layout(forWidth: bounds.width).tops
            guard tops.indices.contains(first), tops.indices.contains(min(last + 1, tops.count - 1)) else { return invalidateTiles() }
            invalidateTiles(NSRect(x: 0, y: codeTop + tops[first], width: bounds.width, height: tops[min(last + 1, tops.count - 1)] - tops[first]))
        }
    }
    private var isPointerCovered = false
    private var isSelectingText = false
    private(set) var gutterSelection: GutterSelection? {
        didSet { if gutterSelection != oldValue { invalidateTiles() } }
    }
    private var hoveredGutterRow: (side: Side, row: Int)? {
        didSet { if hoveredGutterRow?.side != oldValue?.side || hoveredGutterRow?.row != oldValue?.row { invalidateTiles() } }
    }
    /// Row geometry for the last width laid out.
    private var rowLayout: RowLayout?
    private var codeFont: NSFont?
    private var onContextExpansion: DiffContextExpansionHandler = { _, _, _ in }

    /// An expansion pill: one action on one row of one side.
    struct ExpansionTarget: Equatable {
        let side: Side
        let row: Int
        let action: DiffPaneTextDocumentBuilder.ContextExpansionAction
    }

    private var hoveredExpansion: ExpansionTarget? {
        didSet { if hoveredExpansion != oldValue { invalidateTiles() } }
    }
    private var pressedExpansion: ExpansionTarget? {
        didSet { if pressedExpansion != oldValue { invalidateTiles() } }
    }
    private var armedExpansion: (target: ExpansionTarget, optionKey: Bool)?
    private var didSetPointingHand = false
    private var palette: Palette?
    private var theme: Theme?
    var hoverHandler: ((NSPoint) -> Void)?
    var commandClickHandler: ((NSPoint) -> Void)?
    var flagsChangedHandler: ((NSEvent) -> Void)?
    var mouseExitedHandler: (() -> Void)?
    private var lspController: DiffPaneLSPController?
    /// The new side's code, which LSP offsets index.
    private var lspDocument: NSString = ""
    /// The documents the lines were built from. The same documents mean the
    /// same lines, so overlays (highlights, chrome) can change without a
    /// rebuild or a horizontal-scroll reset.
    private var contentSources: [NSAttributedString] = []
    private var chevronImages: [String: NSImage] = [:]
    private var truncatedHeader: (width: CGFloat, line: CTLine)?
    /// Distance from a line's top to its baseline, as TextKit places it.
    private var baselineOffset: CGFloat = 12
    private var chrome: HunkChrome?
    private var headerLine: CTLine?
    private var headerButtons: [NSButton] = []
    private var headerActions: [@MainActor () -> Void] = []
    private(set) var horizontalScroll = DiffSplitHorizontalScroll()
    private var scrollGesture = DiffSplitScrollGesture()
    private let oldScroller = NSScroller(frame: .zero)
    private let newScroller = NSScroller(frame: .zero)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for scroller in [oldScroller, newScroller] {
            scroller.scrollerStyle = .overlay
            scroller.controlSize = .small
            scroller.target = self
            scroller.action = #selector(scrollerDidMove(_:))
            scroller.isHidden = true
            addSubview(scroller)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTileScale()
        observeClipView()
        // Parked rows leave the window; their hover panels must not linger.
        if window == nil { lspController?.notifyScrolled() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeClipView()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateTileScale()
    }

    // MARK: - Content

    func configure(
        result: DiffPaneTextDocumentBuilder.SplitResult,
        font: NSFont,
        theme: Theme,
        chrome: HunkChrome? = nil,
        wraps: Bool = false,
        review: ReviewLines = ReviewLines(),
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in },
        lspContext: DiffPaneLSPContext? = nil
    ) {
        let sources = [result.oldCode.attributedString, result.oldGutter, result.newCode.attributedString, result.newGutter]
        lspDocument = result.newCode.attributedString.string as NSString
        defer { updateLSP(lspContext, theme: theme) }
        let changed = contentChanged(sources: sources, stacked: false, wraps: wraps, font: font)
        self.onContextExpansion = onContextExpansion
        self.review = review
        let palette = Palette(theme: theme)
        if changed {
            isStacked = false
            self.wraps = wraps
            old = Self.lines(code: result.oldCode, gutter: result.oldGutter, font: font, palette: palette)
            new = Self.lines(code: result.newCode, gutter: result.newGutter, font: font, palette: palette)
        }
        apply(palette: palette, font: font, chrome: chrome, contentChanged: changed)
    }

    func configure(
        stacked result: DiffPaneTextDocumentBuilder.StackedResult,
        font: NSFont,
        theme: Theme,
        chrome: HunkChrome? = nil,
        wraps: Bool = false,
        review: ReviewLines = ReviewLines(),
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in },
        lspContext: DiffPaneLSPContext? = nil
    ) {
        let changed = contentChanged(sources: [result.code.attributedString, result.gutter], stacked: true, wraps: wraps, font: font)
        lspDocument = result.code.attributedString.string as NSString
        defer { updateLSP(lspContext, theme: theme) }
        self.onContextExpansion = onContextExpansion
        self.review = review
        let palette = Palette(theme: theme)
        if changed {
            isStacked = true
            self.wraps = wraps
            old = SideLines()
            new = Self.lines(code: result.code, gutter: result.gutter, font: font, palette: palette)
        }
        apply(palette: palette, font: font, chrome: chrome, contentChanged: changed)
    }

    /// Whether these documents differ from the ones on screen. The cache
    /// hands back the same instances for unchanged content, and the theme and
    /// font are part of its key, so identity is enough.
    private func contentChanged(sources: [NSAttributedString], stacked: Bool, wraps: Bool, font: NSFont) -> Bool {
        let same = sources.count == contentSources.count && zip(sources, contentSources).allSatisfy { $0 === $1 }
            && stacked == isStacked && wraps == self.wraps && font == codeFont
        contentSources = sources
        return !same
    }

    private func apply(palette: Palette, font: NSFont, chrome: HunkChrome?, contentChanged: Bool) {
        self.palette = palette
        chevronImages = [:]
        if contentChanged {
            codeFont = font
            hoveredExpansion = nil
            pressedExpansion = nil
            armedExpansion = nil
            if didSetPointingHand {
                NSCursor.arrow.set()
                didSetPointingHand = false
            }
            let metrics = Self.textKitMetrics(for: font)
            lineHeight = metrics.lineHeight
            baselineOffset = metrics.baselineOffset
            rowLayout = nil
            gutterSelection = nil
            textSelection = nil
            hoveredGutterRow = nil
            // Wrapped lines fit their pane, so there is nothing to scroll sideways.
            horizontalScroll.oldContentWidth = isStacked || wraps ? 0 : old.widest + 2 * Self.textInset
            horizontalScroll.newContentWidth = wraps ? 0 : new.widest + 2 * Self.textInset
            // New content starts at the leading edge, as the panes do today.
            horizontalScroll.resetToLeading()
        }
        applyChrome(chrome, palette: palette)
        updateViewportWidths()
        layoutSubviewsForContent()
        invalidateTiles()
        if contentChanged { codeElements = [:] }
    }

    func widestLineWidth(side: Side) -> CGFloat {
        side == .old ? old.widest : new.widest
    }

    func cachedLineStringForTesting(side: Side, line: Int) -> String? {
        let lines = side == .old ? old : new
        return lines.codeStrings.indices.contains(line) ? lines.codeStrings[line] : nil
    }

    func headerButtonsForTesting() -> [NSButton] { headerButtons }

    private var lineCount: Int { max(old.code.count, new.code.count) }

    /// Height of the hunk header strip, or 0 without chrome.
    var headerHeight: CGFloat {
        guard let chrome else { return 0 }
        let font = chrome.headerFont
        return ceil(font.ascender - font.descender + font.leading) + 2 * Self.headerVerticalPadding
    }

    private var bottomPadding: CGFloat { chrome?.fusion.bottomPadding ?? 0 }

    /// Top of the first code line.
    private var codeTop: CGFloat { headerHeight + Self.verticalInset }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        lastMeasuredWidth = width
        let rows = layout(forWidth: width).tops.last ?? 0
        return headerHeight + rows + 2 * Self.verticalInset + bottomPadding
    }

    func attach(to documentView: NSView) {
        documentView.addSubview(self)
    }

    func suppressNextLayoutForStableScroll() {}

    /// The rows (logical lines) that intersect `rect`.
    func visibleLineRange(in rect: NSRect) -> Range<Int> {
        guard lineCount > 0 else { return 0..<0 }
        return Self.visibleRows(from: rect.minY - codeTop, to: rect.maxY - codeTop, rowTops: layout(forWidth: bounds.width).tops)
    }

    /// The rows a span covers, in offsets below the first code line,
    /// including rows it only partly covers.
    static func visibleRows(from minY: CGFloat, to maxY: CGFloat, rowTops: [CGFloat]) -> Range<Int> {
        guard rowTops.count > 1, maxY > 0, minY < rowTops[rowTops.count - 1] else { return 0..<0 }
        let first = row(containing: minY, rowTops: rowTops)
        let last = row(containing: maxY - 0.001, rowTops: rowTops) + 1
        return first < last ? first..<last : first..<first
    }

    // MARK: - Row geometry

    private struct RowLayout {
        let width: CGFloat
        /// Each row's visual lines when wrapping, per side.
        let old: [[CTLine]]?
        let new: [[CTLine]]?
        /// Each row's top below the first code line; one extra entry holds
        /// the total height.
        let tops: [CGFloat]
    }

    /// Where each row starts when a row is as tall as its taller side, so
    /// old and new lines stay level. The last entry is the total height.
    static func rowTops(oldHeights: [CGFloat], newHeights: [CGFloat], minimum: CGFloat) -> [CGFloat] {
        var tops: [CGFloat] = [0]
        tops.reserveCapacity(max(oldHeights.count, newHeights.count) + 1)
        for index in 0..<max(oldHeights.count, newHeights.count) {
            let old = oldHeights.indices.contains(index) ? oldHeights[index] : 0
            let new = newHeights.indices.contains(index) ? newHeights[index] : 0
            tops.append(tops[tops.count - 1] + max(minimum, old, new))
        }
        return tops
    }

    /// The row whose span contains `offset` below the first code line,
    /// clamped to the first and last rows.
    static func row(containing offset: CGFloat, rowTops: [CGFloat]) -> Int {
        var low = 0, high = max(0, rowTops.count - 2)
        while low < high {
            let mid = (low + high + 1) / 2
            if rowTops[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func layout(forWidth width: CGFloat) -> RowLayout {
        // Unwrapped rows do not depend on the width.
        if let rowLayout, !wraps || rowLayout.width == width { return rowLayout }
        var oldLines: [[CTLine]]?
        var newLines: [[CTLine]]?
        if wraps {
            let oldWidth = Self.codeColumn(.old, containerWidth: width, stacked: isStacked, gutter: old.gutterWidth).width - 2 * Self.textInset
            let newWidth = Self.codeColumn(.new, containerWidth: width, stacked: isStacked, gutter: new.gutterWidth).width - 2 * Self.textInset
            oldLines = isStacked ? [] : wrappedLines(old, width: oldWidth)
            newLines = wrappedLines(new, width: newWidth)
        }
        let layout = RowLayout(
            width: width, old: oldLines, new: newLines,
            tops: Self.rowTops(
                oldHeights: heights(old, wrapped: oldLines), newHeights: heights(new, wrapped: newLines), minimum: lineHeight
            )
        )
        rowLayout = layout
        return layout
    }

    private func wrappedLines(_ side: SideLines, width: CGFloat) -> [[CTLine]] {
        side.attributed.indices.map { index in
            // Rows with their own metrics (expansion rows) clip instead of wrapping.
            side.customMetrics[index] == nil ? Self.wrapped(side.attributed[index], width: width) : [side.code[index]]
        }
    }

    private func heights(_ side: SideLines, wrapped: [[CTLine]]?) -> [CGFloat] {
        side.code.indices.map { index in
            let height = side.customMetrics[index]?.lineHeight ?? lineHeight
            return height * CGFloat(wrapped?[index].count ?? 1)
        }
    }

    /// Breaks `line` at word boundaries to fit `width`, as TextKit's default
    /// paragraph style does.
    static func wrapped(_ line: NSAttributedString, width: CGFloat) -> [CTLine] {
        let typesetter = CTTypesetterCreateWithAttributedString(line)
        guard line.length > 0, width > 1 else { return [CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: line.length))] }
        var lines: [CTLine] = []
        var start = 0
        while start < line.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    // MARK: - Chrome

    private func applyChrome(_ chrome: HunkChrome?, palette: Palette) {
        self.chrome = chrome
        truncatedHeader = nil
        headerLine = chrome.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0.header, attributes: [
                .font: $0.headerFont,
                .foregroundColor: palette.fgMuted,
            ]))
        }
        let actions = chrome?.actions ?? []
        headerActions = actions.map(\.perform)
        while headerButtons.count > actions.count {
            headerButtons.removeLast().removeFromSuperview()
        }
        while headerButtons.count < actions.count {
            let button = NSButton(title: "", target: self, action: #selector(headerButtonPressed(_:)))
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            addSubview(button)
            headerButtons.append(button)
        }
        for (index, action) in actions.enumerated() {
            let button = headerButtons[index]
            button.tag = index
            button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.tooltip)
            button.toolTip = action.tooltip
            button.setAccessibilityLabel(action.tooltip)
        }
    }

    @objc private func headerButtonPressed(_ sender: NSButton) {
        guard headerActions.indices.contains(sender.tag) else { return }
        headerActions[sender.tag]()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        updateViewportWidths()
        layoutSubviewsForContent()
    }

    /// The scroller sets frames directly after measuring, without a layout
    /// pass, so a resize redraws and re-lays out here.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        updateViewportWidths()
        layoutSubviewsForContent()
        layoutTiles()
        invalidateTiles()
    }

    private func layoutSubviewsForContent() {
        let size = Self.headerButtonSize
        var x = bounds.maxX - Self.headerHorizontalPadding - size.width
        for button in headerButtons.reversed() {
            button.frame = NSRect(x: x, y: (headerHeight - size.height) / 2, width: size.width, height: size.height)
            x -= size.width + Self.headerButtonSpacing
        }
        layoutScrollers()
    }

    private func updateViewportWidths() {
        horizontalScroll.setViewportWidths(
            old: Self.codeColumn(.old, containerWidth: bounds.width, stacked: isStacked, gutter: old.gutterWidth).width,
            new: Self.codeColumn(.new, containerWidth: bounds.width, stacked: isStacked, gutter: new.gutterWidth).width
        )
    }

    /// The column `side` draws in: a split half, or the full width for the
    /// new side of a stacked hunk.
    private func pane(_ side: Side, width: CGFloat? = nil) -> NSRect {
        let column = Self.paneColumn(side, containerWidth: width ?? bounds.width, stacked: isStacked)
        return NSRect(x: column.minX, y: 0, width: column.width, height: bounds.height)
    }

    /// The x-span `side` draws in: split halves as the text-view panes use,
    /// or the full width for the new side of a stacked hunk.
    static func paneColumn(_ side: Side, containerWidth: CGFloat, stacked: Bool) -> (minX: CGFloat, width: CGFloat) {
        if stacked { return side == .new ? (0, containerWidth) : (0, 0) }
        let frames = DiffPaneSplitGeometry.frames(containerWidth: containerWidth)
        let pane = side == .old ? frames.oldPane : frames.newPane
        return (pane.minX, pane.width)
    }

    /// The x-span of `side`'s code, right of its line-number gutter. This is
    /// the viewport its lines scroll through sideways.
    static func codeColumn(_ side: Side, containerWidth: CGFloat, stacked: Bool, gutter: CGFloat) -> (minX: CGFloat, width: CGFloat) {
        let pane = paneColumn(side, containerWidth: containerWidth, stacked: stacked)
        guard pane.width > 0 else { return (0, 0) }
        return (pane.minX + gutter, max(0, pane.width - gutter))
    }

    func side(at point: NSPoint) -> Side {
        if isStacked { return .new }
        return point.x < DiffPaneSplitGeometry.frames(containerWidth: bounds.width).divider.minX ? .old : .new
    }

    /// The code area of `side`, which scrolls; the gutter beside it does not.
    private func codeRect(_ side: Side) -> NSRect {
        let column = Self.codeColumn(side, containerWidth: bounds.width, stacked: isStacked, gutter: lines(side).gutterWidth)
        guard column.width > 0 else { return .zero }
        return NSRect(x: column.minX, y: headerHeight, width: column.width, height: max(0, bounds.height - headerHeight - bottomPadding))
    }

    // MARK: - Review line selection

    /// The side and row whose line-number gutter contains `point`.
    func gutterRow(at point: NSPoint) -> (side: Side, row: Int)? {
        let side = side(at: point)
        let pane = pane(side)
        let gutter = side == .old ? old.gutterWidth : new.gutterWidth
        guard point.x >= pane.minX, point.x < pane.minX + gutter, let row = row(at: point.y) else { return nil }
        return (side, row)
    }

    private func row(at y: CGFloat) -> Int? {
        let tops = layout(forWidth: bounds.width).tops
        guard lineCount > 0, y >= codeTop, y < codeTop + (tops.last ?? 0) else { return nil }
        return Self.row(containing: y - codeTop, rowTops: tops)
    }

    private func lines(_ side: Side) -> SideLines { side == .old ? old : new }

    private func rowCenterY(_ row: Int) -> CGFloat {
        let tops = layout(forWidth: bounds.width).tops
        return codeTop + (tops[row] + tops[row + 1]) / 2
    }

    private func isCommentable(side: Side, row: Int) -> Bool {
        review.allowsSelection && lines(side).metadata.reviewLineAnchor(fromRow: row, toRow: row) != nil
    }

    var allowsReviewLineSelection: Bool { review.allowsSelection }

    /// Rows a gutter press could comment on, old side first, as the rulers
    /// list them.
    func commentableRowsForTesting() -> [(side: Side, row: Int)] {
        (isStacked ? [Side.new] : [.old, .new]).flatMap { side in
            lines(side).metadata.indices.filter { isCommentable(side: side, row: $0) }.map { (side, $0) }
        }
    }

    func selectReviewLineForTesting(side: Side, row: Int) {
        if let anchor = lines(side).metadata.reviewLineAnchor(fromRow: row, toRow: row) {
            review.onSelect(anchor)
        }
    }

    /// Starts a gutter drag; returns false when `point` is not on a gutter row.
    func beginGutterSelection(at point: NSPoint) -> Bool {
        guard review.allowsSelection, let hit = gutterRow(at: point) else { return false }
        gutterSelection = GutterSelection(side: hit.side, start: hit.row, current: hit.row)
        return true
    }

    /// Extends the drag to the row level with `point`, staying on its side.
    func extendGutterSelection(to point: NSPoint) {
        guard var selection = gutterSelection else { return }
        let last = lines(selection.side).metadata.count - 1
        guard last >= 0 else { return }
        if let row = row(at: point.y) {
            selection.current = min(row, last)
        } else {
            selection.current = point.y < codeTop ? 0 : last
        }
        gutterSelection = selection
    }

    /// Ends the drag, reporting the selected lines when they form an anchor.
    func endGutterSelection() {
        guard let selection = gutterSelection else { return }
        gutterSelection = nil
        if let anchor = lines(selection.side).metadata.reviewLineAnchor(fromRow: selection.start, toRow: selection.current) {
            review.onSelect(anchor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let optionKey = event.modifierFlags.contains(.option)
        if expandFromGutter(at: point, optionKey: optionKey) { return }
        if let target = expansionTarget(at: point) {
            armedExpansion = (target, optionKey)
            pressedExpansion = target
            return
        }
        if event.modifierFlags.contains(.command), let commandClickHandler, codeRect(.new).contains(point) {
            commandClickHandler(point)
            return
        }
        if beginGutterSelection(at: point) { return }
        if let hit = textHit(at: point) {
            window?.makeFirstResponder(self)
            beginTextSelection(side: hit.side, at: hit.position, point: point, clickCount: event.clickCount, extending: event.modifierFlags.contains(.shift))
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let armed = armedExpansion {
            pressedExpansion = expansionTarget(at: point) == armed.target ? armed.target : nil
            return
        }
        if isSelectingText, let selection = textSelection {
            if let position = textPosition(at: point, side: selection.side) {
                textSelection?.focus = position
            }
            autoscroll(with: event)
            return
        }
        guard gutterSelection != nil else { return super.mouseDragged(with: event) }
        extendGutterSelection(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        if let armed = armedExpansion {
            armedExpansion = nil
            pressedExpansion = nil
            if expansionTarget(at: convert(event.locationInWindow, from: nil)) == armed.target {
                armed.target.action.invoke(optionKey: armed.optionKey, handler: onContextExpansion)
            }
            return
        }
        if isSelectingText {
            isSelectingText = false
            return
        }
        guard gutterSelection != nil else { return super.mouseUp(with: event) }
        endGutterSelection()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self
            ))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Tracking areas still fire under overlays (launcher, palettes); a
        // covered move behaves like leaving the view, once.
        guard isTopmostHitTarget(atWindowLocation: event.locationInWindow) else {
            if !isPointerCovered {
                isPointerCovered = true
                clearPointerHover()
            }
            return
        }
        isPointerCovered = false
        let point = convert(event.locationInWindow, from: nil)
        // A visible scroller over the code is its own target: no hover behind it.
        if [oldScroller, newScroller].contains(where: { !$0.isHidden && $0.frame.contains(point) }) {
            clearPointerHover()
            return
        }
        let hit = gutterRow(at: point)
        hoveredGutterRow = hit.flatMap { isCommentable(side: $0.side, row: $0.row) ? $0 : nil }
        hoveredExpansion = expansionTarget(at: point)
        hoverHandler?(point)
        // Cursors are set here rather than through cursor rects: rects on
        // every mounted row make AppKit recompute them each display cycle.
        if hoveredExpansion != nil {
            NSCursor.pointingHand.set()
            didSetPointingHand = true
        } else if textHit(at: point) != nil {
            NSCursor.iBeam.set()
            didSetPointingHand = true
        } else if didSetPointingHand {
            NSCursor.arrow.set()
            didSetPointingHand = false
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        flagsChangedHandler?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearPointerHover()
    }

    private func clearPointerHover() {
        mouseExitedHandler?()
        hoveredGutterRow = nil
        hoveredExpansion = nil
        if didSetPointingHand {
            NSCursor.arrow.set()
            didSetPointingHand = false
        }
    }

    // MARK: - Text selection

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // The selection's color depends on focus.
        if let textSelection, !textSelection.isEmpty { invalidateTiles() }
        return super.becomeFirstResponder()
    }

    /// The selection stays, drawn inactive, as a text view keeps it.
    override func resignFirstResponder() -> Bool {
        if let textSelection, !textSelection.isEmpty { invalidateTiles() }
        return super.resignFirstResponder()
    }

    /// The side, row and offset under `point`, or nil outside the code columns.
    func textHit(at point: NSPoint) -> (side: Side, position: TextSelection.Position)? {
        let side = side(at: point)
        guard codeRect(side).contains(point), let row = row(at: point.y), row < lines(side).code.count,
              !isWrapPadding(point, side: side), let position = textPosition(at: point, side: side)
        else { return nil }
        return (side, position)
    }

    /// Whether `point` is in the blank space below `side`'s last visual line,
    /// where the other side wrapped to more lines and made the row taller.
    private func isWrapPadding(_ point: NSPoint, side: Side) -> Bool {
        guard wraps else { return false }
        let layout = layout(forWidth: bounds.width)
        let offset = point.y - codeTop
        guard offset >= 0, let last = layout.tops.last, offset < last else { return false }
        let row = Self.row(containing: offset, rowTops: layout.tops)
        guard let parts = side == .old ? layout.old : layout.new, parts.indices.contains(row), !parts[row].isEmpty else { return false }
        return Int((offset - layout.tops[row]) / lineHeight) >= parts[row].count
    }

    /// The row and offset on `side` nearest `point`. Points above or below
    /// the rows clamp to the first or last line, as a drag past the edge does.
    /// With `characterUnder`, only a glyph actually under `point` counts: the
    /// padding below a side that wraps to fewer lines resolves to nothing.
    func textPosition(at point: NSPoint, side: Side, characterUnder: Bool = false) -> TextSelection.Position? {
        let sideLines = lines(side)
        let code = codeRect(side)
        guard !sideLines.code.isEmpty, code.width > 0 else { return nil }
        let tops = layout(forWidth: bounds.width).tops
        let offset = point.y - codeTop
        if offset < 0 { return characterUnder ? nil : .init(row: 0, index: 0) }
        if offset >= tops[tops.count - 1] {
            guard !characterUnder else { return nil }
            let last = sideLines.code.count - 1
            return .init(row: last, index: (sideLines.codeStrings[last] as NSString).length)
        }
        let containing = Self.row(containing: offset, rowTops: tops)
        if characterUnder, containing >= sideLines.code.count { return nil }
        let row = min(containing, sideLines.code.count - 1)
        var line = sideLines.code[row]
        if wraps, let parts = (side == .old ? layout(forWidth: bounds.width).old : layout(forWidth: bounds.width).new)?[row], !parts.isEmpty {
            if characterUnder, isWrapPadding(point, side: side) { return nil }
            let part = Int((offset - tops[row]) / lineHeight)
            line = parts[min(max(0, part), parts.count - 1)]
        }
        let x = point.x - code.minX - Self.textInset - (sideLines.indents[row] ?? 0) + (wraps ? 0 : horizontalScroll.offset(side))
        var index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        let length = (sideLines.codeStrings[row] as NSString).length
        if characterUnder {
            // The glyph the pointer is over, not the nearest caret position;
            // nothing past the line's last glyph, as the text view requires.
            guard index != kCFNotFound, x >= 0, x <= CTLineGetTypographicBounds(line, nil, nil, nil) else { return nil }
            if index > 0, x < CTLineGetOffsetForStringIndex(line, index, nil) {
                // The glyph's first code unit, not the middle of a surrogate pair.
                index = (sideLines.codeStrings[row] as NSString).rangeOfComposedCharacterSequence(at: index - 1).location
            }
            guard index < length else { return nil }
        }
        return .init(row: row, index: index == kCFNotFound ? 0 : min(max(0, index), length))
    }

    private func beginTextSelection(side: Side, at position: TextSelection.Position, point: NSPoint, clickCount: Int, extending: Bool) {
        isSelectingText = true
        if extending, var selection = textSelection, selection.side == side {
            selection.focus = position
            textSelection = selection
            return
        }
        let line = lines(side).codeStrings[position.row] as NSString
        switch clickCount {
        case 2:
            // The word under the pointer, as NSTextView picks it, not the one
            // after the nearest caret position.
            // Blank space past the line's end selects nothing.
            guard line.length > 0, let under = textPosition(at: point, side: side, characterUnder: true)?.index else {
                textSelection = .init(side: side, anchor: position, focus: position)
                return
            }
            let word = NSAttributedString(string: line as String).doubleClick(at: min(max(0, under), line.length - 1))
            textSelection = .init(side: side, anchor: .init(row: position.row, index: word.location), focus: .init(row: position.row, index: NSMaxRange(word)))
        case 3...:
            textSelection = .init(side: side, anchor: .init(row: position.row, index: 0), focus: .init(row: position.row, index: line.length))
        default:
            textSelection = .init(side: side, anchor: position, focus: position)
        }
    }

    func selectedText() -> String {
        guard let selection = textSelection else { return "" }
        return selection.text(in: lines(selection.side).codeStrings)
    }

    /// Copies the selection to `pasteboard`; false when nothing is selected.
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard) -> Bool {
        let text = selectedText()
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    @objc func copy(_ sender: Any?) {
        copySelection(to: .general)
    }

    // MARK: - Keyboard

    /// Keys reach this row once a click focuses it. Paging and arrows scroll
    /// the review as they did over the read-only text views; Escape clears
    /// the selection first.
    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        if responds(to: selector) {
            perform(selector, with: nil)
        } else {
            nextResponder?.doCommand(by: selector)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if textSelection != nil {
            textSelection = nil
        } else {
            nextResponder?.cancelOperation(sender)
        }
    }

    override func insertText(_ insertString: Any) {
        nextResponder?.insertText(insertString)
    }

    override func scrollPageUp(_ sender: Any?) { scrollReview(byPages: -1) }
    override func scrollPageDown(_ sender: Any?) { scrollReview(byPages: 1) }
    override func pageUp(_ sender: Any?) { scrollReview(byPages: -1) }
    override func pageDown(_ sender: Any?) { scrollReview(byPages: 1) }
    // Sideways arrows scroll the focused side's long lines, as moving the
    // caret along them did in the text views.
    override func moveLeft(_ sender: Any?) { scrollFocusedSide(byPoints: -lineHeight) }
    override func moveRight(_ sender: Any?) { scrollFocusedSide(byPoints: lineHeight) }
    override func moveUp(_ sender: Any?) { scrollReview(byPoints: -lineHeight) }
    override func moveDown(_ sender: Any?) { scrollReview(byPoints: lineHeight) }
    override func scrollLineUp(_ sender: Any?) { scrollReview(byPoints: -lineHeight) }
    override func scrollLineDown(_ sender: Any?) { scrollReview(byPoints: lineHeight) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { scrollReview(to: -.greatestFiniteMagnitude) }
    override func scrollToEndOfDocument(_ sender: Any?) { scrollReview(to: .greatestFiniteMagnitude) }

    private func scrollFocusedSide(byPoints delta: CGFloat) {
        let side = textSelection?.side ?? .new
        guard !wraps, horizontalScroll.scroll(side, byPoints: delta) else { return }
        invalidateTiles(codeRect(side))
        updateScroller(side)
        lspController?.notifyScrolled()
    }

    private func scrollReview(byPages pages: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        scrollReview(byPoints: pages * max(lineHeight, clip.bounds.height - 2 * lineHeight))
    }

    private func scrollReview(byPoints delta: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        scrollReview(to: clip.bounds.minY + delta)
    }

    private func scrollReview(to y: CGFloat) {
        guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    override func selectAll(_ sender: Any?) {
        let side = textSelection?.side ?? .new
        let strings = lines(side).codeStrings
        guard let last = strings.indices.last else { return }
        textSelection = .init(side: side, anchor: .init(row: 0, index: 0), focus: .init(row: last, index: (strings[last] as NSString).length))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard textSelection.map({ !$0.isEmpty }) ?? false else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Accessibility

    /// One read-only text area per side, kept while the content is, so
    /// VoiceOver keeps its place. It reads and moves by line like the
    /// text-view panes did.
    private var codeElements: [Side: CodeAccessibilityElement] = [:]

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + codeAccessibilityElements()
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // AppKit asks on the main thread.
        let hit: (scroller: NSScroller?, element: CodeAccessibilityElement?) = MainActor.assumeIsolated {
            guard let window else { return (nil, nil) }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            // A visible scroller sits over its code column and answers for itself.
            if let scroller = [oldScroller, newScroller].first(where: { !$0.isHidden && $0.frame.contains(local) }) {
                return (scroller, nil)
            }
            return (nil, codeAccessibilityElements().first { $0.accessibilityFrameInParentSpace().contains(local) })
        }
        if let scroller = hit.scroller { return scroller }
        let element = hit.element
        return element ?? super.accessibilityHitTest(point)
    }

    func codeAccessibilityElements() -> [CodeAccessibilityElement] {
        (isStacked ? [Side.new] : [.old, .new]).compactMap { side in
            let code = codeRect(side)
            guard code.width > 0 else { return nil }
            let element = codeElements[side] ?? {
                let element = CodeAccessibilityElement(lines: lines(side).codeStrings)
                element.setAccessibilityRole(.textArea)
                element.setAccessibilityLabel(isStacked ? "Code" : side == .old ? "Old code" : "New code")
                element.setAccessibilityParent(self)
                element.frameForLines = { [weak self] start, end in
                    guard let self, let window else { return nil }
                    var rect = textRect(side, row: start.row, from: start.index, to: start.row == end.row ? end.index : .max)
                    for row in start.row + 1..<max(start.row + 1, end.row) {
                        rect = rect.union(textRect(side, row: row, from: 0, to: .max))
                    }
                    if end.row != start.row { rect = rect.union(textRect(side, row: end.row, from: 0, to: end.index)) }
                    return window.convertToScreen(convert(rect, to: nil))
                }
                element.selection = { [weak self] in
                    guard let self, let textSelection, textSelection.side == side else { return nil }
                    return (textSelection.start, textSelection.end)
                }
                element.visibleLines = { [weak self] in
                    guard let self else { return nil }
                    let visible = visibleRect.intersection(codeRect(side))
                    let count = lines(side).code.count
                    let tops = layout(forWidth: bounds.width).tops
                    guard !visible.isEmpty, count > 0 else { return nil }
                    let first = min(Self.row(containing: max(0, visible.minY - codeTop), rowTops: tops), count - 1)
                    let last = min(Self.row(containing: max(0, visible.maxY - codeTop - 0.5), rowTops: tops), count - 1)
                    guard first <= last else { return nil }
                    return (.init(row: first, index: 0), .init(row: last, index: (lines(side).codeStrings[last] as NSString).length))
                }
                element.select = { [weak self] start, end in
                    self?.textSelection = .init(side: side, anchor: start, focus: end)
                }
                codeElements[side] = element
                return element
            }()
            element.setAccessibilityFrameInParentSpace(code)
            return element
        }
    }

    // MARK: - Context expansion

    /// A gutter click on an expansion row expands it, as the ruler does.
    private func expandFromGutter(at point: NSPoint, optionKey: Bool) -> Bool {
        guard let hit = gutterRow(at: point) else { return false }
        return expand(side: hit.side, row: hit.row, optionKey: optionKey)
    }

    private func expand(side: Side, row: Int, optionKey: Bool) -> Bool {
        let metadata = lines(side).metadata
        guard metadata.indices.contains(row), let key = metadata[row].expansionKey else { return false }
        let edge = metadata[row].expansionEdge
        let all = optionKey || (key.isShared && edge == nil)
        onContextExpansion(key, all ? .all : .chunk(size: diffContextExpansionChunkSize), edge)
        return true
    }

    /// Clicks the first side's gutter on `row`, as the ruler's
    /// `invokeExpansionForTesting` does.
    func invokeExpansionForTesting(row: Int, optionKey: Bool) {
        _ = expand(side: isStacked ? .new : .old, row: row, optionKey: optionKey)
    }

    /// Both sides' lines, as the text views' strings read.
    func renderedTextForTesting() -> String {
        (old.codeStrings + new.codeStrings).joined(separator: "\n")
    }

    func expansionTarget(at point: NSPoint) -> ExpansionTarget? {
        let side = side(at: point)
        guard let row = row(at: point.y) else { return nil }
        return expansionPills(side, row: row).first { $0.pill.contains(point) }.map {
            ExpansionTarget(side: side, row: row, action: $0.action)
        }
    }

    private struct ExpansionPill {
        let action: DiffPaneTextDocumentBuilder.ContextExpansionAction
        let pill: NSRect
        let chevron: NSRect?
    }

    /// Pill and chevron rects for each expansion action on `row`, from the
    /// same inputs `DiffPaneCodeTextView` feeds `expandPillRect`.
    private func expansionPills(_ side: Side, row: Int) -> [ExpansionPill] {
        let sideLines = lines(side)
        guard sideLines.metadata.indices.contains(row), sideLines.code.indices.contains(row) else { return [] }
        let metadata = sideLines.metadata[row]
        let actions = metadata.contextExpansionActions
        guard !actions.isEmpty else { return [] }
        let tops = layout(forWidth: bounds.width).tops
        let pane = pane(side)
        let gutter = sideLines.gutterWidth
        let rowRect = NSRect(x: pane.minX + gutter, y: codeTop + tops[row], width: max(0, pane.width - gutter), height: tops[row + 1] - tops[row])
        let textX = rowRect.minX + Self.textInset + (sideLines.indents[row] ?? 0) - (wraps ? 0 : horizontalScroll.offset(side))
        let textHeight = sideLines.customMetrics[row]?.lineHeight ?? lineHeight
        let line = sideLines.code[row]
        let label = sideLines.codeStrings[row] as NSString
        return actions.compactMap { action in
            let start = action.range.location - metadata.range.location
            guard action.range.length > 0, start >= 0, start + action.range.length <= label.length,
                  !label.substring(with: NSRange(location: start, length: action.range.length)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let minX = CTLineGetOffsetForStringIndex(line, start, nil)
            let maxX = CTLineGetOffsetForStringIndex(line, start + action.range.length, nil)
            let textRect = NSRect(x: textX + minX, y: rowRect.minY, width: maxX - minX, height: textHeight)
            let chevronSize = chevronImage(for: action)?.size ?? .zero
            let pill = DiffPaneCodeTextView.expandPillRect(textRect: textRect, firstLineRect: textRect, rowRect: rowRect, chevronSize: chevronSize)
            let chevron = chevronSize == .zero ? nil : DiffPaneCodeTextView.expandChevronRect(
                chevronLeftX: textRect.minX - 5 - chevronSize.width, chevronSize: chevronSize, pillRect: pill
            )
            return ExpansionPill(action: action, pill: pill, chevron: chevron)
        }
    }

    /// The pill's chevron in the pill tint, built once per symbol.
    private func chevronImage(for action: DiffPaneTextDocumentBuilder.ContextExpansionAction) -> NSImage? {
        let symbol = DiffPaneTextDocumentBuilder.expandableContextSymbolName(boundary: action.boundary, mode: action.mode)
        if let image = chevronImages[symbol] { return image }
        let image = DiffPaneCodeTextView.expandChevronImage(
            boundary: action.boundary, mode: action.mode, font: codeFont, color: palette?.pillTint ?? .textColor
        )
        chevronImages[symbol] = image
        return image
    }

    private func drawExpansionPills(_ side: Side, rows: Range<Int>, palette: Palette) {
        for row in rows {
            for pill in expansionPills(side, row: row) {
                let target = ExpansionTarget(side: side, row: row, action: pill.action)
                let alpha = DiffPaneCodeTextView.expandPillFillAlpha(hovered: hoveredExpansion == target, pressed: pressedExpansion == target)
                if alpha > 0 {
                    palette.accent.withAlphaComponent(alpha).setFill()
                    NSBezierPath(roundedRect: pill.pill, xRadius: 6, yRadius: 6).fill()
                }
                if let chevron = pill.chevron {
                    chevronImage(for: pill.action)?.draw(
                        in: chevron, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                    )
                }
            }
        }
    }

    // MARK: - Horizontal scrolling

    func scrollerForTesting(_ side: Side) -> NSScroller {
        side == .old ? oldScroller : newScroller
    }

    @objc private func scrollerDidMove(_ sender: NSScroller) {
        let side: Side = sender === oldScroller ? .old : .new
        if horizontalScroll.scroll(side, toFraction: CGFloat(sender.doubleValue)) {
            invalidateTiles(codeRect(side))
            lspController?.notifyScrolled()
        }
        updateScroller(side)
    }

    private func updateScroller(_ side: Side) {
        let scroller = side == .old ? oldScroller : newScroller
        let maxOffset = horizontalScroll.maxOffset(side)
        scroller.isHidden = maxOffset == 0
        guard maxOffset > 0 else { return }
        let content = side == .old ? horizontalScroll.oldContentWidth : horizontalScroll.newContentWidth
        let viewport = side == .old ? horizontalScroll.oldViewportWidth : horizontalScroll.newViewportWidth
        scroller.knobProportion = viewport / max(content, 1)
        scroller.doubleValue = Double(horizontalScroll.offset(side) / maxOffset)
    }

    private func layoutScrollers() {
        let thickness = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
        for side in [Side.old, .new] {
            let code = codeRect(side)
            (side == .old ? oldScroller : newScroller).frame = NSRect(
                x: code.minX, y: max(0, code.maxY - thickness), width: code.width, height: thickness
            )
            updateScroller(side)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let handled = scroll(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas,
            at: location, phase: event.phase, momentumPhase: event.momentumPhase
        )
        if !handled {
            nextResponder?.scrollWheel(with: event)
        }
    }

    /// Applies a wheel event at `point`. Returns false for events the review
    /// should scroll instead: gestures that began mostly vertical, and any
    /// over a side with nothing to scroll sideways.
    func scroll(
        deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool, at point: NSPoint,
        phase: NSEvent.Phase = [], momentumPhase: NSEvent.Phase = []
    ) -> Bool {
        let side = side(at: point)
        let canScroll = horizontalScroll.maxOffset(side) > 0
        guard scrollGesture.claims(phase: phase, momentumPhase: momentumPhase, deltaX: deltaX, deltaY: deltaY, canScroll: canScroll) else {
            return false
        }
        let delta = -DiffSplitHorizontalScroll.pointDelta(scrollingDeltaX: deltaX, isPrecise: isPrecise, lineHeight: lineHeight)
        if horizontalScroll.scroll(side, byPoints: delta) {
            invalidateTiles(codeRect(side))
            updateScroller(side)
            lspController?.notifyScrolled()
        }
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawContent(dirtyRect)
    }

    // MARK: - Tiles

    /// Rows draw into tile layers of this height. Each tile draws once when
    /// it nears the viewport and again only when content under it changes.
    /// With one backing store per row, AppKit redrew a strip of every tall
    /// row on each scroll step, which cost a vsync in about one frame in
    /// twelve.
    static let tileHeight: CGFloat = 512

    private var tiles: [Int: CALayer] = [:]
    private lazy var tileDelegate = TileDelegate(view: self)

    override var wantsUpdateLayer: Bool { true }

    private var observedClipView: NSClipView?
    private var clipObserver: NSObjectProtocol?

    /// Scrolling reveals rows without invalidating them, so each row watches
    /// the clip view and asks for tiles it has not drawn yet.
    private func observeClipView() {
        let clipView = window == nil ? nil : enclosingScrollView?.contentView
        guard clipView !== observedClipView else { return }
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        observedClipView = clipView
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addMainActorObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView
        ) { [weak self] in
            self?.requestMissingTiles()
            // Hover and definition popovers anchor to a symbol that just moved.
            self?.lspController?.notifyScrolled()
        }
    }

    private func requestMissingTiles() {
        guard bounds.height > 0 else { return }
        if wantedTiles().contains(where: { tiles[$0] == nil }) {
            needsDisplay = true
        }
    }

    /// The tiles to have drawn: the visible part plus a quarter viewport
    /// each way, so a tall row entering the screen draws a tile or two per
    /// frame rather than several viewports at once.
    private func wantedTiles() -> Range<Int> {
        let margin = (enclosingScrollView?.contentView.bounds.height ?? visibleRect.height) / 4
        return Self.tileRange(covering: visibleRect.insetBy(dx: 0, dy: -margin), height: bounds.height, tileHeight: Self.tileHeight)
    }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        lspController?.tearDown()
    }

    /// AppKit calls this for its own scroll invalidations as well as ours,
    /// so it only adds tiles that are missing; existing ones redraw only
    /// through `invalidateTiles`.
    override func updateLayer() {
        guard let layer, bounds.height > 0 else { return }
        for index in wantedTiles() where tiles[index] == nil {
            let tile = CALayer()
            tile.delegate = tileDelegate
            tile.contentsFormat = .RGBA8Uint
            tile.contentsScale = window?.backingScaleFactor ?? 2
            tile.isOpaque = false
            tile.setValue(index, forKey: "tileIndex")
            tile.frame = convertToLayer(tileFrame(index))
            layer.insertSublayer(tile, at: 0)
            tile.setNeedsDisplay()
            tiles[index] = tile
        }
    }

    /// The tiles a rect touches, in a row `height` tall.
    static func tileRange(covering rect: NSRect, height: CGFloat, tileHeight: CGFloat) -> Range<Int> {
        let count = Int(ceil(height / tileHeight))
        let clipped = rect.intersection(NSRect(x: rect.minX, y: 0, width: max(rect.width, 1), height: height))
        guard count > 0, !clipped.isNull, clipped.height > 0 else { return 0..<0 }
        let first = max(0, Int(floor(clipped.minY / tileHeight)))
        let last = min(count, Int(ceil(clipped.maxY / tileHeight)))
        return first..<max(first, last)
    }

    private func tileRect(_ index: Int) -> NSRect {
        let minY = CGFloat(index) * Self.tileHeight
        return NSRect(x: 0, y: minY, width: bounds.width, height: min(Self.tileHeight, bounds.height - minY))
    }

    /// A tile's layer frame: its rect plus a point of overlap with each
    /// neighbor. Rows sit at fractional positions, so tile edges fall
    /// mid-pixel; overlapping identical content keeps them from blending
    /// into a visible seam.
    private func tileFrame(_ index: Int) -> NSRect {
        tileRect(index).insetBy(dx: 0, dy: -1).intersection(bounds)
    }

    /// Redraws the tiles under `rect`, or every tile, and lets
    /// `updateLayer` add any that are now needed.
    private func invalidateTiles(_ rect: NSRect? = nil) {
        for (index, tile) in tiles where rect.map({ tileRect(index).intersects($0) }) ?? true {
            tile.setNeedsDisplay()
        }
        needsDisplay = true
    }

    /// Fits tiles to a new size: drops those past the end and reframes the rest.
    private func layoutTiles() {
        let count = Int(ceil(max(0, bounds.height) / Self.tileHeight))
        for (index, tile) in tiles {
            if index >= count {
                tile.removeFromSuperlayer()
                tiles[index] = nil
            } else {
                tile.frame = convertToLayer(tileFrame(index))
            }
        }
    }

    private func updateTileScale() {
        let scale = window?.backingScaleFactor ?? 2
        for tile in tiles.values where tile.contentsScale != scale {
            tile.contentsScale = scale
            tile.setNeedsDisplay()
        }
    }

    fileprivate func drawTile(_ tile: CALayer, in context: CGContext) {
        guard let index = tile.value(forKey: "tileIndex") as? Int else { return }
        let rect = tileFrame(index)
        context.saveGState()
        if !tile.contentsAreFlipped() {
            context.translateBy(x: 0, y: tile.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.translateBy(x: -rect.minX, y: -rect.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawContent(rect)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private func drawContent(_ requestedRect: NSRect) {
        let dirtyRect = requestedRect.intersection(bounds)
        guard !dirtyRect.isEmpty, let palette, let context = NSGraphicsContext.current?.cgContext else { return }
        let cardRect = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bottomPadding))
        let fusion = chrome?.fusion ?? .none
        let hunkPath = chrome == nil ? nil : Self.roundedPath(
            in: cardRect,
            top: fusion.fusedWithPrevious ? 0 : Self.hunkCornerRadius,
            bottom: fusion.fusedWithNext ? 0 : Self.hunkCornerRadius
        )

        context.saveGState()
        // Content stays inside the file card's rounded corners, as SwiftUI clips it.
        if cardEdges.top || cardEdges.bottom {
            Self.roundedPath(
                in: bounds, top: cardEdges.top ? Self.cardCornerRadius : 0, bottom: cardEdges.bottom ? Self.cardCornerRadius : 0
            ).addClip()
        }
        palette.bg1.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height).intersection(dirtyRect).fill()
        if let hunkPath { hunkPath.addClip() }
        drawHeader(palette: palette, context: context, dirtyRect: dirtyRect)
        let range = visibleLineRange(in: dirtyRect)
        let layout = layout(forWidth: bounds.width)
        for side in isStacked ? [Side.new] : [.old, .new] {
            draw(
                side, wrapped: side == .old ? layout.old : layout.new, tops: layout.tops,
                in: pane(side), offset: horizontalScroll.offset(side), range: range, palette: palette, context: context
            )
            drawReviewOverlays(side, tops: layout.tops, palette: palette)
        }
        if !isStacked {
            let divider = DiffPaneSplitGeometry.frames(containerWidth: bounds.width).divider
            let top = max(dirtyRect.minY, headerHeight)
            palette.line.setFill()
            NSRect(x: divider.minX, y: top, width: divider.width, height: max(0, dirtyRect.maxY - top)).fill()
        }
        context.restoreGState()
        if let hunkPath {
            palette.line.setStroke()
            hunkPath.lineWidth = 0.75
            hunkPath.stroke()
        }
        drawFileCardEdges(palette: palette)
    }

    private func drawHeader(palette: Palette, context: CGContext, dirtyRect: NSRect) {
        guard chrome != nil, let headerLine = header(), dirtyRect.minY < headerHeight else { return }
        palette.bg2.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
        palette.line.setFill()
        NSRect(x: 0, y: headerHeight - 0.5, width: bounds.width, height: 0.5).fill()
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(headerLine, &ascent, &descent, nil)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: Self.headerHorizontalPadding, y: (headerHeight + ascent - descent) / 2)
        CTLineDraw(headerLine, context)
        context.restoreGState()
    }

    /// The header text, truncated to end 12pt before the first button, as
    /// SwiftUI's one-line `Text` and `Spacer(minLength: 12)` lay it out.
    private func header() -> CTLine? {
        guard let headerLine else { return nil }
        let trailing = headerButtons.first.map { $0.frame.minX - 12 } ?? bounds.width - Self.headerHorizontalPadding
        let width = max(0, trailing - Self.headerHorizontalPadding)
        if let truncatedHeader, truncatedHeader.width == width { return truncatedHeader.line }
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(
            string: "…", attributes: [.font: chrome?.headerFont as Any, .foregroundColor: palette?.fgMuted as Any]
        ))
        let line = CTLineCreateTruncatedLine(headerLine, Double(width), .end, ellipsis) ?? headerLine
        truncatedHeader = (width, line)
        return line
    }

    /// Draws `side`'s rows in `range`: backgrounds and line numbers, then
    /// the code clipped to its column. When wrapping, `wrapped` holds each
    /// row's visual lines.
    private func draw(
        _ which: Side, wrapped: [[CTLine]]?, tops: [CGFloat],
        in pane: CGRect, offset: CGFloat, range: Range<Int>, palette: Palette, context: CGContext
    ) {
        let side = lines(which)
        let gutter = side.gutterWidth
        context.saveGState()
        context.clip(to: CGRect(x: pane.minX, y: headerHeight, width: pane.width, height: max(0, bounds.height - headerHeight)))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // The gutter column, as `DiffPaneLineNumberRulerView` paints it.
        palette.bg0.setFill()
        NSRect(x: pane.minX, y: headerHeight, width: gutter, height: max(0, bounds.height - headerHeight - bottomPadding)).fill()
        let rows = range.clamped(to: 0..<side.code.count)
        for index in rows {
            let y = codeTop + tops[index]
            let rowHeight = tops[index + 1] - tops[index]
            let tone = side.tones.indices.contains(index) ? side.tones[index] : .context
            if let fill = palette.codeFills[tone] {
                let codeRow = NSRect(x: pane.minX + gutter, y: y, width: max(0, pane.width - gutter), height: rowHeight)
                (tone == .placeholder ? palette.hatchPattern : fill).setFill()
                codeRow.fill()
            }
            let gutterRow = NSRect(x: pane.minX, y: y, width: gutter, height: rowHeight)
            if let fill = palette.gutterFills[tone] {
                fill.setFill()
                gutterRow.fill()
            }
            if tone == .add || tone == .delete {
                (tone == .add ? palette.add : palette.del).setFill()
                NSRect(x: gutterRow.minX, y: gutterRow.minY, width: 3, height: gutterRow.height).fill()
            }
        }
        // Under the line numbers and code, as the ruler and text view draw it.
        drawActiveHighlight(which, tops: tops, palette: palette)
        for index in rows {
            if side.labels.indices.contains(index), let label = side.labels[index] {
                context.textPosition = CGPoint(
                    x: pane.minX + gutter - DiffPaneLineNumberGutterGeometry.horizontalPadding - label.width,
                    y: codeTop + tops[index] + baseline(side, index)
                )
                CTLineDraw(label.line, context)
            }
        }
        context.clip(to: CGRect(x: pane.minX + gutter, y: headerHeight, width: max(0, pane.width - gutter), height: max(0, bounds.height - headerHeight)))
        drawTextSelection(which, wrapped: wrapped, tops: tops, rows: rows)
        // Under the labels, as `DiffPaneCodeTextView` draws them with the row backgrounds.
        drawExpansionPills(which, rows: rows, palette: palette)
        for index in rows {
            let x = pane.minX + gutter + Self.textInset + (side.indents[index] ?? 0)
            let baseline = codeTop + tops[index] + baseline(side, index)
            if let wrapped {
                for (part, line) in wrapped[index].enumerated() {
                    context.textPosition = CGPoint(x: x, y: baseline + CGFloat(part) * lineHeight)
                    CTLineDraw(line, context)
                }
            } else {
                context.textPosition = CGPoint(x: x - offset, y: baseline)
                CTLineDraw(side.code[index], context)
            }
        }
        context.restoreGState()
    }

    /// The selected text's background, in the system selection color, dimmed
    /// when this row is not the focused view, as `NSTextView` draws it.
    private func drawTextSelection(_ which: Side, wrapped: [[CTLine]]?, tops: [CGFloat], rows: Range<Int>) {
        guard let selection = textSelection, selection.side == which, !selection.isEmpty else { return }
        let side = lines(which)
        let code = codeRect(which)
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        for row in rows {
            let length = (side.codeStrings[row] as NSString).length
            guard let span = selection.span(inRow: row, length: length) else { continue }
            let originX = code.minX + Self.textInset + (side.indents[row] ?? 0) - (wraps ? 0 : horizontalScroll.offset(which))
            let parts = wrapped?[row] ?? [side.code[row]]
            let partHeight = wrapped == nil ? tops[row + 1] - tops[row] : lineHeight
            for (part, line) in parts.enumerated() {
                let range = CTLineGetStringRange(line)
                let lower = max(span.range.lowerBound, range.location)
                let upper = min(span.range.upperBound, range.location + range.length)
                let runsOn = span.continues && part == parts.count - 1
                guard lower < upper || runsOn else { continue }
                let minX = CTLineGetOffsetForStringIndex(line, min(lower, upper), nil)
                let maxX = runsOn ? code.maxX - originX : CTLineGetOffsetForStringIndex(line, upper, nil)
                NSRect(
                    x: originX + minX, y: codeTop + tops[row] + CGFloat(part) * lineHeight,
                    width: max(0, maxX - minX), height: partHeight
                ).fill()
            }
        }
    }

    /// Distance from a row's top to its first baseline, as TextKit places it.
    private func baseline(_ side: SideLines, _ index: Int) -> CGFloat {
        side.customMetrics[index]?.baselineOffset ?? baselineOffset
    }

    /// The rows' rect within the code area or the gutter of `side`.
    private func rowsRect(_ rows: ClosedRange<Int>, side: Side, tops: [CGFloat]) -> NSRect {
        let top = codeTop + tops[rows.lowerBound]
        let bottom = codeTop + tops[rows.upperBound + 1]
        let pane = pane(side)
        return NSRect(x: pane.minX, y: top, width: pane.width, height: bottom - top)
    }

    /// The active comment's lines, as `DiffPaneCodeTextView` and the ruler
    /// draw them.
    private func drawActiveHighlight(_ side: Side, tops: [CGFloat], palette: Palette) {
        let sideLines = lines(side)
        guard let rows = review.activeHighlight?.highlightedRowRange(in: sideLines.metadata) else { return }
        let gutter = sideLines.gutterWidth
        let rect = rowsRect(rows, side: side, tops: tops)
        palette.accentGutter.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: gutter, height: rect.height).fill()
        let code = NSRect(x: rect.minX + gutter + 4, y: rect.minY, width: max(rect.width - gutter - 8, 1), height: rect.height)
        palette.accentCode.setFill()
        NSBezierPath(roundedRect: code, xRadius: 4, yRadius: 4).fill()
        palette.accentStroke.setStroke()
        let stroke = NSBezierPath(roundedRect: code.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        stroke.lineWidth = 1
        stroke.stroke()
    }

    /// The gutter drag outline and the hover "+" affordance, as the ruler
    /// draws them.
    private func drawReviewOverlays(_ side: Side, tops: [CGFloat], palette: Palette) {
        let gutter = lines(side).gutterWidth
        let accent = palette.accent
        if let selection = gutterSelection, selection.side == side {
            let rect = rowsRect(min(selection.start, selection.current)...max(selection.start, selection.current), side: side, tops: tops)
            let outline = NSRect(x: rect.minX + 4, y: rect.minY, width: max(gutter - 8, 1), height: rect.height)
            accent.setStroke()
            let path = NSBezierPath(roundedRect: outline.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            path.lineWidth = 1.5
            path.stroke()
        }
        if let hover = hoveredGutterRow, hover.side == side, gutterSelection == nil {
            let row = rowsRect(hover.row...hover.row, side: side, tops: tops)
            let rect = DiffPaneLineNumberRulerView.reviewAffordanceRect(
                in: NSRect(x: 0, y: row.minY, width: gutter, height: min(row.height, lineHeight)), ruleThickness: gutter
            ).offsetBy(dx: row.minX, dy: 0)
            accent.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: palette.bg1,
            ]
            let plus = "+" as NSString
            let size = plus.size(withAttributes: attributes)
            plus.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 0.5), withAttributes: attributes)
        }
    }

    /// The review's file-card border: the sides always, top and bottom with
    /// rounded corners where this row starts or ends the card. One stroke
    /// per edge, so no side is drawn twice.
    private func drawFileCardEdges(palette: Palette) {
        let rect = bounds.insetBy(dx: 0.375, dy: 0.375)
        let radius = Self.cardCornerRadius
        let path: NSBezierPath
        switch (cardEdges.top, cardEdges.bottom) {
        case (true, true):
            path = Self.roundedPath(in: bounds, top: radius, bottom: radius)
        case (true, false):
            path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: bounds.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
            path.line(to: NSPoint(x: rect.maxX, y: bounds.maxY))
        case (false, true):
            path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: bounds.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX + radius, y: rect.maxY), radius: radius)
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.maxX, y: rect.maxY - radius), radius: radius)
            path.line(to: NSPoint(x: rect.maxX, y: bounds.minY))
        case (false, false):
            path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: bounds.minY))
            path.line(to: NSPoint(x: rect.minX, y: bounds.maxY))
            path.move(to: NSPoint(x: rect.maxX, y: bounds.minY))
            path.line(to: NSPoint(x: rect.maxX, y: bounds.maxY))
        }
        palette.line.setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    /// `rect` inset by half a stroke, with `top` and `bottom` corner radii.
    private static func roundedPath(in rect: NSRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let r = rect.insetBy(dx: 0.375, dy: 0.375)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX, y: r.minY + top))
        if top > 0 { path.appendArc(from: NSPoint(x: r.minX, y: r.minY), to: NSPoint(x: r.minX + top, y: r.minY), radius: top) }
        path.line(to: NSPoint(x: r.maxX - top, y: r.minY))
        if top > 0 { path.appendArc(from: NSPoint(x: r.maxX, y: r.minY), to: NSPoint(x: r.maxX, y: r.minY + top), radius: top) }
        path.line(to: NSPoint(x: r.maxX, y: r.maxY - bottom))
        if bottom > 0 { path.appendArc(from: NSPoint(x: r.maxX, y: r.maxY), to: NSPoint(x: r.maxX - bottom, y: r.maxY), radius: bottom) }
        path.line(to: NSPoint(x: r.minX + bottom, y: r.maxY))
        if bottom > 0 { path.appendArc(from: NSPoint(x: r.minX, y: r.maxY), to: NSPoint(x: r.minX, y: r.maxY - bottom), radius: bottom) }
        path.close()
        return path
    }

    /// Theme colors resolved once per configure: `Theme.nsColor` bridges from
    /// SwiftUI on every call, too slow to repeat per row on every frame.
    private struct Palette {
        let bg0, bg1, bg2, line, hatch, add, del, accent, accentGutter, accentCode, accentStroke, pillTint, fgMuted, fgFaint: NSColor
        /// The placeholder hatch as a pattern fill: the same 45° lines 8pt
        /// apart that `DiffPaneCodeTextView` strokes one by one, at a
        /// fraction of the cost of stroking them on every tile draw.
        let hatchPattern: NSColor
        /// Row fills for the code, and the ruler's slightly lighter ones.
        let codeFills: [DiffPaneLineTone: NSColor]
        let gutterFills: [DiffPaneLineTone: NSColor]

        init(theme: Theme) {
            bg0 = theme.nsColor("bg-0")
            bg1 = theme.nsColor("bg-1")
            bg2 = theme.nsColor("bg-2")
            line = theme.nsColor("line")
            hatch = line.withAlphaComponent(0.35)
            let stroke = hatch
            let placeholder = Self.opaque(bg2.withAlphaComponent(0.55), over: bg1)
            hatchPattern = NSColor(patternImage: NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                placeholder.setFill()
                rect.fill()
                stroke.setStroke()
                let path = NSBezierPath()
                // One period of the diagonal, plus its neighbors so the corners
                // join. Rows draw flipped, so this runs bottom-left to top-right
                // on screen, as the text view's hatch does.
                for offset: CGFloat in [-8, 0, 8] {
                    path.move(to: NSPoint(x: offset, y: 8))
                    path.line(to: NSPoint(x: offset + 8, y: 0))
                }
                path.lineWidth = 1
                path.stroke()
                return true
            })
            add = theme.nsColor("add")
            del = theme.nsColor("del")
            accent = theme.nsColor("accent")
            accentGutter = accent.withAlphaComponent(0.18)
            accentCode = accent.withAlphaComponent(0.12)
            accentStroke = accent.withAlphaComponent(0.82)
            pillTint = theme.nsColor("seg-pill-active-fg")
            fgMuted = theme.nsColor("fg-muted")
            fgFaint = theme.nsColor("fg-faint")
            let collapsed = theme.nsColor("bg-3").withAlphaComponent(0.72)
            // Code rows sit on bg-1 and gutter rows on bg-0, so their tints are
            // flattened onto those: an opaque fill copies pixels instead of
            // blending them, and these rows span the whole pane.
            codeFills = [
                .add: Self.opaque(add.withAlphaComponent(0.18), over: bg1),
                .delete: Self.opaque(del.withAlphaComponent(0.18), over: bg1),
                .placeholder: placeholder, .collapsed: Self.opaque(collapsed, over: bg1),
            ]
            gutterFills = [
                .add: Self.opaque(add.withAlphaComponent(0.16), over: bg0),
                .delete: Self.opaque(del.withAlphaComponent(0.16), over: bg0),
                .placeholder: Self.opaque(bg2.withAlphaComponent(0.55), over: bg0),
                .collapsed: Self.opaque(collapsed, over: bg0),
            ]
        }

        /// `top` composited onto `base` in sRGB, or `top` itself when `base`
        /// is translucent and the result would depend on what lies beneath.
        static func opaque(_ top: NSColor, over base: NSColor) -> NSColor {
            guard let top = top.usingColorSpace(.sRGB), let base = base.usingColorSpace(.sRGB),
                  base.alphaComponent >= 1 else { return top }
            let a = top.alphaComponent
            func mix(_ t: CGFloat, _ b: CGFloat) -> CGFloat { t * a + b * (1 - a) }
            return NSColor(
                srgbRed: mix(top.redComponent, base.redComponent), green: mix(top.greenComponent, base.greenComponent),
                blue: mix(top.blueComponent, base.blueComponent), alpha: 1
            )
        }

        /// Same coloring as `DiffPaneLineNumberRulerView.labelAttributes`.
        func labelColor(_ label: String, tone: DiffPaneLineTone) -> NSColor {
            if tone == .add || label.hasPrefix("+") { return add }
            if tone == .delete || label.hasPrefix("-") { return del }
            return fgFaint
        }
    }

    // MARK: - Text metrics and lines

    private struct TextKitMetrics {
        let lineHeight: CGFloat
        let baselineOffset: CGFloat
    }

    private static var metricsCache: [String: TextKitMetrics] = [:]

    /// Line height and baseline exactly as TextKit lays out diff code with
    /// `CenterTypography.paragraphStyle()`, so a row measures the same as the
    /// text-view panes and scroll anchors do not shift between renderers.
    static func textKitLineHeight(for font: NSFont) -> CGFloat {
        textKitMetrics(for: font).lineHeight
    }

    private static func textKitMetrics(
        for font: NSFont,
        style: NSParagraphStyle = CenterTypography.paragraphStyle()
    ) -> TextKitMetrics {
        let key = "\(font.fontName)|\(font.pointSize)|\(style.lineHeightMultiple)|\(style.minimumLineHeight)|\(style.maximumLineHeight)"
        if let cached = metricsCache[key] { return cached }
        // Without `.baselineOffset`: CoreText applies that itself when drawing.
        let storage = NSTextStorage(string: "X\nX", attributes: [
            .font: font,
            .paragraphStyle: style,
        ])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let first = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let second = layoutManager.lineFragmentRect(forGlyphAt: 2, effectiveRange: nil)
        let baseline = layoutManager.location(forGlyphAt: 0).y
        let metrics = TextKitMetrics(lineHeight: second.minY - first.minY, baselineOffset: baseline)
        metricsCache[key] = metrics
        return metrics
    }

    /// Height, baseline and indent for a line whose paragraph style sets its
    /// own (the context-expansion rows), as TextKit lays it out; nil for
    /// lines that use the code line metrics.
    static func ownMetrics(of line: NSAttributedString, font: NSFont) -> (lineHeight: CGFloat, baselineOffset: CGFloat, indent: CGFloat)? {
        guard line.length > 0,
              let style = line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              style.minimumLineHeight > 0 || style.maximumLineHeight > 0 || style.firstLineHeadIndent > 0
        else { return nil }
        let metrics = textKitMetrics(for: line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? font, style: style)
        return (metrics.lineHeight, metrics.baselineOffset, style.firstLineHeadIndent)
    }

    private static func lines(
        code document: DiffPaneTextDocumentBuilder.CodeDocument,
        gutter: NSAttributedString,
        font: NSFont,
        palette: Palette
    ) -> SideLines {
        var side = SideLines()
        let text = document.attributedString
        let length = text.length
        for metadata in document.lines {
            var range = metadata.range
            range.location = min(range.location, length)
            range.length = min(range.length, length - range.location)
            var line = text.attributedSubstring(from: range)
            if line.string.hasSuffix("\n") {
                line = line.attributedSubstring(from: NSRange(location: 0, length: line.length - 1))
            }
            if let own = ownMetrics(of: line, font: font) {
                side.customMetrics[side.code.count] = TextKitMetrics(lineHeight: own.lineHeight, baselineOffset: own.baselineOffset)
                if own.indent > 0 { side.indents[side.code.count] = own.indent }
            }
            let ctLine = CTLineCreateWithAttributedString(line)
            side.code.append(ctLine)
            side.attributed.append(line)
            side.codeStrings.append(line.string)
            // Expansion rows draw indented, inside a pill that pads past the text.
            let extent = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)) + (side.indents[side.code.count - 1] ?? 0)
                + (metadata.contextExpansionActions.isEmpty ? 0 : Self.expansionPillPadding)
            side.widest = max(side.widest, extent)
        }
        let labels = gutter.string.components(separatedBy: "\n")
        side.gutterWidth = DiffPaneLineNumberGutterGeometry.thickness(labels: labels)
        for (index, metadata) in document.lines.enumerated() {
            let label = labels.indices.contains(index) ? labels[index] : ""
            let tone = metadata.tone ?? DiffPaneLineTone(label: label, rowKind: metadata.kind)
            side.tones.append(tone)
            side.metadata.append(metadata)
            side.labels.append(label.isEmpty ? nil : Label(CTLineCreateWithAttributedString(NSAttributedString(
                string: label,
                attributes: [.font: DiffPaneLineNumberGutterGeometry.labelFont, .foregroundColor: palette.labelColor(label, tone: tone)]
            ))))
        }
        return side
    }
}

extension DiffSplitCoreTextRowView: AppKitDiffScrollLineTargetProviding {
    /// The target line's center, so line jumps land on the line rather than
    /// centering the whole hunk. Same lookup as the text-view panes.
    func scrollTargetCenterY(for target: AppKitDiffScrollLineTarget) -> CGFloat? {
        let side: Side = isStacked || target.side != .old ? .new : .old
        guard let row = lines(side).metadata.firstIndex(where: { metadata in
            guard let sourceLine = metadata.sourceLine else { return false }
            return target.side.matches(sourceLine.anchor.side)
                && sourceLine.highlightLineNumber(for: target.side) == target.line
        }) else { return nil }
        return rowCenterY(row)
    }
}

/// Draws a row's tiles; layers hold their delegate weakly. Core Animation
/// displays these layers during the main-thread commit.
@MainActor
private final class TileDelegate: NSObject, @preconcurrency CALayerDelegate {
    weak var view: DiffSplitCoreTextRowView?

    init(view: DiffSplitCoreTextRowView) {
        self.view = view
    }

    func draw(_ layer: CALayer, in context: CGContext) {
        view?.drawTile(layer, in: context)
    }

    /// No implicit fades when tiles appear or change.
    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}

extension DiffSplitCoreTextRowView: DiffPaneLSPHost {
    /// LSP serves the new side, as it does in the text-view panes; stacked
    /// rows hold all their lines there.
    var lineMetadata: [DiffPaneTextDocumentBuilder.LineMetadata] { new.metadata }
    var lspTheme: Theme? { theme }
    var lspFont: NSFont? { codeFont }

    fileprivate func updateLSP(_ context: DiffPaneLSPContext?, theme: Theme) {
        self.theme = theme
        guard let context else {
            lspController?.tearDown()
            lspController = nil
            return
        }
        if lspController == nil {
            lspController = DiffPaneLSPController(textView: self)
        }
        lspController?.update(context: context, allowedSide: .new)
    }

    func characterIndex(at point: NSPoint) -> Int? {
        guard side(at: point) == .new, codeRect(.new).contains(point),
              let position = textPosition(at: point, side: .new, characterUnder: true),
              new.metadata.indices.contains(position.row)
        else { return nil }
        return new.metadata[position.row].range.location + position.index
    }

    func symbolRange(at point: NSPoint) -> NSRange? {
        guard let index = characterIndex(at: point) else { return nil }
        let range = lspDocument.rangeOfWord(at: index)
        return range.length == 0 ? nil : range
    }

    /// The first glyph of `range`, where hover panels anchor.
    /// Where `row`'s characters `start..<end` on `side` draw: the glyphs'
    /// own span on one visual line, or the full width of the visual lines
    /// a wrapped range crosses.
    func textRect(_ side: Side, row: Int, from start: Int, to end: Int) -> NSRect {
        let sideLines = lines(side)
        let code = codeRect(side)
        guard sideLines.code.indices.contains(row) else { return code }
        let layout = layout(forWidth: bounds.width)
        let length = (sideLines.codeStrings[row] as NSString).length
        let start = min(max(0, start), length), end = min(max(start, end), length)
        let parts = wraps ? ((side == .old ? layout.old : layout.new)?[row] ?? []) : [sideLines.code[row]]
        guard !parts.isEmpty else { return code }
        let part = { (index: Int) in parts.lastIndex { CTLineGetStringRange($0).location <= index } ?? 0 }
        let first = part(start), last = part(max(start, end - 1))
        let top = codeTop + layout.tops[row] + CGFloat(first) * lineHeight
        guard first == last else {
            return NSRect(x: code.minX, y: top, width: code.width, height: CGFloat(last - first + 1) * lineHeight)
        }
        let originX = code.minX + Self.textInset + (sideLines.indents[row] ?? 0) - (wraps ? 0 : horizontalScroll.offset(side))
        let minX = CTLineGetOffsetForStringIndex(parts[first], start, nil)
        let maxX = CTLineGetOffsetForStringIndex(parts[first], end, nil)
        return NSRect(x: originX + minX, y: top, width: max(1, maxX - minX), height: lineHeight)
    }

    func symbolAnchorRect(for range: NSRange) -> NSRect? {
        guard range.length > 0,
              let row = new.metadata.firstIndex(where: { NSLocationInRange(range.location, $0.range) })
        else { return nil }
        let local = range.location - new.metadata[row].range.location
        let tops = layout(forWidth: bounds.width).tops
        var line = new.code[row]
        var part = 0
        if wraps, let parts = layout(forWidth: bounds.width).new?[row] {
            part = parts.lastIndex(where: { CTLineGetStringRange($0).location <= local }) ?? 0
            line = parts[part]
        }
        let originX = codeRect(.new).minX + Self.textInset + (new.indents[row] ?? 0) - (wraps ? 0 : horizontalScroll.offset(.new))
        let minX = CTLineGetOffsetForStringIndex(line, local, nil)
        let maxX = CTLineGetOffsetForStringIndex(line, local + 1, nil)
        return NSRect(x: originX + minX, y: codeTop + tops[row] + CGFloat(part) * lineHeight, width: max(1, maxX - minX), height: lineHeight)
    }
}

/// A side's code as navigable static text: whole value, characters, and
/// lines, which is how VoiceOver reads a read-only text view. Its own state
/// is immutable after init, and AppKit only uses it on the main thread.
final class CodeAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    private let text: NSString
    /// Where each line starts in `text`.
    private let lineStarts: [Int]

    init(lines: [String]) {
        var starts: [Int] = []
        var location = 0
        for line in lines {
            starts.append(location)
            location += (line as NSString).length + 1
        }
        text = lines.joined(separator: "\n") as NSString
        lineStarts = starts
        super.init()
    }

    override func accessibilityValue() -> Any? { text as String }
    override func accessibilityNumberOfCharacters() -> Int { text.length }
    /// The lines the enclosing scroll view shows, set by the row.
    var visibleLines: (@MainActor @Sendable () -> (start: DiffSplitCoreTextRowView.TextSelection.Position, end: DiffSplitCoreTextRowView.TextSelection.Position)?)?

    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let visibleLines else { return NSRange(location: 0, length: text.length) }
        guard let lines = MainActor.assumeIsolated({ visibleLines() }) else { return NSRange(location: 0, length: 0) }
        let start = lineStarts[lines.start.row] + lines.start.index
        return NSRange(location: start, length: lineStarts[lines.end.row] + lines.end.index - start)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    override func accessibilityLine(for index: Int) -> Int {
        max(0, (lineStarts.lastIndex { $0 <= index }) ?? 0)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard lineStarts.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : text.length
        return NSRange(location: lineStarts[line], length: end - lineStarts[line])
    }

    /// The screen rect of the text from one (line, offset) to another, set
    /// by the row that draws it.
    var frameForLines: (@MainActor @Sendable (_ start: (row: Int, index: Int), _ end: (row: Int, index: Int)) -> NSRect?)?

    typealias Position = DiffSplitCoreTextRowView.TextSelection.Position
    /// The row's selection on this side, and a way to replace it, so
    /// assistive apps can read and set it as in a text view.
    var selection: (@MainActor @Sendable () -> (start: Position, end: Position)?)?
    var select: (@MainActor @Sendable (_ start: Position, _ end: Position) -> Void)?

    private func position(at offset: Int) -> Position {
        let offset = min(max(0, offset), text.length)
        let row = accessibilityLine(for: offset)
        return Position(row: row, index: offset - lineStarts[row])
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard let selection, let span = MainActor.assumeIsolated({ selection() }) else { return NSRange(location: 0, length: 0) }
        let start = lineStarts[span.start.row] + span.start.index
        return NSRange(location: start, length: lineStarts[span.end.row] + span.end.index - start)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let select, range.location != NSNotFound else { return }
        let start = position(at: range.location), end = position(at: NSMaxRange(range))
        MainActor.assumeIsolated { select(start, end) }
    }

    override func accessibilitySelectedText() -> String? {
        accessibilityString(for: accessibilitySelectedTextRange())
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard range.location != NSNotFound, range.location <= text.length else { return accessibilityFrame() }
        let startRow = accessibilityLine(for: range.location)
        let endRow = accessibilityLine(for: max(range.location, NSMaxRange(range) - 1))
        let start = (row: startRow, index: range.location - lineStarts[startRow])
        let end = (row: endRow, index: NSMaxRange(range) - lineStarts[endRow])
        // AppKit asks on the main thread.
        guard let frameForLines else { return accessibilityFrame() }
        return MainActor.assumeIsolated { frameForLines(start, end) } ?? accessibilityFrame()
    }
}

extension DiffSplitCoreTextRowView: NSMenuItemValidation {
    /// Copy only with something selected.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? textSelection.map { !$0.isEmpty } ?? false : true
    }
}
