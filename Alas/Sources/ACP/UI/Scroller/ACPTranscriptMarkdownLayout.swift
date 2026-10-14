import AppKit
import CoreText

/// Markdown laid out as positioned CoreText lines and block backgrounds, with
/// the spacing `ACPMarkdownText` gives its SwiftUI blocks. Pure geometry: a row
/// view draws `lines` and `backgrounds` and owns no layout of its own.
@MainActor
struct ACPTranscriptMarkdownLayout {
    struct Line {
        let line: CTLine
        /// Top-left of the line's box, in a flipped space.
        var origin: CGPoint
        var height: CGFloat
        /// Underlined runs, which `CTLineDraw` leaves undrawn.
        var underlines: [Underline] = []
        /// The index into `texts` of the block this line shows, or nil for
        /// drawn-only text such as a code block's language label.
        var block: Int?
        /// The line's range in its block's text, including the whitespace
        /// it hangs past its end.
        var range = NSRange(location: 0, length: 0)
        /// How much of `range` the line draws, without that whitespace.
        var visibleLength = 0
    }

    /// A code block's "Copy" button in its header.
    struct CodeBlock {
        let code: String
        /// The button's right edge, top, and height; its width follows its label.
        let maxX: CGFloat
        let minY: CGFloat
        let height: CGFloat
    }

    /// The "Copy" and "Copied" labels and colors every code block's button shares.
    struct CopyButtonStyle {
        let copy: CTLine
        let copied: CTLine
        let ascent: CGFloat
        let fill: NSColor
        let copiedFill: NSColor
        let stroke: NSColor
        let copiedStroke: NSColor
    }

    /// A rule under one run, relative to its line's origin and baseline.
    struct Underline {
        let minX: CGFloat
        let width: CGFloat
        /// Distance below the baseline to the rule's top edge.
        let offset: CGFloat
        let thickness: CGFloat
        let color: NSColor
    }

    struct Background {
        let rect: CGRect
        let color: NSColor
        let cornerRadius: CGFloat
    }

    // Copied from `ACPMarkdownText` and its `CodeBlockView`.
    static let blockSpacing: CGFloat = 8
    static let h1TopPadding: CGFloat = 4
    static let headingTopPadding: CGFloat = 2
    static let quoteBarWidth: CGFloat = 2
    static let quoteBarGap: CGFloat = 10
    static let quoteBarAlpha: CGFloat = 0.55
    static let codeCornerRadius: CGFloat = 6
    static let codeBackgroundAlpha: CGFloat = 0.6
    static let codeBodyHorizontalPadding: CGFloat = 10
    static let codeBodyVerticalPadding: CGFloat = 8
    static let codeHeaderHorizontalPadding: CGFloat = 10
    static let codeHeaderVerticalPadding: CGFloat = 6
    /// Height of the empty header `CodeBlockView` keeps when there is no language.
    static let codeEmptyHeaderContentHeight: CGFloat = 1
    static let codeLineSpacing: CGFloat = 2
    static let codeLabelTracking: CGFloat = 0.4
    static let copyButtonHorizontalPadding: CGFloat = 6
    static let copyButtonVerticalPadding: CGFloat = 2
    static let copyButtonCornerRadius: CGFloat = 4
    static let copyButtonStrokeWidth: CGFloat = 0.5

    let width: CGFloat
    let height: CGFloat
    let lines: [Line]
    let backgrounds: [Background]
    /// The selectable text of each block, in order: rendered inline markdown
    /// (no backticks or asterisks) and code bodies.
    let texts: [String]
    /// Each block's rendered text with its attributes, for link boundaries.
    let attributedTexts: [NSAttributedString]
    let codeBlocks: [CodeBlock]
    let copyButtonStyle: CopyButtonStyle

    /// Whether every block can be drawn here. Tables, images, Mermaid diagrams
    /// and task lists need views of their own, and so does prose with an
    /// inline image: the SwiftUI renderer turns it into a text attachment that
    /// `CTLineDraw` cannot show. `![` is a conservative stand-in for the inline
    /// renderer's image matching, which needs a theme.
    static func supports(_ blocks: [ACPMarkdownParser.Block]) -> Bool {
        blocks.allSatisfy { block in
            switch block {
            case .table, .image, .mermaid, .taskList: false
            case .heading(_, let text), .paragraph(let text), .quote(let text): !text.contains("![")
            case .code, .streamingCode: true
            }
        }
    }

