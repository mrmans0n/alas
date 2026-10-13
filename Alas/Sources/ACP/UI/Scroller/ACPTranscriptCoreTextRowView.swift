import AppKit
import Combine
import CoreText

/// A common transcript row drawn with CoreText in one view instead of a
/// SwiftUI host: agent prose, commentary, a collapsed thought, a collapsed
/// tool call, a tool-call group header, and the user bubble. Hover reveals
/// the message actions button and a tool row's timestamp; clicking a tool
/// row, thought, or group header expands it. Agent and user text can be
/// selected and copied, and code blocks have a "Copy" button. Text rows expose
/// one text-area element; the one-line rows are buttons that expand.
@MainActor
final class ACPTranscriptCoreTextRowView: NSView, ACPTranscriptRowView {
    enum Content: Equatable, Sendable {
        /// Agent markdown; `commentary` adds the narration lane and "Working…" header.
        case agent(markdown: String, commentary: Bool)
        /// A collapsed thought.
        case thought(label: String)
        /// A collapsed tool call.
        /// `timestamp` is shown before the duration while the pointer is over the row.
        case toolCall(presentation: ACPToolCallPresentation, target: String?, duration: String?, timestamp: String? = nil, failed: Bool)
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
    /// Interaction closures from the latest configure, kept even when the
    /// content token is unchanged and the layout is reused.
    private(set) var actions: ACPTranscriptNativeRows.Actions = .inert
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
        if window == nil {
            dropTiles()
            resetHover()
            armedHitTarget = nil
            pressOrigin = nil
            isSelectingText = false
            pointerCursor = .arrow
        } else {
            updateTileScale()
            needsDisplay = true
        }
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
        content: Content, contentMaxWidth: CGFloat, inToolCallGroup: Bool, theme: Theme, typography: ACPChatTypography,
        actions: ACPTranscriptNativeRows.Actions = .inert
    ) {
        self.actions = actions
        defer { syncActionsButton() }
        let sizeChanged = content != self.content || contentMaxWidth != self.contentMaxWidth
            || inToolCallGroup != self.inToolCallGroup || typography != self.typography
        guard sizeChanged || theme != self.theme else { return }
        if content != self.content {
            // Offsets into the old text mean nothing in the new.
            textSelection = nil
            codeCopyFeedbackTask?.cancel()
            copiedCodeBlock = nil
            textElement = nil
        }
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
        actionsButton?.apply(theme: theme)
        if sizeChanged { onIntrinsicSizeInvalidated?() }
    }

    func markNeedsRemeasure() {
        needsRemeasure = true
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        needsRemeasure = false
        lastMeasuredWidth = width
        positionActions()
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
        /// The header line a click expands or collapses, for rows that have one.
        var toggleRect: CGRect?
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
        case .toolCall(let presentation, let target, let duration, let timestamp, _):
            builder.addToolCall(
                target: target, duration: duration, timestamp: isHovering ? timestamp : nil, label: presentation.label
            )
        case .toolGroupHeader(let label, _, _):
            builder.addGroupHeader(label: label)
        case .user(let markdown):
            builder.addUserBubble(markdown, contentMaxWidth: contentMaxWidth, theme: theme, typography: typography)
        }
        var layout = builder.finish(width: width, column: column)
        switch content {
        case .thought, .toolCall, .toolGroupHeader:
            // These rows are their header line, so the whole column width
            // and height is the click target.
            layout.toggleRect = CGRect(x: column.minX, y: 0, width: column.width, height: layout.height)
        case .agent, .user:
            break
        }
        return layout
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
        mutating func addToolCall(target: String?, duration: String?, timestamp: String?, label: String) {
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
            if let timestamp {
                let line = V.line(timestamp, font: durationFont, color: palette.fgFaint)
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
        case .toolCall(let presentation, _, _, _, let failed):
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
        drawTextSelection(markdown, origin: origin, lines: lines, context: context)
        for index in lines.indices {
            let line = markdown.lines[index]
            context.textPosition = CGPoint(x: origin.x + line.origin.x, y: origin.y + line.origin.y + ascents[index])
            let linePosition = context.textPosition
            CTLineDraw(line.line, context)
            for underline in line.underlines {
                underline.color.setFill()
                CGRect(
                    x: linePosition.x + underline.minX, y: linePosition.y + underline.offset,
                    width: underline.width, height: underline.thickness
                ).fill()
            }
        }
        drawCopyButtons(markdown, origin: origin, dirtyRect: dirtyRect, context: context)
    }

    /// The selected text's background, in the system selection color, dimmed
    /// when this row is not the focused view, as `NSTextView` draws it.
    private func drawTextSelection(
        _ markdown: ACPTranscriptMarkdownLayout, origin: CGPoint, lines: ArraySlice<ACPTranscriptMarkdownLayout.Line>,
        context: CGContext
    ) {
        guard let selection = textSelection, !selection.isEmpty else { return }
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        var color = CGColor.clear
        // System colors are dynamic; resolve against the row's appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).cgColor
        }
        context.setFillColor(color)
        // A selection running past a line's end fills to the text's edge;
        // the bubble's edge is its widest line, not the width it wraps to.
        var edge = markdown.width
        if case .user = content { edge = Self.usedWidth(of: markdown) }
        for line in lines {
            guard let block = line.block,
                  let span = selection.span(inBlock: block, length: (markdown.texts[block] as NSString).length)
            else { continue }
            let visibleEnd = line.range.location + line.visibleLength
            let breakPosition = TextSelection.Position(block: block, index: visibleEnd)
            let runsOn = selection.start <= breakPosition && selection.end > breakPosition
            let lower = max(span.lowerBound, line.range.location)
            let upper = min(span.upperBound, visibleEnd)
            guard span.lowerBound <= visibleEnd, span.upperBound >= line.range.location, lower < upper || runsOn else { continue }
            let minX = line.visibleLength > 0 ? CTLineGetOffsetForStringIndex(line.line, lower, nil) : 0
            let maxX = runsOn ? edge - line.origin.x : CTLineGetOffsetForStringIndex(line.line, upper, nil)
            context.fill(CGRect(
                x: origin.x + line.origin.x + minX, y: origin.y + line.origin.y, width: max(0, maxX - minX), height: line.height
            ))
        }
    }

