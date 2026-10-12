import AppKit
import CoreText

/// A split or stacked hunk drawn with CoreText in one view: no text views,
/// scroll views, or rulers. Behind `ALAS_DIFF_CORETEXT`; no selection, hover,
/// LSP, or expansion pills yet. A stacked hunk is one full-width pane, held as
/// the new side.
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
    static let cardCornerRadius: CGFloat = 8

    var representedRowID: String?
    var onIntrinsicSizeInvalidated: ((String) -> Void)?
    private(set) var lastMeasuredWidth: CGFloat?
    private(set) var lineHeight: CGFloat = 16
    var cardEdges = CardEdges.middle {
        didSet { if cardEdges != oldValue { needsDisplay = true } }
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
    private(set) var gutterSelection: GutterSelection? {
        didSet { if gutterSelection != oldValue { needsDisplay = true } }
    }
    private var hoveredGutterRow: (side: Side, row: Int)? {
        didSet { if hoveredGutterRow?.side != oldValue?.side || hoveredGutterRow?.row != oldValue?.row { needsDisplay = true } }
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
        didSet { if hoveredExpansion != oldValue { needsDisplay = true } }
    }
    private var pressedExpansion: ExpansionTarget? {
        didSet { if pressedExpansion != oldValue { needsDisplay = true } }
    }
    private var armedExpansion: (target: ExpansionTarget, optionKey: Bool)?
    private var didSetPointingHand = false
    private var palette: Palette?
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
        layer?.contentsFormat = .RGBA8Uint
    }

    // MARK: - Content

    func configure(
        result: DiffPaneTextDocumentBuilder.SplitResult,
        font: NSFont,
        theme: Theme,
        chrome: HunkChrome? = nil,
        wraps: Bool = false,
        review: ReviewLines = ReviewLines(),
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in }
    ) {
        let sources = [result.oldCode.attributedString, result.oldGutter, result.newCode.attributedString, result.newGutter]
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
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in }
    ) {
        let changed = contentChanged(sources: [result.code.attributedString, result.gutter], stacked: true, wraps: wraps, font: font)
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
        needsDisplay = true
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
        let tops = layout(forWidth: bounds.width).tops
        guard rect.maxY > codeTop, rect.minY < codeTop + (tops.last ?? 0) else { return 0..<0 }
        let first = Self.row(containing: rect.minY - codeTop, rowTops: tops)
        let last = Self.row(containing: rect.maxY - codeTop - 0.001, rowTops: tops) + 1
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
            let oldWidth = isStacked ? 0 : pane(.old, width: width).width - old.gutterWidth - 2 * Self.textInset
            let newWidth = pane(.new, width: width).width - new.gutterWidth - 2 * Self.textInset
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
    private static func wrapped(_ line: NSAttributedString, width: CGFloat) -> [CTLine] {
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
    /// pass, so a resize redraws and re-lays out here rather than stretching
    /// the old layer contents.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        updateViewportWidths()
        layoutSubviewsForContent()
        needsDisplay = true
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
            old: isStacked ? 0 : pane(.old).width - old.gutterWidth,
            new: pane(.new).width - new.gutterWidth
        )
    }

    /// The column `side` draws in: a split half, or the full width for the
    /// new side of a stacked hunk.
    private func pane(_ side: Side, width: CGFloat? = nil) -> NSRect {
        let width = width ?? bounds.width
        if isStacked {
            return side == .new ? NSRect(x: 0, y: 0, width: width, height: bounds.height) : .zero
        }
        let frames = DiffPaneSplitGeometry.frames(containerWidth: width)
        return side == .old ? frames.oldPane : frames.newPane
    }

    func side(at point: NSPoint) -> Side {
        if isStacked { return .new }
        return point.x < DiffPaneSplitGeometry.frames(containerWidth: bounds.width).divider.minX ? .old : .new
    }

    /// The code area of `side`, which scrolls; the gutter beside it does not.
    private func codeRect(_ side: Side) -> NSRect {
        if isStacked, side == .old { return .zero }
        let pane = pane(side)
        let gutter = side == .old ? old.gutterWidth : new.gutterWidth
        return NSRect(
            x: pane.minX + gutter, y: headerHeight,
            width: max(0, pane.width - gutter), height: max(0, bounds.height - headerHeight - bottomPadding)
        )
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

    private func isCommentable(side: Side, row: Int) -> Bool {
        review.allowsSelection && lines(side).metadata.reviewLineAnchor(fromRow: row, toRow: row) != nil
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
        if !beginGutterSelection(at: point) {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let armed = armedExpansion {
            pressedExpansion = expansionTarget(at: point) == armed.target ? armed.target : nil
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
        let point = convert(event.locationInWindow, from: nil)
        let hit = gutterRow(at: point)
        hoveredGutterRow = hit.flatMap { isCommentable(side: $0.side, row: $0.row) ? $0 : nil }
        hoveredExpansion = expansionTarget(at: point)
        if hoveredExpansion != nil {
            NSCursor.pointingHand.set()
            didSetPointingHand = true
        } else if didSetPointingHand {
            NSCursor.arrow.set()
            didSetPointingHand = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredGutterRow = nil
        hoveredExpansion = nil
        if didSetPointingHand {
            NSCursor.arrow.set()
            didSetPointingHand = false
        }
    }

    // MARK: - Context expansion

    /// A gutter click on an expansion row expands it, as the ruler does.
    private func expandFromGutter(at point: NSPoint, optionKey: Bool) -> Bool {
        guard let hit = gutterRow(at: point) else { return false }
        let metadata = lines(hit.side).metadata
        guard metadata.indices.contains(hit.row), let key = metadata[hit.row].expansionKey else { return false }
        let edge = metadata[hit.row].expansionEdge
        let all = optionKey || (key.isShared && edge == nil)
        onContextExpansion(key, all ? .all : .chunk(size: diffContextExpansionChunkSize), edge)
        return true
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
            setNeedsDisplay(codeRect(side))
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
            setNeedsDisplay(codeRect(side))
            updateScroller(side)
        }
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let palette, let context = NSGraphicsContext.current?.cgContext else { return }
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
                fill.setFill()
                codeRow.fill()
                if tone == .placeholder {
                    Self.drawPlaceholderHatch(in: codeRow, color: palette.hatch)
                }
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

    /// Same hatch as `DiffPaneCodeTextView.drawPlaceholderHatch`.
    private static func drawPlaceholderHatch(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let path = NSBezierPath()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += 8
        }
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }

    /// Theme colors resolved once per configure: `Theme.nsColor` bridges from
    /// SwiftUI on every call, too slow to repeat per row on every frame.
    private struct Palette {
        let bg0, bg1, bg2, line, hatch, add, del, accent, accentGutter, accentCode, accentStroke, pillTint, fgMuted, fgFaint: NSColor
        /// Row fills for the code, and the ruler's slightly lighter ones.
        let codeFills: [DiffPaneLineTone: NSColor]
        let gutterFills: [DiffPaneLineTone: NSColor]

        init(theme: Theme) {
            bg0 = theme.nsColor("bg-0")
            bg1 = theme.nsColor("bg-1")
            bg2 = theme.nsColor("bg-2")
            line = theme.nsColor("line")
            hatch = line.withAlphaComponent(0.35)
            add = theme.nsColor("add")
            del = theme.nsColor("del")
            accent = theme.nsColor("accent")
            accentGutter = accent.withAlphaComponent(0.18)
            accentCode = accent.withAlphaComponent(0.12)
            accentStroke = accent.withAlphaComponent(0.82)
            pillTint = theme.nsColor("seg-pill-active-fg")
            fgMuted = theme.nsColor("fg-muted")
            fgFaint = theme.nsColor("fg-faint")
            let placeholder = bg2.withAlphaComponent(0.55)
            let collapsed = theme.nsColor("bg-3").withAlphaComponent(0.72)
            codeFills = [
                .add: add.withAlphaComponent(0.18), .delete: del.withAlphaComponent(0.18),
                .placeholder: placeholder, .collapsed: collapsed,
            ]
            gutterFills = [
                .add: add.withAlphaComponent(0.16), .delete: del.withAlphaComponent(0.16),
                .placeholder: placeholder, .collapsed: collapsed,
            ]
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
            if line.length > 0, let style = line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
               style.minimumLineHeight > 0 || style.maximumLineHeight > 0 || style.firstLineHeadIndent > 0 {
                let lineFont = line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? font
                side.customMetrics[side.code.count] = textKitMetrics(for: lineFont, style: style)
                if style.firstLineHeadIndent > 0 { side.indents[side.code.count] = style.firstLineHeadIndent }
            }
            let ctLine = CTLineCreateWithAttributedString(line)
            side.code.append(ctLine)
            side.attributed.append(line)
            side.codeStrings.append(line.string)
            side.widest = max(side.widest, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
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