    static func make(source: String, width: CGFloat, theme: Theme, typography: ACPChatTypography) -> ACPTranscriptMarkdownLayout? {
        let blocks = ACPMarkdownParser.parse(source)
        guard supports(blocks) else { return nil }
        var builder = Builder(width: max(1, width), theme: theme, typography: typography)
        for (index, block) in blocks.enumerated() {
            if index > 0 { builder.y += blockSpacing }
            builder.add(block)
        }
        return ACPTranscriptMarkdownLayout(
            width: max(1, width), height: builder.y, lines: builder.lines, backgrounds: builder.backgrounds,
            texts: builder.texts, attributedTexts: builder.attributedTexts, codeBlocks: builder.codeBlocks,
            copyButtonStyle: builder.copyButtonStyle
        )
    }

    /// Code block `index`'s "Copy" button, sized for the label it shows.
    func copyButtonRect(_ index: Int, copied: Bool) -> CGRect {
        let block = codeBlocks[index]
        let label = copied ? copyButtonStyle.copied : copyButtonStyle.copy
        let width = ceil(CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil))) + 2 * Self.copyButtonHorizontalPadding
        return CGRect(x: block.maxX - width, y: block.minY, width: width, height: block.height)
    }

    /// The lines whose boxes overlap `rect` vertically, including ones it only cuts.
    func linesIntersecting(_ rect: CGRect) -> ArraySlice<Line> {
        // Lines never overlap, so both edges are monotonic in index.
        let first = partitionPoint { $0.origin.y + $0.height <= rect.minY }
        let last = partitionPoint { $0.origin.y < rect.maxY }
        return first < last ? lines[first..<last] : lines[first..<first]
    }

    /// A link as drawn: its URL, visible text, and the rect of each line it
    /// covers, in layout coordinates. A wrapped link has one rect per line.
    struct LinkSpan {
        let url: URL
        let text: String
        let rects: [CGRect]
        /// The block and source offset where the span ends, so only the
        /// next run of the same link continues it.
        let block: Int
        let end: Int
    }

    /// Every link in drawing order. Computed on demand (accessibility asks),
    /// so laying out a row pays nothing for it.
    func linkSpans() -> [LinkSpan] {
        var spans: [LinkSpan] = []
        for line in lines {
            guard let block = line.block, texts.indices.contains(block) else { continue }
            let blockText = texts[block] as NSString
            for run in CTLineGetGlyphRuns(line.line) as! [CTRun] {
                let value = (CTRunGetAttributes(run) as NSDictionary)[NSAttributedString.Key.link]
                guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { continue }
                let range = CTRunGetStringRange(run)
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                let rect = CGRect(x: line.origin.x + position.x, y: line.origin.y, width: width, height: line.height)
                let text = NSMaxRange(NSRange(location: range.location, length: range.length)) <= blockText.length
                    ? blockText.substring(with: NSRange(location: range.location, length: range.length)) : ""
                let end = range.location + range.length
                // Runs of one link continue across style changes and line wraps:
                // same URL, same block, and nothing but wrapped-away whitespace
                // between them in the source. Two links to one URL stay apart.
                if let last = spans.last, last.url == url, last.block == block, last.end <= range.location,
                   Self.isSameLink(in: attributedTexts[block], endingAt: last.end, startingAt: range.location) {
                    let gap = blockText.substring(with: NSRange(location: last.end, length: range.location - last.end))
                    spans[spans.count - 1] = LinkSpan(
                        url: url, text: last.text + gap + text, rects: last.rects + [rect], block: block, end: end
                    )
                } else {
                    spans.append(LinkSpan(url: url, text: text, rects: [rect], block: block, end: end))
                }
            }
        }
        return spans
    }

    /// Marks which source link each rendered link character came from.
    static let linkOrdinal = NSAttributedString.Key("alas.acp.nativeLinkOrdinal")

    /// Whether the runs ending at `end` and starting at `start` belong to one
    /// source link (a wrap or a style change inside it), not two links.
    private static func isSameLink(in text: NSAttributedString, endingAt end: Int, startingAt start: Int) -> Bool {
        guard end > 0, end <= start, start < text.length else { return false }
        let before = text.attribute(linkOrdinal, at: end - 1, effectiveRange: nil) as? Int
        let after = text.attribute(linkOrdinal, at: start, effectiveRange: nil) as? Int
        return before != nil && before == after
    }

    /// The link under `point`, in layout coordinates; nil outside link glyphs.
    func link(at point: CGPoint) -> URL? {
        let lines = linesIntersecting(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        guard let line = lines.first(where: { $0.origin.y <= point.y && point.y < $0.origin.y + $0.height }) else { return nil }
        let x = point.x - line.origin.x
        guard x >= 0, x < CGFloat(CTLineGetTypographicBounds(line.line, nil, nil, nil)) else { return nil }
        // The run's drawn extent, not a caret index: past a glyph's midpoint
        // the caret index is the next character, outside a link's last run.
        for run in CTLineGetGlyphRuns(line.line) as! [CTRun] where CTRunGetGlyphCount(run) > 0 {
            var position = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
            guard x >= position.x, x < position.x + width else { continue }
            let value = (CTRunGetAttributes(run) as NSDictionary)[NSAttributedString.Key.link]
            return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        }
        return nil
    }

    /// The first index whose line fails `predicate`, which holds for a prefix.
    private func partitionPoint(_ predicate: (Line) -> Bool) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(lines[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Building

    @MainActor
    private struct Builder {
        let width: CGFloat
        let theme: Theme
        let typography: ACPChatTypography
        var y: CGFloat = 0
        var lines: [Line] = []
        var backgrounds: [Background] = []
        var texts: [String] = []
        var attributedTexts: [NSAttributedString] = []
        var codeBlocks: [CodeBlock] = []
        let copyButtonStyle: CopyButtonStyle

        init(width: CGFloat, theme: Theme, typography: ACPChatTypography) {
            self.width = width
            self.theme = theme
            self.typography = typography
            // As `CodeBlockView.copyButton`, without its icon.
            let font = NSFont.systemFont(ofSize: typography.labelSize, weight: .medium)
            func label(_ string: String, _ color: NSColor) -> CTLine {
                CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
            }
            let add = theme.nsColor("add")
            copyButtonStyle = CopyButtonStyle(
                copy: label("Copy", theme.nsColor("fg-muted")),
                copied: label("Copied", add),
                ascent: font.ascender,
                fill: theme.nsColor("bg-3").withAlphaComponent(0.6),
                copiedFill: theme.nsColor("bg-3").withAlphaComponent(0.4),
                stroke: theme.nsColor("line"),
                copiedStroke: add.withAlphaComponent(0.5)
            )
        }

        mutating func add(_ block: ACPMarkdownParser.Block) {
            switch block {
            case .heading(let level, let text):
                y += level == 1 ? ACPTranscriptMarkdownLayout.h1TopPadding : ACPTranscriptMarkdownLayout.headingTopPadding
                addBlockText(inline(text, role: .heading(level: level)), x: 0, width: width)
            case .paragraph(let text):
                addBlockText(inline(text, role: .body), x: 0, width: width)
            case .quote(let text):
                let top = y
                let x = ACPTranscriptMarkdownLayout.quoteBarWidth + ACPTranscriptMarkdownLayout.quoteBarGap
                addBlockText(inline(text, role: .quote), x: x, width: max(1, width - x))
                backgrounds.append(Background(
                    rect: CGRect(x: 0, y: top, width: ACPTranscriptMarkdownLayout.quoteBarWidth, height: y - top),
                    color: theme.nsColor("accent").withAlphaComponent(ACPTranscriptMarkdownLayout.quoteBarAlpha),
                    cornerRadius: 0
                ))
            case .code(let language, let body):
                addCode(language: language, body: body, highlighted: true)
            case .streamingCode(let language, let body):
                addCode(language: language, body: body, highlighted: false)
            case .taskList, .image, .mermaid, .table:
                break
            }
        }

        private func inline(_ text: String, role: ACPMarkdownInlineRole) -> NSAttributedString {
            let rendered = ACPMarkdownInlineRenderer.makeAttributedString(source: text, theme: theme, typography: typography, role: role)
            // As `ACPMarkdownInlineText.plainText` styles links for SwiftUI text.
            rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { link, range, _ in
                guard link != nil else { return }
                rendered.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            Self.markLinkBoundaries(in: rendered, source: text)
            return rendered
        }

        /// Equal `.link` values coalesce, so two links to one URL written back to
        /// back render as one range. Each source link gets its own ordinal so
        /// accessibility can tell them apart; a range whose labels don't add up
        /// stays one link.
        private static func markLinkBoundaries(in rendered: NSMutableAttributedString, source: String) {
            let pattern = #"\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let nsSource = source as NSString
            var sourceLinks = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length)).map {
                (label: nsSource.substring(with: $0.range(at: 1)), url: nsSource.substring(with: $0.range(at: 2)))
            }
            var ordinal = 0
            rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
                guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                // The source links this range was rendered from, in order.
                var lengths: [Int] = []
                var total = 0
                while total < range.length, let next = sourceLinks.first,
                      URL(string: next.url)?.absoluteString == url.absoluteString || next.url == url.absoluteString {
                    sourceLinks.removeFirst()
                    let length = (ACPMarkdownInlineRenderer.plainText(next.label) as NSString).length
                    lengths.append(length)
                    total += length
                }
                if total != range.length || lengths.isEmpty { lengths = [range.length] }
                var location = range.location
                for length in lengths {
                    rendered.addAttribute(linkOrdinal, value: ordinal, range: NSRange(location: location, length: length))
                    ordinal += 1
                    location += length
                }
            }
        }

        private static func underlines(of line: CTLine) -> [Underline] {
            var result: [Underline] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let style = attributes[NSAttributedString.Key.underlineStyle] as? Int, style != 0,
                      let font = attributes[NSAttributedString.Key.font] as? NSFont
                else { continue }
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let thickness = max(1, font.underlineThickness)
                result.append(Underline(
                    minX: position.x,
                    width: CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)),
                    offset: -font.underlinePosition - thickness / 2,
                    thickness: thickness,
                    color: attributes[NSAttributedString.Key.foregroundColor] as? NSColor ?? .linkColor
                ))
            }
            return result
        }

        private mutating func addCode(language: String?, body: String, highlighted: Bool) {
            typealias L = ACPTranscriptMarkdownLayout
            let top = y
            // The background is added first so it paints under the lines.
            backgrounds.append(Background(rect: .zero, color: .clear, cornerRadius: 0))
            let backgroundIndex = backgrounds.count - 1

            // The header is as tall as the taller of its label and the button.
            // SwiftUI rounds a font's ascent and descent up separately; its symbol
            // image is two points taller than that, which TextKit and `NSImage` miss
            // at small sizes.
            let buttonFont = NSFont.systemFont(ofSize: typography.labelSize, weight: .medium)
            let iconFont = NSFont.systemFont(ofSize: typography.labelSize, weight: .regular)
            let buttonHeight = max(Self.swiftUILineHeight(of: buttonFont), Self.swiftUILineHeight(of: iconFont) + 2)
                + 2 * L.copyButtonVerticalPadding
            let headerContentHeight = buttonHeight
            y += L.codeHeaderVerticalPadding
            let headerTop = y
            var headerHeight = max(L.codeEmptyHeaderContentHeight, headerContentHeight)
            if let language, !language.isEmpty {
                let label = NSAttributedString(string: language.uppercased(), attributes: [
                    .font: typography.appKitFont(size: typography.labelSize, traits: .boldFontMask),
                    .foregroundColor: theme.nsColor("fg-faint"),
                    .kern: L.codeLabelTracking,
                ])
                let first = lines.count
                addText(label, x: L.codeHeaderHorizontalPadding, width: max(1, width - 2 * L.codeHeaderHorizontalPadding), lineSpacing: 0)
                let labelHeight = y - headerTop
                headerHeight = max(labelHeight, headerContentHeight)
                for index in first..<lines.count {
                    lines[index].origin.y += (headerHeight - labelHeight) / 2
                }
            }
            codeBlocks.append(CodeBlock(
                code: body, maxX: width - L.codeHeaderHorizontalPadding,
                minY: headerTop + (headerHeight - buttonHeight) / 2, height: buttonHeight
            ))
            y = headerTop + headerHeight + L.codeHeaderVerticalPadding

            y += L.codeBodyVerticalPadding
            let code: NSAttributedString
            if highlighted {
                // As `ACPSyntaxHighlightedText`, so the colors match the SwiftUI block.
                code = HighlightCache.attributedString(code: body, language: language, theme: theme, typography: typography)
            } else {
                code = NSAttributedString(string: body, attributes: [
                    .font: CenterTypography.resolveCodeFont(family: typography.fontFamily, size: typography.codeSize),
                    .foregroundColor: theme.nsColor("fg"),
                ])
            }
            let firstCodeLine = lines.count
            // SwiftUI's line can be a point taller than TextKit's box.
            let codeFont = CenterTypography.resolveCodeFont(family: typography.fontFamily, size: typography.codeSize)
            addBlockText(
                code, x: L.codeBodyHorizontalPadding, width: max(1, width - 2 * L.codeBodyHorizontalPadding),
                lineSpacing: L.codeLineSpacing,
                lineHeight: Self.swiftUILineHeight(of: codeFont)
            )
            // Line spacing goes between lines, not after the last one.
            if lines.count > firstCodeLine {
                lines[lines.count - 1].height -= L.codeLineSpacing
                y -= L.codeLineSpacing
            }
            y += L.codeBodyVerticalPadding

            backgrounds[backgroundIndex] = Background(
                rect: CGRect(x: 0, y: top, width: width, height: y - top),
                color: theme.nsColor("bg-0").withAlphaComponent(L.codeBackgroundAlpha),
                cornerRadius: L.codeCornerRadius
            )
        }

        /// Adds a selectable block: its lines map back into `texts`.
        private mutating func addBlockText(
            _ text: NSAttributedString, x: CGFloat, width: CGFloat, lineSpacing: CGFloat = 0, lineHeight: CGFloat? = nil
        ) {
            texts.append(text.string)
            attributedTexts.append(text)
            addText(text, x: x, width: width, lineSpacing: lineSpacing, lineHeight: lineHeight, block: texts.count - 1)
        }

        /// Breaks `text` to `width` and stacks its lines from the current `y`.
        private mutating func addText(
            _ text: NSAttributedString, x: CGFloat, width: CGFloat, lineSpacing: CGFloat = 0, lineHeight: CGFloat? = nil,
            block: Int? = nil
        ) {
            guard text.length > 0 else { return }
            let typesetter = CTTypesetterCreateWithAttributedString(text)
            var start = 0
            while start < text.length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
                // Trailing whitespace hangs past the width; the drawn line leaves it off.
                let visible = Self.lengthWithoutTrailingWhitespace(text.string as NSString, from: start, count: count)
                // A zero-length range means "to the end of the string", so a blank
                // line gets an empty line of its own instead.
                let line = visible > 0
                    ? CTTypesetterCreateLine(typesetter, CFRange(location: start, length: visible))
                    : CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: text.attributes(at: start, effectiveRange: nil)))
                // A fallback font (emoji, CJK) can be taller than any `.font` attribute, and a
                // range without one measures 0; the line's own bounds are the floor.
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                let measured = max(lineHeight ?? Self.lineHeight(of: text, range: NSRange(location: start, length: count)), ascent + descent)
                let height = (measured > 0 ? measured : typography.paragraphSize) + lineSpacing
                lines.append(Line(
                    line: line, origin: CGPoint(x: x, y: y), height: height, underlines: Self.underlines(of: line),
                    block: block, range: NSRange(location: start, length: count), visibleLength: visible
                ))
                y += height
                start += count
            }
        }

        /// A line of `font` as SwiftUI sizes it: ascent, descent and leading each rounded up.
        private static func swiftUILineHeight(of font: NSFont) -> CGFloat {
            ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading)
        }

        private static func lengthWithoutTrailingWhitespace(_ string: NSString, from start: Int, count: Int) -> Int {
            var end = start + count
            while end > start, let scalar = Unicode.Scalar(string.character(at: end - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                end -= 1
            }
            return end - start
        }

        /// The tallest line box TextKit gives any font in `range`.
        private static func lineHeight(of text: NSAttributedString, range: NSRange) -> CGFloat {
            var height: CGFloat = 0
            text.enumerateAttribute(.font, in: range) { value, _, _ in
                if let font = value as? NSFont { height = max(height, TextKitLineHeight.of(font)) }
            }
            return height
        }
    }
}