    /// Each code block's "Copy" button, or "Copied" just after a click.
    private func drawCopyButtons(_ markdown: ACPTranscriptMarkdownLayout, origin: CGPoint, dirtyRect: CGRect, context: CGContext) {
        typealias L = ACPTranscriptMarkdownLayout
        let style = markdown.copyButtonStyle
        for index in markdown.codeBlocks.indices {
            let copied = copiedCodeBlock == index
            let rect = markdown.copyButtonRect(index, copied: copied).offsetBy(dx: origin.x, dy: origin.y)
            guard rect.intersects(dirtyRect) else { continue }
            (copied ? style.copiedFill : style.fill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: L.copyButtonCornerRadius, yRadius: L.copyButtonCornerRadius).fill()
            let inset = L.copyButtonStrokeWidth / 2
            let border = NSBezierPath(
                roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: L.copyButtonCornerRadius, yRadius: L.copyButtonCornerRadius
            )
            border.lineWidth = L.copyButtonStrokeWidth
            (copied ? style.copiedStroke : style.stroke).setStroke()
            border.stroke()
            context.textPosition = CGPoint(
                x: rect.minX + L.copyButtonHorizontalPadding, y: rect.minY + L.copyButtonVerticalPadding + style.ascent
            )
            CTLineDraw(copied ? style.copied : style.copy, context)
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

    // MARK: - Clicks

    /// What a press on the row lands on. Armed on mouse-down and fired on
    /// mouse-up only if the pointer is still over the same target, like the
    /// diff's expansion pills.
    private enum HitTarget: Equatable {
        case expansionToggle
        case link(URL)
        /// The "Copy" button of the code block at this index.
        case codeCopy(Int)
    }

    private var armedHitTarget: HitTarget?
    /// Where the armed press began, to tell a click from a drag.
    private var pressOrigin: NSPoint?
    /// Farther than this from the press, a drag is not a click.
    private static let clickSlop: CGFloat = 3

    private enum PointerCursor {
        case arrow, pointingHand, iBeam
    }

    /// The cursor this row last set; cursors are set on moves rather than
    /// through cursor rects, as the diff rows do.
    private var pointerCursor = PointerCursor.arrow

    /// The row's markdown and its origin, for the rows that have text.
    private var markdown: (layout: ACPTranscriptMarkdownLayout, origin: CGPoint)? {
        let width = bounds.width > 0 ? bounds.width : lastMeasuredWidth ?? 0
        guard width > 0 else { return nil }
        for case .markdown(let markdown, let origin, _) in layout(forWidth: width).items {
            return (markdown, origin)
        }
        return nil
    }

    private func codeCopyIndex(at point: NSPoint) -> Int? {
        guard let (markdown, origin) = markdown else { return nil }
        return markdown.codeBlocks.indices.first { index in
            markdown.copyButtonRect(index, copied: copiedCodeBlock == index).offsetBy(dx: origin.x, dy: origin.y).contains(point)
        }
    }

    private func link(at point: NSPoint) -> URL? {
        guard bounds.width > 0 else { return nil }
        for case .markdown(let markdown, let origin, _) in layout(forWidth: bounds.width).items {
            if let url = markdown.link(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) { return url }
        }
        return nil
    }

    private func hitTarget(at point: NSPoint) -> HitTarget? {
        guard bounds.width > 0 else { return nil }
        if let index = codeCopyIndex(at: point) { return .codeCopy(index) }
        if let url = link(at: point) { return .link(url) }
        guard actions.toggleExpanded != nil,
              layout(forWidth: bounds.width).toggleRect?.contains(point) == true
        else { return nil }
        return .expansionToggle
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let target = hitTarget(at: point) {
            armedHitTarget = target
            pressOrigin = point
            return
        }
        if let position = textPosition(at: point, inside: true) {
            window?.makeFirstResponder(self)
            beginTextSelection(
                at: position, point: point, clickCount: event.clickCount, extending: event.modifierFlags.contains(.shift)
            )
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .link = armedHitTarget, let pressOrigin {
            guard hypot(point.x - pressOrigin.x, point.y - pressOrigin.y) > Self.clickSlop else { return }
            // A drag from a link is not a click: it selects text from where it began.
            armedHitTarget = nil
            self.pressOrigin = nil
            guard let start = textPosition(at: pressOrigin) else { return }
            window?.makeFirstResponder(self)
            beginTextSelection(at: start, point: pressOrigin, clickCount: 1, extending: false)
        }
        guard isSelectingText else { return super.mouseDragged(with: event) }
        if let position = textPosition(at: point) {
            textSelection?.focus = position
        }
        autoscroll(with: event)
    }

    private func updateCursor(at point: NSPoint?) {
        var wanted = PointerCursor.arrow
        if let point {
            if link(at: point) != nil || codeCopyIndex(at: point) != nil {
                wanted = .pointingHand
            } else if textPosition(at: point, inside: true) != nil {
                wanted = .iBeam
            }
        }
        guard wanted != pointerCursor else { return }
        pointerCursor = wanted
        switch wanted {
        case .arrow: NSCursor.arrow.set()
        case .pointingHand: NSCursor.pointingHand.set()
        case .iBeam: NSCursor.iBeam.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isSelectingText {
            isSelectingText = false
            return
        }
        guard let armed = armedHitTarget else { return super.mouseUp(with: event) }
        armedHitTarget = nil
        pressOrigin = nil
        guard hitTarget(at: convert(event.locationInWindow, from: nil)) == armed else { return }
        perform(armed)
    }

    private func perform(_ target: HitTarget) {
        switch target {
        case .link(let url):
            actions.openURL(url)
        case .codeCopy(let index):
            copyCode(index, to: .general)
        case .expansionToggle:
            // A native tool call or thought is always collapsed; a group
            // header draws either state.
            if case .toolGroupHeader(_, _, let expanded) = content {
                actions.toggleExpanded?(!expanded)
            } else {
                actions.toggleExpanded?(true)
            }
        }
    }

    // MARK: - Text selection (ported from `DiffSplitCoreTextRowView`)

    /// Selected text, as UTF-16 offsets into the markdown's block texts.
    struct TextSelection: Equatable {
        struct Position: Comparable {
            var block: Int
            var index: Int

            static func < (lhs: Position, rhs: Position) -> Bool {
                (lhs.block, lhs.index) < (rhs.block, rhs.index)
            }
        }

        var anchor: Position
        var focus: Position

        var start: Position { min(anchor, focus) }
        var end: Position { max(anchor, focus) }
        var isEmpty: Bool { anchor == focus }

        /// The selected offsets within `block`, whose text is `length` long.
        func span(inBlock block: Int, length: Int) -> Range<Int>? {
            guard block >= start.block, block <= end.block else { return nil }
            let lower = block == start.block ? min(start.index, length) : 0
            let upper = block == end.block ? min(end.index, length) : length
            return lower..<max(lower, upper)
        }

        /// The selected text, blocks joined by newlines.
        func text(in texts: [String]) -> String {
            guard !isEmpty else { return "" }
            return (start.block...end.block).compactMap { block -> String? in
                guard texts.indices.contains(block) else { return nil }
                let text = texts[block] as NSString
                guard let span = span(inBlock: block, length: text.length) else { return nil }
                return text.substring(with: NSRange(location: span.lowerBound, length: span.count))
            }.joined(separator: "\n")
        }
    }

    private var isSelectingText = false
    private var textSelection: TextSelection? {
        didSet {
            guard textSelection != oldValue else { return }
            // Only the lines either selection covers, so a drag does not
            // redraw every tile of a long message on each event.
            let rects = [oldValue, textSelection].compactMap { $0.flatMap(rect(covering:)) }
            guard let first = rects.first else { return }
            invalidateTiles(rects.dropFirst().reduce(first) { $0.union($1) })
        }
    }

    /// The lines `selection` touches, full width, in view coordinates.
    private func rect(covering selection: TextSelection) -> CGRect? {
        guard !selection.isEmpty, let (markdown, origin) = markdown else { return nil }
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for line in markdown.lines {
            guard let block = line.block,
                  TextSelection.Position(block: block, index: line.range.location) <= selection.end,
                  TextSelection.Position(block: block, index: NSMaxRange(line.range)) >= selection.start
            else { continue }
            minY = min(minY, line.origin.y)
            maxY = max(maxY, line.origin.y + line.height)
        }
        guard minY < maxY else { return nil }
        return CGRect(x: 0, y: origin.y + minY, width: bounds.width, height: maxY - minY)
    }

    /// Agent and user text is selectable; one-line rows are click targets.
    override var acceptsFirstResponder: Bool {
        switch content {
        case .agent, .user: true
        default: false
        }
    }

    override func becomeFirstResponder() -> Bool {
        // The selection's color depends on focus.
        if let rect = textSelection.flatMap(rect(covering:)) { invalidateTiles(rect) }
        return super.becomeFirstResponder()
    }

    /// The selection stays, drawn inactive, as a text view keeps it.
    override func resignFirstResponder() -> Bool {
        if let rect = textSelection.flatMap(rect(covering:)) { invalidateTiles(rect) }
        return super.resignFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let rect = textSelection.flatMap(rect(covering:)) { invalidateTiles(rect) }
    }

    /// The selectable line whose box is under or after `y`, in markdown coordinates.
    private static func selectableLine(atOrAfter y: CGFloat, in markdown: ACPTranscriptMarkdownLayout) -> ACPTranscriptMarkdownLayout.Line? {
        markdown.lines.first { $0.block != nil && y < $0.origin.y + $0.height }
    }

    /// The block and offset nearest `point`. Points above or below the text
    /// clamp to its start or end, as a drag past the edge does; with
    /// `inside`, only points over the markdown resolve.
    private func textPosition(at point: NSPoint, inside: Bool = false) -> TextSelection.Position? {
        guard let (markdown, origin) = markdown else { return nil }
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if inside, !CGRect(x: 0, y: 0, width: markdown.width, height: markdown.height).contains(local) { return nil }
        guard let line = Self.selectableLine(atOrAfter: local.y, in: markdown), let block = line.block else {
            guard let last = markdown.texts.indices.last else { return nil }
            return .init(block: last, index: (markdown.texts[last] as NSString).length)
        }
        // Between blocks, the next block's start.
        guard local.y >= line.origin.y, line.visibleLength > 0 else { return .init(block: block, index: line.range.location) }
        let index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: local.x - line.origin.x, y: 0))
        guard index != kCFNotFound else { return .init(block: block, index: line.range.location) }
        return .init(block: block, index: min(max(index, line.range.location), line.range.location + line.visibleLength))
    }

    /// The offset of the character under `point`, not the nearest caret
    /// position, as `NSTextView` picks a double-clicked word.
    private func characterIndex(at point: NSPoint, near position: TextSelection.Position) -> Int {
        guard let (markdown, origin) = markdown else { return position.index }
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let line = Self.selectableLine(atOrAfter: local.y, in: markdown), line.block == position.block,
              line.visibleLength > 0, position.index > line.range.location,
              local.x - line.origin.x < CTLineGetOffsetForStringIndex(line.line, position.index, nil)
        else { return position.index }
        return (markdown.texts[position.block] as NSString).rangeOfComposedCharacterSequence(at: position.index - 1).location
    }

    private func beginTextSelection(at position: TextSelection.Position, point: NSPoint, clickCount: Int, extending: Bool) {
        isSelectingText = true
        if extending, var selection = textSelection {
            selection.focus = position
            textSelection = selection
            return
        }
        guard let texts = markdown?.layout.texts, texts.indices.contains(position.block) else { return }
        let text = texts[position.block] as NSString
        func select(_ range: NSRange) {
            textSelection = .init(
                anchor: .init(block: position.block, index: range.location), focus: .init(block: position.block, index: NSMaxRange(range))
            )
        }
        switch clickCount {
        case 2 where text.length > 0:
            let under = min(characterIndex(at: point, near: position), text.length - 1)
            select(NSAttributedString(string: text as String).doubleClick(at: under))
        case 3...:
            // The paragraph, as a text view's triple-click: a code line or a whole prose block.
            var paragraph = text.paragraphRange(for: NSRange(location: min(position.index, text.length), length: 0))
            while paragraph.length > 0, text.character(at: NSMaxRange(paragraph) - 1) == 0x0A {
                paragraph.length -= 1
            }
            select(paragraph)
        default:
            textSelection = .init(anchor: position, focus: position)
        }
    }

    func selectedText() -> String {
        guard let textSelection, let texts = markdown?.layout.texts else { return "" }
        return textSelection.text(in: texts)
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

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    /// The key commands this row handles; arrows and paging go on to the
    /// transcript's scroll view.
    private static let keyCommands: Set<Selector> = [#selector(cancelOperation(_:)), #selector(selectAll(_:))]

    override func doCommand(by selector: Selector) {
        if Self.keyCommands.contains(selector) {
            perform(selector, with: nil)
        } else {
            nextResponder?.doCommand(by: selector)
        }
    }

    override func insertText(_ insertString: Any) {
        nextResponder?.insertText(insertString)
    }

    /// Escape clears the selection first.
    override func cancelOperation(_ sender: Any?) {
        if textSelection != nil {
            textSelection = nil
        } else {
            nextResponder?.cancelOperation(sender)
        }
    }

    /// All of this row's text, not the transcript's.
    override func selectAll(_ sender: Any?) {
        guard let texts = markdown?.layout.texts, let last = texts.indices.last else { return }
        textSelection = .init(anchor: .init(block: 0, index: 0), focus: .init(block: last, index: (texts[last] as NSString).length))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard textSelection.map({ !$0.isEmpty }) ?? false else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        return menu
    }

    func selectAllForTesting() {
        selectAll(nil)
    }

    // MARK: - Accessibility

    /// The text rows' text area, kept while their text is, so VoiceOver
    /// keeps its place.
    private var textElement: ACPTranscriptTextAccessibilityElement?

    /// Agent and user rows hold text; the others are one-line buttons.
    private var hasTextArea: Bool {
        switch content {
        case .agent, .user: true
        default: false
        }
    }

    var contentForTesting: Content? { content }

    override func isAccessibilityElement() -> Bool {
        content != nil && !hasTextArea
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        guard content != nil else { return super.accessibilityRole() }
        return hasTextArea ? .group : .button
    }

    override func accessibilityLabel() -> String? {
        switch content {
        case .thought(let label), .toolGroupHeader(let label, _, _):
            return label
        case .toolCall(let presentation, let target, let duration, _, let failed):
            let name = [presentation.label, target].compactMap { $0 }.joined(separator: " ")
            return [name, duration, failed ? "failed" : nil].compactMap { $0 }.joined(separator: ", ")
        case .agent, .user, nil:
            return super.accessibilityLabel()
        }
    }

    override func accessibilityValue() -> Any? {
        switch content {
        case .toolGroupHeader(_, _, let expanded): expanded ? "Expanded" : "Collapsed"
        // A native tool call or thought is always collapsed.
        case .thought, .toolCall: "Collapsed"
        case .agent, .user, nil: super.accessibilityValue()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard !hasTextArea, let toggle = actions.toggleExpanded else { return false }
        if case .toolGroupHeader(_, _, let expanded) = content {
            toggle(!expanded)
        } else {
            toggle(true)
        }
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        // The system's list may omit subviews, so add the actions button
        // explicitly unless it is already there.
        var children = super.accessibilityChildren() ?? []
        let (button, elements) = MainActor.assumeIsolated { (actionsButton as NSButton?, textAccessibilityElements()) }
        if let button, !children.contains(where: { $0 as AnyObject === button }) { children.append(button) }
        return children + elements
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // AppKit asks on the main thread.
        let hit: (button: NSButton?, element: ACPTranscriptTextAccessibilityElement?) = MainActor.assumeIsolated {
            guard let window else { return (nil, nil) }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            // A visible actions button answers for itself.
            if let actionsButton, actionsButton.alphaValue > 0, actionsButton.frame.contains(local) { return (actionsButton, nil) }
            return (nil, textAccessibilityElements().first { $0.accessibilityFrameInParentSpace().contains(local) })
        }
        if let button = hit.button { return button }
        let element = hit.element
        return element ?? super.accessibilityHitTest(point)
    }

    private func textAccessibilityElements() -> [ACPTranscriptTextAccessibilityElement] {
        guard hasTextArea, let (markdown, origin) = markdown, !markdown.texts.isEmpty else { return [] }
        let lines = markdown.lines.compactMap { line in
            line.block.map { TextSelection.Position(block: $0, index: line.range.location) }
        }
        let element: ACPTranscriptTextAccessibilityElement
        if let textElement, textElement.texts == markdown.texts {
            element = textElement
            element.updateLines(lines)
        } else {
            element = ACPTranscriptTextAccessibilityElement(texts: markdown.texts, lines: lines)
            element.setAccessibilityRole(.textArea)
            element.setAccessibilityParent(self)
            element.frameForRange = { [weak self] start, end in
                guard let self, let window else { return nil }
                return textRect(from: start, to: end).map { window.convertToScreen(convert($0, to: nil)) }
            }
            element.selection = { [weak self] in
                guard let selection = self?.textSelection else { return nil }
                return (selection.start, selection.end)
            }
            element.select = { [weak self] start, end in
                self?.textSelection = .init(anchor: start, focus: end)
            }
            element.visibleLines = { [weak self] in self?.visibleTextPositions() }
            textElement = element
        }
        element.setAccessibilityFrameInParentSpace(CGRect(origin: origin, size: CGSize(width: markdown.width, height: markdown.height)))
        return [element]
    }

    /// The rect of the text from `start` to `end`, in view coordinates.
    private func textRect(from start: TextSelection.Position, to end: TextSelection.Position) -> CGRect? {
        guard let (markdown, origin) = markdown else { return nil }
        var result: CGRect?
        for line in markdown.lines {
            guard let block = line.block else { continue }
            let first = line.range.location, last = first + line.visibleLength
            let from = block == start.block ? max(start.index, first) : first
            let to = block == end.block ? min(end.index, last) : last
            guard block >= start.block, block <= end.block, from <= to else { continue }
            let x1 = CTLineGetOffsetForStringIndex(line.line, from, nil), x2 = CTLineGetOffsetForStringIndex(line.line, to, nil)
            let rect = CGRect(
                x: origin.x + line.origin.x + min(x1, x2), y: origin.y + line.origin.y, width: max(1, abs(x2 - x1)), height: line.height
            )
            result = result.map { $0.union(rect) } ?? rect
        }
        return result
    }

    /// The first and last text positions the enclosing scroll view shows.
    private func visibleTextPositions() -> (start: TextSelection.Position, end: TextSelection.Position)? {
        guard let (markdown, origin) = markdown else { return nil }
        let visible = visibleRect
        let shown = markdown.lines.filter { line in
            line.block != nil && line.origin.y + origin.y + line.height > visible.minY && line.origin.y + origin.y < visible.maxY
        }
        guard let first = shown.first, let last = shown.last, let firstBlock = first.block, let lastBlock = last.block else { return nil }
        return (
            .init(block: firstBlock, index: first.range.location),
            .init(block: lastBlock, index: last.range.location + last.visibleLength)
        )
    }

    // MARK: - Code block copy

    /// The code block showing "Copied".
    private var copiedCodeBlock: Int? {
        didSet {
            guard copiedCodeBlock != oldValue, let (markdown, origin) = markdown else { return }
            for index in [oldValue, copiedCodeBlock].compactMap({ $0 }) where markdown.codeBlocks.indices.contains(index) {
                let rect = markdown.copyButtonRect(index, copied: true).union(markdown.copyButtonRect(index, copied: false))
                invalidateTiles(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
    }

    /// How long "Copied" shows, as `CodeBlockView`; tests replace it.
    var codeCopyFeedbackWait: @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(1.5)) }
    private var codeCopyFeedbackTask: Task<Void, Never>?

    private func copyCode(_ index: Int, to pasteboard: NSPasteboard) {
        guard let markdown = markdown?.layout, markdown.codeBlocks.indices.contains(index) else { return }
        pasteboard.clearContents()
        pasteboard.setString(markdown.codeBlocks[index].code, forType: .string)
        copiedCodeBlock = index
        codeCopyFeedbackTask?.cancel()
        let wait = codeCopyFeedbackWait
        codeCopyFeedbackTask = Task { @MainActor [weak self] in
            await wait()
            guard !Task.isCancelled else { return }
            self?.copiedCodeBlock = nil
        }
    }

    func clickCodeCopyForTesting(block: Int, pasteboard: NSPasteboard) -> Bool {
        guard let markdown = markdown?.layout, markdown.codeBlocks.indices.contains(block) else { return false }
        copyCode(block, to: pasteboard)
        return true
    }

    var copiedCodeBlockForTesting: Int? { copiedCodeBlock }
    var codeCopyFeedbackTaskForTesting: Task<Void, Never>? { codeCopyFeedbackTask }

    // MARK: - Hover and actions

    private lazy var hover = ACPDelayedHoverVisibility()
    private var hoverObservation: AnyCancellable?
    private var isHovering = false
    private var isHoverVisible = false
    private var isPointerCovered = false
    private var isMenuOpen = false {
        didSet { if isMenuOpen != oldValue { refreshActionsVisibility() } }
    }
    private var actionsButton: ActionsButton?
    private var actionsTimestamp: NSTextField?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Added once: an `.inVisibleRect` area follows the view, and replacing
        // it under the pointer fires a spurious exit/enter pair.
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerMoved(toWindowLocation: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointerMoved(toWindowLocation: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerCovered = false
        updateCursor(at: nil)
        setHovering(false)
    }

    /// Tracking areas still fire under overlays (launcher, palettes); a
    /// covered move behaves like leaving the row, once.
    private func pointerMoved(toWindowLocation location: NSPoint) {
        guard isTopmostHitTarget(atWindowLocation: location) else {
            if !isPointerCovered {
                isPointerCovered = true
                updateCursor(at: nil)
                setHovering(false)
            }
            return
        }
        isPointerCovered = false
        updateCursor(at: convert(location, from: nil))
        setHovering(true)
    }

    private func setHovering(_ inside: Bool) {
        guard inside != isHovering else { return }
        isHovering = inside
        if inside {
            if actions.menu != nil { ensureActionsButton() }
            hover.enter()
        } else {
            hover.leave()
        }
        // A tool row shows its timestamp while hovered; it is one line, so
        // only its first tile changes.
        if case .toolCall(_, _, _, let timestamp?, _) = content, !timestamp.isEmpty {
            cachedLayout = nil
            tiles[0]?.setNeedsDisplay()
        }
    }

    /// Detaching a retained row clears hover without the pointer-exit delay.
    private func resetHover() {
        isPointerCovered = false
        let wasHovering = isHovering
        isHovering = false
        hover.reset()
        isMenuOpen = false
        if wasHovering { cachedLayout = nil }
    }

    /// Creates, updates, or removes the button for the latest `actions`.
    private func syncActionsButton() {
        if actions.menu == nil {
            actionsButton?.removeFromSuperview()
            actionsTimestamp?.removeFromSuperview()
            actionsButton = nil
            actionsTimestamp = nil
        } else if actions.showsActionsPermanently || isHovering {
            ensureActionsButton()
        }
        positionActions()
        refreshActionsVisibility()
    }

    /// Built on first hover, not with the row: every platform view costs a
    /// layout pass when its row mounts mid-scroll. Once built it stays
    /// mounted, toggling alpha, since removing it would dismiss an open menu.
    private func ensureActionsButton() {
        guard actionsButton == nil else { return }
        let button = ActionsButton()
        button.target = self
        button.action = #selector(showActionsMenu(_:))
        if let theme { button.apply(theme: theme) }
        addSubview(button)
        actionsButton = button
        // `@Published` publishes before it stores, so keep the delivered value.
        hoverObservation = hover.$isVisible.sink { [weak self] visible in
            MainActor.assumeIsolated {
                self?.isHoverVisible = visible
                self?.refreshActionsVisibility()
            }
        }
        positionActions()
        refreshActionsVisibility()
    }

    private var showsActions: Bool {
        actions.showsActionsPermanently || isMenuOpen || isHoverVisible
    }

    private func refreshActionsVisibility() {
        guard let actionsButton else { return }
        let alpha: CGFloat = showsActions ? 1 : 0
        actionsButton.alphaValue = alpha
        actionsTimestamp?.alphaValue = alpha
    }

    /// Flush with the right edge of the reserved lane: the button's own
    /// padding makes the net inset `laneWidth - 8`; `y: -2` aligns it with the
    /// top of the content, as `ACPMessageGutter` does.
    private func positionActions() {
        guard let actionsButton, lastMeasuredWidth != nil else { return }
        let column = columnRect
        let x = column.maxX + ACPMessageGutterLayout.laneWidth - 8 - ACPMessageGutterLayout.menuWidth
        let size = NSSize(width: ACPMessageGutterLayout.menuWidth, height: ACPMessageGutterLayout.menuWidth)
        actionsButton.frame = NSRect(origin: NSPoint(x: x, y: -2), size: size)
        let createdAt = actions.menu?.createdAt
        let showsInline = createdAt != nil
            && ACPTranscriptRowContent.showsInlineTimestamp(
                availableRowContentWidth: column.width,
                availableTrailingGutterWidth: (lastMeasuredWidth ?? 0) - column.maxX
            )
        guard showsInline, let createdAt, let theme else {
            actionsTimestamp?.removeFromSuperview()
            actionsTimestamp = nil
            return
        }
        let label = actionsTimestamp ?? makeTimestampLabel()
        label.stringValue = ACPMessageTimestampFormatter.string(for: createdAt)
        label.textColor = theme.nsColor("fg-faint")
        label.layer?.backgroundColor = theme.nsColor("bg-3").withAlphaComponent(0.92).cgColor
        label.sizeToFit()
        let labelSize = NSSize(width: label.frame.width + 12, height: label.frame.height + 8)
        label.frame = NSRect(
            x: x, y: actionsButton.frame.maxY + ACPMessageGutterLayout.timestampVerticalSpacing,
            width: labelSize.width, height: labelSize.height
        )
        label.layer?.cornerRadius = labelSize.height / 2
        label.alphaValue = actionsButton.alphaValue
    }

    private func makeTimestampLabel() -> NSTextField {
        let label = TimestampLabel(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.wantsLayer = true
        label.setAccessibilityElement(false)
        addSubview(label)
        actionsTimestamp = label
        return label
    }

    @objc private func showActionsMenu(_ sender: NSButton) {
        guard let input = actions.menu else { return }
        let menu = ACPMessageActionsMenu.make(input)
        menu.delegate = self
        menu.popUp(
            positioning: menu.items.first { $0.title == "Copy message" },
            at: NSPoint(x: 0, y: sender.bounds.height + 2),
            in: sender
        )
    }

    var actionsButtonForTesting: NSButton? { actionsButton }

    var isMenuOpenForTesting: Bool {
        get { isMenuOpen }
        set { isMenuOpen = newValue }
    }

    func hoverForTesting(_ inside: Bool) {
        setHovering(inside)
    }

    func flushHoverForTesting() {
        hover.flushPendingHide()
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
        positionActions()
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

    /// Redraws the tiles under `rect`, or every tile, and lets
    /// `updateLayer` add any that are now needed.
    private func invalidateTiles(_ rect: NSRect? = nil) {
        for (index, tile) in tiles where rect.map({ tileRect(index).intersects($0) }) ?? true {
            tile.setNeedsDisplay()
        }
        needsDisplay = true
    }

    /// A parked row keeps no bitmaps; `updateLayer` redraws the tiles it
    /// needs once the row is attached again.
    private func dropTiles() {
        for tile in tiles.values {
            tile.removeFromSuperlayer()
        }
        tiles.removeAll()
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

extension ACPTranscriptCoreTextRowView: NSMenuItemValidation {
    /// Copy only with something selected.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? !selectedText().isEmpty : true
    }
}

extension ACPTranscriptCoreTextRowView: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }
}

/// The "…" button, styled as `ACPMessageGutter` styles its SwiftUI wrapper.
private final class ActionsButton: NSButton {
    private static let ellipsisImage = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Message actions")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        image = Self.ellipsisImage
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        toolTip = "Message actions"
        setAccessibilityLabel("Message actions")
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ACPMessageGutterLayout.menuWidth, height: ACPMessageGutterLayout.menuWidth)
    }

    /// A hidden button is not a click target, as `allowsHitTesting(false)` does for the SwiftUI one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue == 0 ? nil : super.hitTest(point)
    }

    @MainActor
    func apply(theme: Theme) {
        contentTintColor = theme.nsColor("fg-muted")
        layer?.backgroundColor = theme.nsColor("bg-3").withAlphaComponent(0.85).cgColor
        layer?.borderColor = theme.nsColor("line").cgColor
    }
}

/// The inline timestamp capsule under the button; never a hit target.
private final class TimestampLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
