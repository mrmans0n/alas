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

    private struct SideLines {
        var code: [CTLine] = []
        /// Source of `code`, kept to break lines when wrapping.
        var attributed: [NSAttributedString] = []
        var codeStrings: [String] = []
        var labels: [CTLine?] = []
        var tones: [DiffPaneLineTone] = []
        var widest: CGFloat = 0
        /// Line-number gutter width, as `DiffPaneLineNumberRulerView` sizes it.
        var gutterWidth: CGFloat = 42
    }

    private var old = SideLines()
    private var new = SideLines()
    private(set) var isStacked = false
    private(set) var wraps = false
    /// Wrapped lines for the last width laid out; nil when not wrapping.
    private var wrapLayout: WrapLayout?
    private var theme: Theme?
    /// Distance from a line's top to its baseline, as TextKit places it.
    private var baselineOffset: CGFloat = 12
    private var chrome: HunkChrome?
    private var headerLine: CTLine?
    private var headerButtons: [NSButton] = []
    private var headerActions: [@MainActor () -> Void] = []
    private(set) var horizontalScroll = DiffSplitHorizontalScroll()
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
        wraps: Bool = false
    ) {
        isStacked = false
        self.wraps = wraps
        old = Self.lines(code: result.oldCode, gutter: result.oldGutter, theme: theme)
        new = Self.lines(code: result.newCode, gutter: result.newGutter, theme: theme)
        applyContent(font: font, theme: theme, chrome: chrome)
    }

    func configure(
        stacked result: DiffPaneTextDocumentBuilder.StackedResult,
        font: NSFont,
        theme: Theme,
        chrome: HunkChrome? = nil,
        wraps: Bool = false
    ) {
        isStacked = true
        self.wraps = wraps
        old = SideLines()
        new = Self.lines(code: result.code, gutter: result.gutter, theme: theme)
        applyContent(font: font, theme: theme, chrome: chrome)
    }

    private func applyContent(font: NSFont, theme: Theme, chrome: HunkChrome?) {
        self.theme = theme
        let metrics = Self.textKitMetrics(for: font)
        lineHeight = metrics.lineHeight
        baselineOffset = metrics.baselineOffset
        wrapLayout = nil
        // Wrapped lines fit their pane, so there is nothing to scroll sideways.
        horizontalScroll.oldContentWidth = isStacked || wraps ? 0 : old.widest + 2 * Self.textInset
        horizontalScroll.newContentWidth = wraps ? 0 : new.widest + 2 * Self.textInset
        // New content starts at the leading edge, as the panes do today.
        horizontalScroll.resetToLeading()
        applyChrome(chrome, theme: theme)
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
        let visualLines = wraps ? layout(forWidth: width).rowStarts.last ?? 0 : lineCount
        return headerHeight + CGFloat(visualLines) * lineHeight + 2 * Self.verticalInset + bottomPadding
    }

    func attach(to documentView: NSView) {
        documentView.addSubview(self)
    }

    func suppressNextLayoutForStableScroll() {}

    /// The rows (logical lines) that intersect `rect`.
    func visibleLineRange(in rect: NSRect) -> Range<Int> {
        guard lineCount > 0, lineHeight > 0 else { return 0..<0 }
        let firstVisual = max(0, Int(floor((rect.minY - codeTop) / lineHeight)))
        let lastVisual = Int(ceil((rect.maxY - codeTop) / lineHeight))
        guard wraps else {
            let last = min(lineCount, lastVisual)
            return firstVisual < last ? firstVisual..<last : firstVisual..<firstVisual
        }
        let starts = layout(forWidth: bounds.width).rowStarts
        // The row containing `firstVisual`, through the last row starting before `lastVisual`.
        let first = Self.row(containingVisualLine: firstVisual, rowStarts: starts)
        let last = min(lineCount, Self.row(containingVisualLine: max(firstVisual, lastVisual - 1), rowStarts: starts) + 1)
        return first < last ? first..<last : first..<first
    }

    // MARK: - Wrapping

    private struct WrapLayout {
        let width: CGFloat
        let old: [[CTLine]]
        let new: [[CTLine]]
        /// Visual line each row starts at; one extra entry holds the total.
        let rowStarts: [Int]
    }

    /// Where each row starts when a row is as tall as its taller side, so
    /// old and new lines stay level. The last entry is the total line count.
    static func rowStarts(oldLineCounts: [Int], newLineCounts: [Int]) -> [Int] {
        var starts = [0]
        starts.reserveCapacity(max(oldLineCounts.count, newLineCounts.count) + 1)
        for index in 0..<max(oldLineCounts.count, newLineCounts.count) {
            let old = oldLineCounts.indices.contains(index) ? oldLineCounts[index] : 0
            let new = newLineCounts.indices.contains(index) ? newLineCounts[index] : 0
            starts.append(starts[starts.count - 1] + max(1, old, new))
        }
        return starts
    }

    static func row(containingVisualLine line: Int, rowStarts: [Int]) -> Int {
        // Last start at or before `line`.
        var low = 0, high = max(0, rowStarts.count - 2)
        while low < high {
            let mid = (low + high + 1) / 2
            if rowStarts[mid] <= line { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func layout(forWidth width: CGFloat) -> WrapLayout {
        if let wrapLayout, wrapLayout.width == width { return wrapLayout }
        let oldWidth = isStacked ? 0 : pane(.old, width: width).width - old.gutterWidth - 2 * Self.textInset
        let newWidth = pane(.new, width: width).width - new.gutterWidth - 2 * Self.textInset
        let oldLines = isStacked ? [] : old.attributed.map { Self.wrapped($0, width: oldWidth) }
        let newLines = new.attributed.map { Self.wrapped($0, width: newWidth) }
        let layout = WrapLayout(
            width: width, old: oldLines, new: newLines,
            rowStarts: Self.rowStarts(oldLineCounts: oldLines.map(\.count), newLineCounts: newLines.map(\.count))
        )
        wrapLayout = layout
        return layout
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

    private func applyChrome(_ chrome: HunkChrome?, theme: Theme) {
        self.chrome = chrome
        headerLine = chrome.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0.header, attributes: [
                .font: $0.headerFont,
                .foregroundColor: theme.nsColor("fg-muted"),
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
        if !scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas, at: location) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    /// Applies a wheel gesture at `point`. Returns false for gestures the
    /// review should scroll instead: those whose vertical motion dominates.
    func scroll(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool, at point: NSPoint) -> Bool {
        guard abs(deltaX) >= abs(deltaY), deltaX != 0 else { return false }
        let side = side(at: point)
        let delta = -DiffSplitHorizontalScroll.pointDelta(scrollingDeltaX: deltaX, isPrecise: isPrecise, lineHeight: lineHeight)
        if horizontalScroll.scroll(side, byPoints: delta) {
            setNeedsDisplay(codeRect(side))
            updateScroller(side)
        }
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let cardRect = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bottomPadding))
        let fusion = chrome?.fusion ?? .none
        let hunkPath = chrome == nil ? nil : Self.hunkCardPath(in: cardRect, fusion: fusion)

        theme.nsColor("bg-1").setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height).intersection(dirtyRect).fill()

        context.saveGState()
        if let hunkPath { hunkPath.addClip() }
        drawHeader(theme: theme, context: context, dirtyRect: dirtyRect)
        let range = visibleLineRange(in: dirtyRect)
        let wrapped = wraps ? layout(forWidth: bounds.width) : nil
        if !isStacked {
            draw(old, wrapped: wrapped?.old, rowStarts: wrapped?.rowStarts, in: pane(.old), offset: horizontalScroll.offset(.old), range: range, theme: theme, context: context)
        }
        draw(new, wrapped: wrapped?.new, rowStarts: wrapped?.rowStarts, in: pane(.new), offset: horizontalScroll.offset(.new), range: range, theme: theme, context: context)
        if !isStacked {
            let divider = DiffPaneSplitGeometry.frames(containerWidth: bounds.width).divider
            theme.nsColor("line").setFill()
            NSRect(x: divider.minX, y: max(dirtyRect.minY, headerHeight), width: divider.width, height: dirtyRect.height).fill()
        }
        context.restoreGState()

        if let hunkPath {
            theme.nsColor("line").setStroke()
            hunkPath.lineWidth = 0.75
            hunkPath.stroke()
        }
        drawFileCardEdges(theme: theme)
    }

    private func drawHeader(theme: Theme, context: CGContext, dirtyRect: NSRect) {
        guard chrome != nil, let headerLine, dirtyRect.minY < headerHeight else { return }
        theme.nsColor("bg-2").setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
        theme.nsColor("line").setFill()
        NSRect(x: 0, y: headerHeight - 0.5, width: bounds.width, height: 0.5).fill()
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(headerLine, &ascent, &descent, nil)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: Self.headerHorizontalPadding, y: (headerHeight + ascent - descent) / 2)
        CTLineDraw(headerLine, context)
        context.restoreGState()
    }

    /// Draws `side`'s rows in `range`. When wrapping, `wrapped` holds each
    /// row's visual lines and `rowStarts` where each row begins.
    private func draw(
        _ side: SideLines, wrapped: [[CTLine]]?, rowStarts: [Int]?,
        in pane: CGRect, offset: CGFloat, range: Range<Int>, theme: Theme, context: CGContext
    ) {
        let gutter = side.gutterWidth
        context.saveGState()
        context.clip(to: CGRect(x: pane.minX, y: headerHeight, width: pane.width, height: max(0, bounds.height - headerHeight)))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // The gutter column, as `DiffPaneLineNumberRulerView` paints it.
        theme.nsColor("bg-0").setFill()
        NSRect(x: pane.minX, y: headerHeight, width: gutter, height: max(0, bounds.height - headerHeight - bottomPadding)).fill()
        for index in range {
            let y = codeTop + CGFloat(rowStarts?[index] ?? index) * lineHeight
            let rowHeight = rowStarts.map { CGFloat($0[index + 1] - $0[index]) * lineHeight } ?? lineHeight
            let tone = side.tones.indices.contains(index) ? side.tones[index] : .context
            if let fill = Self.fill(for: tone, theme: theme) {
                let codeRow = NSRect(x: pane.minX + gutter, y: y, width: max(0, pane.width - gutter), height: rowHeight)
                fill.setFill()
                codeRow.fill()
                if tone == .placeholder {
                    Self.drawPlaceholderHatch(in: codeRow, theme: theme)
                }
            }
            let gutterRow = NSRect(x: pane.minX, y: y, width: gutter, height: rowHeight)
            if let fill = Self.gutterFill(for: tone, theme: theme) {
                fill.setFill()
                gutterRow.fill()
            }
            if tone == .add || tone == .delete {
                theme.nsColor(tone == .add ? "add" : "del").setFill()
                NSRect(x: gutterRow.minX, y: gutterRow.minY, width: 3, height: gutterRow.height).fill()
            }
            let baseline = y + baselineOffset
            if side.labels.indices.contains(index), let label = side.labels[index] {
                let width = CTLineGetTypographicBounds(label, nil, nil, nil)
                context.textPosition = CGPoint(x: pane.minX + gutter - DiffPaneLineNumberGutterGeometry.horizontalPadding - width, y: baseline)
                CTLineDraw(label, context)
            }
            if let wrapped {
                guard wrapped.indices.contains(index) else { continue }
                for (part, line) in wrapped[index].enumerated() {
                    context.textPosition = CGPoint(x: pane.minX + gutter + Self.textInset, y: baseline + CGFloat(part) * lineHeight)
                    CTLineDraw(line, context)
                }
            } else if side.code.indices.contains(index) {
                context.saveGState()
                context.clip(to: CGRect(x: pane.minX + gutter, y: y, width: max(0, pane.width - gutter), height: lineHeight))
                context.textPosition = CGPoint(x: pane.minX + gutter + Self.textInset - offset, y: baseline)
                CTLineDraw(side.code[index], context)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    /// The review's file-card border: the sides always, top and bottom with
    /// rounded corners where this row starts or ends the card.
    private func drawFileCardEdges(theme: Theme) {
        let rect = bounds.insetBy(dx: 0.375, dy: 0.375)
        let radius = Self.cardCornerRadius
        let path = NSBezierPath()
        if cardEdges.top {
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: NSPoint(x: rect.minX, y: bounds.minY))
            path.line(to: NSPoint(x: rect.minX, y: bounds.maxY))
            path.move(to: NSPoint(x: rect.maxX, y: bounds.minY))
            path.line(to: NSPoint(x: rect.maxX, y: bounds.maxY))
        }
        if cardEdges.bottom {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX + radius, y: rect.maxY), radius: radius)
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.maxX, y: rect.maxY - radius), radius: radius)
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        theme.nsColor("line").setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    private static func hunkCardPath(in rect: NSRect, fusion: DiffPaneHunkFusionState) -> NSBezierPath {
        let top = fusion.fusedWithPrevious ? 0 : hunkCornerRadius
        let bottom = fusion.fusedWithNext ? 0 : hunkCornerRadius
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
    private static func drawPlaceholderHatch(in rect: NSRect, theme: Theme) {
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
        theme.nsColor("line").withAlphaComponent(0.35).setStroke()
        path.stroke()
    }

    /// The ruler's row fill, slightly lighter than the code's.
    private static func gutterFill(for tone: DiffPaneLineTone, theme: Theme) -> NSColor? {
        switch tone {
        case .add: theme.nsColor("add").withAlphaComponent(0.16)
        case .delete: theme.nsColor("del").withAlphaComponent(0.16)
        case .placeholder: theme.nsColor("bg-2").withAlphaComponent(0.55)
        case .collapsed: theme.nsColor("bg-3").withAlphaComponent(0.72)
        case .context: nil
        }
    }

    private static func fill(for tone: DiffPaneLineTone, theme: Theme) -> NSColor? {
        switch tone {
        case .add: theme.nsColor("add").withAlphaComponent(0.18)
        case .delete: theme.nsColor("del").withAlphaComponent(0.18)
        case .placeholder: theme.nsColor("bg-2").withAlphaComponent(0.55)
        case .collapsed: theme.nsColor("bg-3").withAlphaComponent(0.72)
        case .context: nil
        }
    }

    /// Same coloring as `DiffPaneLineNumberRulerView.labelAttributes`.
    private static func labelColor(_ label: String, tone: DiffPaneLineTone, theme: Theme) -> NSColor {
        if tone == .add || label.hasPrefix("+") { return theme.nsColor("add") }
        if tone == .delete || label.hasPrefix("-") { return theme.nsColor("del") }
        return theme.nsColor("fg-faint")
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

    private static func textKitMetrics(for font: NSFont) -> TextKitMetrics {
        let key = "\(font.fontName)|\(font.pointSize)"
        if let cached = metricsCache[key] { return cached }
        let storage = NSTextStorage(string: "X\nX", attributes: [
            .font: font,
            .paragraphStyle: CenterTypography.paragraphStyle(),
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
        theme: Theme
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
            side.labels.append(label.isEmpty ? nil : CTLineCreateWithAttributedString(NSAttributedString(
                string: label,
                attributes: [.font: DiffPaneLineNumberGutterGeometry.labelFont, .foregroundColor: labelColor(label, tone: tone, theme: theme)]
            )))
        }
        return side
    }
}
