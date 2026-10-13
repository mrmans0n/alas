import AppKit
import CoreText

/// A common transcript row drawn with CoreText in one view instead of a
/// SwiftUI host: agent prose, commentary, a collapsed thought, a collapsed
/// tool call, a tool-call group header, and the user bubble. Draw-only: no
/// hover, clicks, selection, menus, or accessibility.
@MainActor
final class ACPTranscriptCoreTextRowView: NSView, ACPTranscriptRowView {
    enum Content: Equatable, Sendable {
        /// Agent markdown; `commentary` adds the narration lane and "Working…" header.
        case agent(markdown: String, commentary: Bool)
        /// A collapsed thought.
        case thought(label: String)
        /// A collapsed tool call.
        case toolCall(presentation: ACPToolCallPresentation, target: String?, duration: String?, failed: Bool)
        /// A tool-call group header, without the "Show N earlier" button.
        case toolGroupHeader(label: String, iconSystemName: String, expanded: Bool)
        /// The user's prompt in its right-aligned bubble.
        case user(markdown: String)
    }

    // Copied from `wrapRow`, `ACPCommentaryRow`, `ACPThoughtView`,
    // `ACPToolCallCard`, `ACPToolCallGroupHeaderRow`, `ACPToolCallGroupLane`,
    // `UserMessageRow`, and `ACPUserBubbleChrome`.
    static let columnHorizontalPadding: CGFloat = 28
    static let laneBarWidth: CGFloat = 1.5
    static let laneBarVerticalPadding: CGFloat = 2
    static let laneSpacing: CGFloat = 12
    static let groupMemberIndent: CGFloat = 7
    static let narrationFontSize: CGFloat = 11
    static let narrationIconSpacing: CGFloat = 7
    static let narrationHeaderSpacing: CGFloat = 6
    static let iconPointSize: CGFloat = 11
    static let iconFrameWidth: CGFloat = 16
    static let toolSpacing: CGFloat = 8
    static let toolLabelSize: CGFloat = 12
    static let toolTargetSize: CGFloat = 11.5
    static let toolTargetHorizontalPadding: CGFloat = 5
    static let toolTargetVerticalPadding: CGFloat = 1
    static let toolTargetCornerRadius: CGFloat = 4
    static let toolSpacerMinLength: CGFloat = 6
    static let toolDurationSize: CGFloat = 10
    static let toolVerticalPadding: CGFloat = 3
    static let statusPointSize: CGFloat = 9
    static let chevronPointSize: CGFloat = 9
    static let groupHeaderSpacing: CGFloat = 7
    static let bubbleMaxWidthFraction: CGFloat = 0.75
    static let bubbleLeadingMinSpace: CGFloat = 40
    static let bubbleHorizontalPadding: CGFloat = 13
    static let bubbleVerticalPadding: CGFloat = 9
    static let bubbleCornerRadius: CGFloat = 12
    static let bubbleTailCornerRadius: CGFloat = 4
    static let bubbleStrokeWidth: CGFloat = 0.5
    static let bubbleTopAlpha: CGFloat = 0.32
    static let bubbleBottomAlpha: CGFloat = 0.20
    static let bubbleStrokeAlpha: CGFloat = 0.5
    /// Symbols are rendered once at this scale; Retina is the common case.
    static let symbolScale: CGFloat = 2

    var onIntrinsicSizeInvalidated: (() -> Void)?
    private(set) var lastMeasuredWidth: CGFloat?
    private(set) var needsRemeasure = false