/// Highlighted code by content, language, theme and font, so a width change
/// re-breaks lines without highlighting again. Entries are immutable copies.
@MainActor
private enum HighlightCache {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        // Long histories hold many unique blocks; keep the cache bounded.
        cache.countLimit = 256
        cache.totalCostLimit = 16 << 20
        return cache
    }()

    static func attributedString(
        code: String, language: String?, theme: Theme, typography: ACPChatTypography
    ) -> NSAttributedString {
        let resolved = language.flatMap(ACPCodeLanguage.highlighterExtension(for:))
        let key = [
            ACPSyntaxHighlightCacheKey.themeKey(theme), resolved ?? "", typography.fontFamily,
            "\(typography.codeSize)", code,
        ].joined(separator: "\u{0}") as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let highlighted = ACPCodeBlockHighlighter.attributedString(
            code: code, language: resolved, theme: theme, fontFamily: typography.fontFamily, fontSize: typography.codeSize
        )
        let stored = highlighted.copy() as! NSAttributedString
        cache.setObject(stored, forKey: key, cost: code.utf8.count)
        return stored
    }
}

/// A font's line height as `NSLayoutManager` lays it out, which is what
/// SwiftUI text and the diff rows match.
private enum TextKitLineHeight {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGFloat] = [:]

    static func of(_ font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let storage = NSTextStorage(string: "X\nX", attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let first = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let second = layoutManager.lineFragmentRect(forGlyphAt: 2, effectiveRange: nil)
        let height = second.minY - first.minY
        cache[key] = height
        return height
    }
}
