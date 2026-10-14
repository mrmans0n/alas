import AppKit
import CoreText

extension ACPTranscriptCoreTextRowView {
    // MARK: - Layout

    /// Something to draw, positioned in view coordinates.
    enum Item {
        case fill(CGRect, NSColor, cornerRadius: CGFloat)
        /// A one-line label; `origin` is its baseline start.
        case text(CTLine, origin: CGPoint)
        case symbol(CGImage, CGRect)
        /// Markdown lines and backgrounds, offset by `origin`; `ascents` parallels its lines.
        case markdown(ACPTranscriptMarkdownLayout, origin: CGPoint, ascents: [CGFloat])
        case bubble(CGRect)
    }

    struct Layout {
        let width: CGFloat
        let height: CGFloat
        let column: CGRect
        let items: [Item]
        /// The header line a click expands or collapses, for rows that have one.
        var toggleRect: CGRect?
    }

    func layout(forWidth width: CGFloat) -> Layout {
        if let cachedLayout, cachedLayout.width == width { return cachedLayout }
        let layout = makeLayout(width: width)
        cachedLayout = layout
        refreshTextElement(from: layout)
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
            var markdown = ACPTranscriptMarkdownLayout.make(source: source, width: textWidth, theme: theme, typography: typography)
            let used = markdown.map(V.usedWidth(of:)) ?? 0
            // Refit a short prompt to the bubble, so hit testing, selection and
            // the accessibility frame end where the bubble does. Every line fits
            // `used`, so the breaks and height are the same.
            if let wide = markdown, ceil(used) < textWidth,
               let fitted = ACPTranscriptMarkdownLayout.make(source: source, width: ceil(used), theme: theme, typography: typography),
               fitted.height == wide.height {
                markdown = fitted
            }
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

    enum SymbolRole: Hashable {
        case leading, status, chevron
    }

    struct Symbol {
        let image: CGImage
        let size: CGSize
    }

    static func renderSymbols(for content: Content, palette: Palette) -> [SymbolRole: Symbol] {
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
    struct Palette {
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

    func drawContent(_ requestedRect: NSRect) {
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
            let radius = background.cornerRadius
            let shape = radius > 0 ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) : NSBezierPath(rect: rect)
            shape.fill()
            if let header = background.header {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                header.fill.setFill()
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: header.height).fill()
                header.divider.setFill()
                CGRect(x: rect.minX, y: rect.minY + header.height - 0.5, width: rect.width, height: 0.5).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if let stroke = background.stroke {
                stroke.setStroke()
                let inset = rect.insetBy(dx: 0.25, dy: 0.25)
                let outline = NSBezierPath(roundedRect: inset, xRadius: max(0, radius - 0.25), yRadius: max(0, radius - 0.25))
                outline.lineWidth = 0.5
                outline.stroke()
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
            let extent = Self.selectionExtent(
                of: line.line, from: lower, to: upper, hasText: line.visibleLength > 0, runsTo: runsOn ? edge - line.origin.x : nil
            )
            context.fill(CGRect(
                x: origin.x + line.origin.x + extent.lowerBound, y: origin.y + line.origin.y,
                width: extent.upperBound - extent.lowerBound, height: line.height
            ))
        }
    }

    /// The x range to highlight for `lower..<upper` of `line`, or from `lower` to
    /// `edge` when the selection runs on past the line. A right-to-left run's
    /// caret offsets fall right to left, so the two are ordered here.
    static func selectionExtent(
        of line: CTLine, from lower: Int, to upper: Int, hasText: Bool, runsTo edge: CGFloat?
    ) -> ClosedRange<CGFloat> {
        let start = hasText ? CTLineGetOffsetForStringIndex(line, lower, nil) : 0
        if let edge { return min(start, edge)...max(start, edge) }
        let end = CTLineGetOffsetForStringIndex(line, upper, nil)
        return min(start, end)...max(start, end)
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
            let icon = copied ? style.copiedIcon : style.copyIcon
            let iconRect = CGRect(
                x: rect.minX + L.copyButtonHorizontalPadding, y: rect.midY - icon.size.height / 2,
                width: icon.size.width, height: icon.size.height
            )
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            context.textPosition = CGPoint(
                x: iconRect.maxX + L.copyButtonIconSpacing, y: rect.minY + L.copyButtonVerticalPadding + style.ascent
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
}