    private var content: Content?
    private var contentMaxWidth: CGFloat = ACPChatLayout.defaultContentMaxWidth
    private var inToolCallGroup = false
    private var theme: Theme?
    private var typography: ACPChatTypography = .default
    private var palette: Palette?
    private var symbols: [SymbolRole: Symbol] = [:]
    private var cachedLayout: Layout?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTileScale()
        observeClipView()
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
        content: Content, contentMaxWidth: CGFloat, inToolCallGroup: Bool, theme: Theme, typography: ACPChatTypography
    ) {
        let sizeChanged = content != self.content || contentMaxWidth != self.contentMaxWidth
            || inToolCallGroup != self.inToolCallGroup || typography != self.typography
        guard sizeChanged || theme != self.theme else { return }
        self.content = content
        self.contentMaxWidth = contentMaxWidth
        self.inToolCallGroup = inToolCallGroup
        self.theme = theme
        self.typography = typography
        let palette = Palette(theme: theme)
        self.palette = palette
        symbols = Self.renderSymbols(for: content, palette: palette)
        cachedLayout = nil
        invalidateTiles()
        if sizeChanged { onIntrinsicSizeInvalidated?() }
    }

    func markNeedsRemeasure() {
        needsRemeasure = true
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        needsRemeasure = false
        lastMeasuredWidth = width
        return layout(forWidth: width).height
    }

    /// The content column, in view coordinates, at `lastMeasuredWidth`.
    var columnRect: CGRect {
        guard let lastMeasuredWidth else { return .zero }
        return layout(forWidth: lastMeasuredWidth).column
    }

    // MARK: - Layout

    /// Something to draw, positioned in view coordinates.
    private enum Item {
        case fill(CGRect, NSColor, cornerRadius: CGFloat)
        /// A one-line label; `origin` is its baseline start.
        case text(CTLine, origin: CGPoint)
        case symbol(CGImage, CGRect)
        /// Markdown lines and backgrounds, offset by `origin`; `ascents` parallels its lines.
        case markdown(ACPTranscriptMarkdownLayout, origin: CGPoint, ascents: [CGFloat])
        case bubble(CGRect)
    }

    private struct Layout {
        let width: CGFloat
        let height: CGFloat
        let column: CGRect
        let items: [Item]
    }

    private func layout(forWidth width: CGFloat) -> Layout {
        if let cachedLayout, cachedLayout.width == width { return cachedLayout }
        let layout = makeLayout(width: width)
        cachedLayout = layout
        return layout
    }

    private func makeLayout(width: CGFloat) -> Layout {
        let columnWidth = max(0, min(contentMaxWidth, width - 2 * (Self.columnHorizontalPadding + ACPMessageGutterLayout.laneWidth)))
        let column = CGRect(x: ((width - columnWidth) / 2).rounded(), y: 0, width: columnWidth, height: 0)
        guard let content, let palette, let theme else {
            return Layout(width: width, height: 0, column: column, items: [])
        }
        var builder = LayoutBuilder(x: column.minX, maxX: column.maxX, palette: palette, symbols: symbols)
        if inToolCallGroup {
            builder.x += Self.groupMemberIndent
            builder.addLane()
        }
        switch content {
        case .agent(let markdown, let commentary):
            if commentary {
                builder.addLane()
                builder.addNarrationHeader(symbol: .leading, label: "Working…")
                builder.y += Self.narrationHeaderSpacing
            }
            builder.addMarkdown(markdown, width: builder.maxX - builder.x, theme: theme, typography: typography)
        case .thought(let label):
            builder.addLane()
            builder.addNarrationHeader(symbol: .leading, label: label)
        case .toolCall(let presentation, let target, let duration, _):
            builder.addToolCall(target: target, duration: duration, label: presentation.label)
        case .toolGroupHeader(let label, _, _):
            builder.addGroupHeader(label: label)
        case .user(let markdown):
            builder.addUserBubble(markdown, contentMaxWidth: contentMaxWidth, theme: theme, typography: typography)
        }
        return builder.finish(width: width, column: column)
    }

    /// Accumulates items left to right and top to bottom from `x`/`y`.
    @MainActor
    private struct LayoutBuilder {
        var x: CGFloat
        let maxX: CGFloat
        let palette: Palette
        let symbols: [SymbolRole: Symbol]
        var y: CGFloat = 0
        var items: [Item] = []
        var lanes: [CGFloat] = []

        typealias V = ACPTranscriptCoreTextRowView

        mutating func addLane() {
            lanes.append(x)
            x += V.laneBarWidth + V.laneSpacing
        }

        /// Icon and label, as the narration rows' header `HStack(spacing: 7)`.
        mutating func addNarrationHeader(symbol role: SymbolRole, label: String) {
            let font = NSFont.systemFont(ofSize: V.narrationFontSize)
            let symbol = symbols[role]
            let height = max(V.lineHeight(font), symbol?.size.height ?? 0)
            var cursor = x
            if let symbol {
                place(symbol, x: cursor, rowTop: y, rowHeight: height)
                cursor += symbol.size.width + V.narrationIconSpacing
            }
            let line = V.line(label, font: font, color: palette.fgFaint, maxWidth: maxX - cursor, truncation: .end)
            addText(line, x: cursor, rowTop: y, rowHeight: height)
            y += height
        }

        mutating func addMarkdown(_ source: String, width: CGFloat, theme: Theme, typography: ACPChatTypography) {
            guard let markdown = ACPTranscriptMarkdownLayout.make(source: source, width: width, theme: theme, typography: typography)
            else { return }
            items.append(.markdown(markdown, origin: CGPoint(x: x, y: y), ascents: V.ascents(of: markdown)))
            y += markdown.height
        }

        /// The collapsed `ACPToolCallCard` header: icon, label, target chip,
        /// spacer, duration, failure mark, chevron.
        mutating func addToolCall(target: String?, duration: String?, label: String) {
            let labelFont = NSFont.systemFont(ofSize: V.toolLabelSize)
            let targetFont = NSFont.monospacedSystemFont(ofSize: V.toolTargetSize, weight: .regular)
            let durationFont = NSFont.monospacedSystemFont(ofSize: V.toolDurationSize, weight: .medium)
            let chipHeight = V.lineHeight(targetFont) + 2 * V.toolTargetVerticalPadding
            let symbolHeights = [SymbolRole.leading, .status, .chevron].compactMap { symbols[$0]?.size.height }
            let height = ([V.lineHeight(labelFont), chipHeight] + symbolHeights).max() ?? 0
            let top = y + V.toolVerticalPadding

            // Trailing items, right to left.
            var trailing = maxX
            if let chevron = symbols[.chevron] {
                trailing -= chevron.size.width
                place(chevron, x: trailing, rowTop: top, rowHeight: height)
                trailing -= V.toolSpacing
            }
            if let status = symbols[.status] {
                trailing -= status.size.width
                place(status, x: trailing, rowTop: top, rowHeight: height)
                trailing -= V.toolSpacing
            }
            if let duration {
                let line = V.line(duration, font: durationFont, color: palette.fgFaint)
                trailing -= V.width(of: line)
                addText(line, x: trailing, rowTop: top, rowHeight: height)
                trailing -= V.toolSpacing
            }
            trailing += V.toolSpacing - V.toolSpacerMinLength

            var cursor = x
            if let icon = symbols[.leading] {
                place(icon, x: cursor + (V.iconFrameWidth - icon.size.width) / 2, rowTop: top, rowHeight: height)
            }
            cursor += V.iconFrameWidth + V.toolSpacing
            let labelLine = V.line(label, font: labelFont, color: palette.fgFaint, maxWidth: trailing - cursor, truncation: .end)
            addText(labelLine, x: cursor, rowTop: top, rowHeight: height)
            cursor += V.width(of: labelLine) + V.toolSpacing
            let targetWidth = trailing - cursor - 2 * V.toolTargetHorizontalPadding
            if let target, targetWidth > 0 {
                let line = V.line(target, font: targetFont, color: palette.fgDim, maxWidth: targetWidth, truncation: .middle)
                let chip = CGRect(
                    x: cursor, y: top + (height - chipHeight) / 2,
                    width: V.width(of: line) + 2 * V.toolTargetHorizontalPadding, height: chipHeight
                )
                items.append(.fill(chip, palette.bg2, cornerRadius: V.toolTargetCornerRadius))
                addText(line, x: cursor + V.toolTargetHorizontalPadding, rowTop: top, rowHeight: height)
            }
            y = top + height + V.toolVerticalPadding
        }

        /// `ACPToolCallGroupHeaderRow`'s toggle: icon in a 16pt frame, label, chevron.
        mutating func addGroupHeader(label: String) {
            let font = NSFont.systemFont(ofSize: V.toolLabelSize)
            let symbolHeights = [SymbolRole.leading, .chevron].compactMap { symbols[$0]?.size.height }
            let height = ([V.lineHeight(font)] + symbolHeights).max() ?? 0
            var cursor = x
            if let icon = symbols[.leading] {
                place(icon, x: cursor + (V.iconFrameWidth - icon.size.width) / 2, rowTop: y, rowHeight: height)
            }
            cursor += V.iconFrameWidth + V.groupHeaderSpacing
            let chevron = symbols[.chevron]
            let chevronSpace = chevron.map { $0.size.width + V.groupHeaderSpacing } ?? 0
            let line = V.line(label, font: font, color: palette.fgFaint, maxWidth: maxX - cursor - chevronSpace, truncation: .end)
            addText(line, x: cursor, rowTop: y, rowHeight: height)
            cursor += V.width(of: line) + V.groupHeaderSpacing
            if let chevron { place(chevron, x: cursor, rowTop: y, rowHeight: height) }
            y += height
        }

        /// The bubble hugs its text up to three quarters of the column, as
        /// `UserMessageRow` frames it, leaving at least its leading spacer.
        mutating func addUserBubble(_ source: String, contentMaxWidth: CGFloat, theme: Theme, typography: ACPChatTypography) {
            let maxBubble = max(0, min(contentMaxWidth * V.bubbleMaxWidthFraction, maxX - x - V.bubbleLeadingMinSpace))
            let textWidth = max(1, maxBubble - 2 * V.bubbleHorizontalPadding)
            let markdown = ACPTranscriptMarkdownLayout.make(source: source, width: textWidth, theme: theme, typography: typography)
            let used = markdown.map(V.usedWidth(of:)) ?? 0
            let bubbleWidth = min(maxBubble, ceil(used) + 2 * V.bubbleHorizontalPadding)
            let bubble = CGRect(
                x: maxX - bubbleWidth, y: y, width: bubbleWidth,
                height: (markdown?.height ?? 0) + 2 * V.bubbleVerticalPadding
            )
            items.append(.bubble(bubble))
            if let markdown {
                let origin = CGPoint(x: bubble.minX + V.bubbleHorizontalPadding, y: bubble.minY + V.bubbleVerticalPadding)
                items.append(.markdown(markdown, origin: origin, ascents: V.ascents(of: markdown)))
            }
            y = bubble.maxY
        }

        mutating func place(_ symbol: Symbol, x: CGFloat, rowTop: CGFloat, rowHeight: CGFloat) {
            let rect = CGRect(x: x, y: rowTop + (rowHeight - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
            items.append(.symbol(symbol.image, rect))
        }

        /// Centers the line's glyph box in the row, as an `HStack` does.
        mutating func addText(_ line: CTLine, x: CGFloat, rowTop: CGFloat, rowHeight: CGFloat) {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            items.append(.text(line, origin: CGPoint(x: x, y: rowTop + (rowHeight + ascent - descent) / 2)))
        }

        func finish(width: CGFloat, column: CGRect) -> Layout {
            let height = ceil(y)
            let lanes = lanes.map { lane -> Item in
                .fill(CGRect(
                    x: lane, y: V.laneBarVerticalPadding,
                    width: V.laneBarWidth, height: max(0, height - 2 * V.laneBarVerticalPadding)
                ), palette.bg4, cornerRadius: 0)
            }
            return Layout(width: width, height: height, column: column, items: lanes + items)
        }
    }

    // MARK: - Text helpers

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    private static func line(
        _ string: String, font: NSFont, color: NSColor, maxWidth: CGFloat? = nil, truncation: CTLineTruncationType = .end
    ) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        guard let maxWidth, width(of: line) > maxWidth else { return line }
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        return CTLineCreateTruncatedLine(line, Double(max(0, maxWidth)), truncation, ellipsis) ?? line
    }

    private static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func ascents(of markdown: ACPTranscriptMarkdownLayout) -> [CGFloat] {
        markdown.lines.map { line in
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line.line, &ascent, nil, nil)
            return ascent
        }
    }

    /// How wide the markdown actually draws: its widest line or background.
    private static func usedWidth(of markdown: ACPTranscriptMarkdownLayout) -> CGFloat {
        let lines = markdown.lines.map { $0.origin.x + width(of: $0.line) }
        let backgrounds = markdown.backgrounds.map(\.rect.maxX)
        return (lines + backgrounds).max() ?? 0
    }

    // MARK: - Symbols

    private enum SymbolRole: Hashable {
        case leading, status, chevron
    }

    private struct Symbol {
        let image: CGImage
        let size: CGSize
    }

    private static func renderSymbols(for content: Content, palette: Palette) -> [SymbolRole: Symbol] {
        var specs: [SymbolRole: (name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor)] = [:]
        switch content {
        case .agent(_, let commentary):
            if commentary { specs[.leading] = ("hammer", narrationFontSize, .regular, palette.fgFaint) }
        case .thought:
            specs[.leading] = ("brain", narrationFontSize, .regular, palette.fgFaint)
        case .toolCall(let presentation, _, _, let failed):
            specs[.leading] = (presentation.iconSystemName, iconPointSize, .regular, palette.fgFaint)
            if failed { specs[.status] = ("xmark", statusPointSize, .bold, palette.del) }
            specs[.chevron] = ("chevron.down", chevronPointSize, .regular, palette.fgFaint)
        case .toolGroupHeader(_, let iconSystemName, let expanded):
            specs[.leading] = (iconSystemName, iconPointSize, .regular, palette.fgFaint)
            specs[.chevron] = (expanded ? "chevron.down" : "chevron.right", chevronPointSize, .regular, palette.fgFaint)
        case .user:
            break
        }
        return specs.compactMapValues { renderSymbol($0.name, pointSize: $0.size, weight: $0.weight, color: $0.color) }
    }

    /// Draws a symbol once into a bitmap tinted `color`.
    private static func renderSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> Symbol? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)),
            let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0, let context = CGContext(
            data: nil, width: Int(ceil(size.width * symbolScale)), height: Int(ceil(size.height * symbolScale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: symbolScale, y: symbolScale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        context.setBlendMode(.sourceIn)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage().map { Symbol(image: $0, size: size) }
    }

    // MARK: - Palette

    /// Theme colors resolved once per configure.
    @MainActor
    private struct Palette {
        let fgFaint: NSColor
        let fgDim: NSColor
        let bg2: NSColor
        let bg4: NSColor
        let del: NSColor
        let bubbleGradient: CGGradient?
        let bubbleStroke: NSColor

        init(theme: Theme) {
            fgFaint = theme.nsColor("fg-faint")
            fgDim = theme.nsColor("fg-dim")
            bg2 = theme.nsColor("bg-2")
            bg4 = theme.nsColor("bg-4")
            del = theme.nsColor("del")
            let accent = theme.nsColor("accent")
            let bg1 = theme.nsColor("bg-1")
            // The transcript sits on `bg-1`, so the bubble's translucent
            // accent gradient is flattened onto it.
            let top = Self.opaque(accent.withAlphaComponent(ACPTranscriptCoreTextRowView.bubbleTopAlpha), over: bg1)
            let bottom = Self.opaque(accent.withAlphaComponent(ACPTranscriptCoreTextRowView.bubbleBottomAlpha), over: bg1)
            bubbleGradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]
            )
            bubbleStroke = accent.withAlphaComponent(ACPTranscriptCoreTextRowView.bubbleStrokeAlpha)
        }

        /// `top` composited onto `base` in sRGB, or `top` itself when `base`
        /// is translucent; as `DiffSplitCoreTextRowView.Palette.opaque`.
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
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawContent(dirtyRect)
    }

    private func drawContent(_ requestedRect: NSRect) {
        let dirtyRect = requestedRect.intersection(bounds)
        guard !dirtyRect.isEmpty, bounds.width > 0, let palette,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let layout = layout(forWidth: bounds.width)
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for item in layout.items {
            switch item {
            case .fill(let rect, let color, let radius):
                guard rect.intersects(dirtyRect) else { continue }
                color.setFill()
                if radius > 0 {
                    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                } else {
                    rect.fill()
                }
            case .text(let line, let origin):
                context.textPosition = origin
                CTLineDraw(line, context)
            case .symbol(let image, let rect):
                guard rect.intersects(dirtyRect) else { continue }
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
                context.restoreGState()
            case .markdown(let markdown, let origin, let ascents):
                drawMarkdown(markdown, origin: origin, ascents: ascents, dirtyRect: dirtyRect, context: context)
            case .bubble(let rect):
                guard rect.intersects(dirtyRect) else { continue }
                drawBubble(rect, palette: palette, context: context)
            }
        }
    }

    private func drawMarkdown(
        _ markdown: ACPTranscriptMarkdownLayout, origin: CGPoint, ascents: [CGFloat], dirtyRect: CGRect, context: CGContext
    ) {
        let local = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        for background in markdown.backgrounds where background.rect.intersects(local) {
            background.color.setFill()
            let rect = background.rect.offsetBy(dx: origin.x, dy: origin.y)
            if background.cornerRadius > 0 {
                NSBezierPath(roundedRect: rect, xRadius: background.cornerRadius, yRadius: background.cornerRadius).fill()
            } else {
                rect.fill()
            }
        }
        let lines = markdown.linesIntersecting(local)
        for index in lines.indices {
            let line = markdown.lines[index]
            context.textPosition = CGPoint(x: origin.x + line.origin.x, y: origin.y + line.origin.y + ascents[index])
            CTLineDraw(line.line, context)
        }
    }

    /// `ACPUserBubbleChrome`: a top-to-bottom accent gradient with a tail
    /// corner at the bottom trailing edge and a hairline inner stroke.
    private func drawBubble(_ rect: CGRect, palette: Palette, context: CGContext) {
        let path = Self.bubblePath(in: rect)
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = palette.bubbleGradient {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: []
            )
        }
        context.restoreGState()
        let inset = Self.bubbleStrokeWidth / 2
        context.addPath(Self.bubblePath(in: rect.insetBy(dx: inset, dy: inset)))
        context.setStrokeColor(palette.bubbleStroke.cgColor)
        context.setLineWidth(Self.bubbleStrokeWidth)
        context.strokePath()
    }

    /// A rounded rect whose bottom-trailing corner is the small tail corner,
    /// in flipped coordinates.
    private static func bubblePath(in rect: CGRect) -> CGPath {
        let large = min(bubbleCornerRadius, rect.width / 2, rect.height / 2)
        let tail = min(bubbleTailCornerRadius, large)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + large, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: large)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: tail)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: large)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: large)
        path.closeSubpath()
        return path
    }

    // MARK: - Tiles (ported from `DiffSplitCoreTextRowView`)

    /// The scroller sets frames directly after measuring, without a layout
    /// pass, so a resize redraws here.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        layoutTiles()
        invalidateTiles()
    }

    /// Rows draw into tile layers of this height. Each tile draws once when
    /// it nears the viewport and again only when content under it changes.
    /// With one backing store per row, AppKit redraws a strip of every tall
    /// row on each scroll step.
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
        }
    }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    private func requestMissingTiles() {
        guard bounds.height > 0 else { return }
        if wantedTiles().contains(where: { tiles[$0] == nil }) {
            needsDisplay = true
        }
    }

    /// The visible part plus a quarter viewport each way, so a tall row
    /// entering the screen draws a tile or two per frame.
    private func wantedTiles() -> Range<Int> {
        let margin = (enclosingScrollView?.contentView.bounds.height ?? visibleRect.height) / 4
        return Self.tileRange(covering: visibleRect.insetBy(dx: 0, dy: -margin), height: bounds.height, tileHeight: Self.tileHeight)
    }

    /// AppKit calls this for its own scroll invalidations as well as ours,
    /// so it only adds missing tiles; existing ones redraw only through
    /// `invalidateTiles`.
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
    private static func tileRange(covering rect: NSRect, height: CGFloat, tileHeight: CGFloat) -> Range<Int> {
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

    /// A tile's rect plus a point of overlap with each neighbor, so tile
    /// edges that fall mid-pixel do not blend into a visible seam.
    private func tileFrame(_ index: Int) -> NSRect {
        tileRect(index).insetBy(dx: 0, dy: -1).intersection(bounds)
    }

    /// Redraws every tile and lets `updateLayer` add any that are now needed.
    private func invalidateTiles() {
        for tile in tiles.values {
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
}

/// Draws a row's tiles; layers hold their delegate weakly.
@MainActor
private final class TileDelegate: NSObject, @preconcurrency CALayerDelegate {
    weak var view: ACPTranscriptCoreTextRowView?

    init(view: ACPTranscriptCoreTextRowView) {
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
