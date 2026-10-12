import AppKit
import CoreText

/// A split hunk drawn with CoreText in one view: no text views, scroll
/// views, or rulers. Behind `ALAS_DIFF_CORETEXT`; unwrapped only, and no
/// selection, hover, LSP, or expansion pills yet.
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
        var codeStrings: [String] = []
        var labels: [CTLine?] = []
        var tones: [DiffPaneLineTone] = []
        var widest: CGFloat = 0
        /// Line-number gutter width, as `DiffPaneLineNumberRulerView` sizes it.
        var gutterWidth: CGFloat = 42
    }

    private var old = SideLines()
    private var new = SideLines()
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
        chrome: HunkChrome? = nil
    ) {
        self.theme = theme
        let metrics = Self.textKitMetrics(for: font)
        lineHeight = metrics.lineHeight
        baselineOffset = metrics.baselineOffset
        old = Self.lines(code: result.oldCode, gutter: result.oldGutter, theme: theme)
        new = Self.lines(code: result.newCode, gutter: result.newGutter, theme: theme)
        horizontalScroll.oldContentWidth = old.widest + 2 * Self.textInset
        horizontalScroll.newContentWidth = new.widest + 2 * Self.textInset
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
        return headerHeight + CGFloat(lineCount) * lineHeight + 2 * Self.verticalInset + bottomPadding
    }

    func attach(to documentView: NSView) {
        documentView.addSubview(self)
    }

    func suppressNextLayoutForStableScroll() {}

    func visibleLineRange(in rect: NSRect) -> Range<Int> {
        guard lineCount > 0, lineHeight > 0 else { return 0..<0 }
        let first = max(0, Int(floor((rect.minY - codeTop) / lineHeight)))
        let last = min(lineCount, Int(ceil((rect.maxY - codeTop) / lineHeight)))
        return first < last ? first..<last : first..<first
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
        let frames = DiffPaneSplitGeometry.frames(containerWidth: bounds.width)
        horizontalScroll.setViewportWidths(
            old: frames.oldPane.width - old.gutterWidth,
            new: frames.newPane.width - new.gutterWidth
        )
    }

    func side(at point: NSPoint) -> Side {
        point.x < DiffPaneSplitGeometry.frames(containerWidth: bounds.width).divider.minX ? .old : .new
    }

    /// The code area of `side`, which scrolls; the gutter beside it does not.
    private func codeRect(_ side: Side) -> NSRect {
        let frames = DiffPaneSplitGeometry.frames(containerWidth: bounds.width)
        let pane = side == .old ? frames.oldPane : frames.newPane
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
        let frames = DiffPaneSplitGeometry.frames(containerWidth: bounds.width)
        let range = visibleLineRange(in: dirtyRect)
        draw(old, in: frames.oldPane, offset: horizontalScroll.offset(.old), range: range, theme: theme, context: context)
        draw(new, in: frames.newPane, offset: horizontalScroll.offset(.new), range: range, theme: theme, context: context)
        theme.nsColor("line").setFill()
        NSRect(x: frames.divider.minX, y: max(dirtyRect.minY, headerHeight), width: frames.divider.width, height: dirtyRect.height).fill()
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

    private func draw(_ side: SideLines, in pane: CGRect, offset: CGFloat, range: Range<Int>, theme: Theme, context: CGContext) {
        let gutter = side.gutterWidth
        context.saveGState()
        context.clip(to: CGRect(x: pane.minX, y: headerHeight, width: pane.width, height: max(0, bounds.height - headerHeight)))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // The gutter column, as `DiffPaneLineNumberRulerView` paints it.
        theme.nsColor("bg-0").setFill()
        NSRect(x: pane.minX, y: headerHeight, width: gutter, height: max(0, bounds.height - headerHeight - bottomPadding)).fill()
        for index in range {
            let y = codeTop + CGFloat(index) * lineHeight
            let tone = side.tones.indices.contains(index) ? side.tones[index] : .context
            if let fill = Self.fill(for: tone, theme: theme) {
                let codeRow = NSRect(x: pane.minX + gutter, y: y, width: max(0, pane.width - gutter), height: lineHeight)
                fill.setFill()
                codeRow.fill()
                if tone == .placeholder {
                    Self.drawPlaceholderHatch(in: codeRow, theme: theme)
                }
            }
            let gutterRow = NSRect(x: pane.minX, y: y, width: gutter, height: lineHeight)
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
            if side.code.indices.contains(index) {
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
