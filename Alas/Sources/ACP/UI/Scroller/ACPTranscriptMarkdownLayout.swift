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
        let origin: CGPoint
        let height: CGFloat
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

    let height: CGFloat
    let lines: [Line]
    let backgrounds: [Background]

    /// Whether every block can be drawn here. Tables, images, Mermaid diagrams
    /// and task lists need views of their own.
    static func supports(_ blocks: [ACPMarkdownParser.Block]) -> Bool {
        blocks.allSatisfy { block in
            switch block {
            case .table, .image, .mermaid, .taskList: false
            case .heading, .paragraph, .quote, .code, .streamingCode: true
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
        return ACPTranscriptMarkdownLayout(height: builder.y, lines: builder.lines, backgrounds: builder.backgrounds)
    }

    /// The lines whose boxes overlap `rect` vertically, including ones it only cuts.
    func linesIntersecting(_ rect: CGRect) -> ArraySlice<Line> {
        // Lines never overlap, so both edges are monotonic in index.
        let first = partitionPoint { $0.origin.y + $0.height <= rect.minY }
        let last = partitionPoint { $0.origin.y < rect.maxY }
        return first < last ? lines[first..<last] : lines[first..<first]
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

        mutating func add(_ block: ACPMarkdownParser.Block) {
            switch block {
            case .heading(let level, let text):
                y += level == 1 ? ACPTranscriptMarkdownLayout.h1TopPadding : ACPTranscriptMarkdownLayout.headingTopPadding
                addText(inline(text, role: .heading(level: level)), x: 0, width: width)
            case .paragraph(let text):
                addText(inline(text, role: .body), x: 0, width: width)
            case .quote(let text):
                let top = y
                let x = ACPTranscriptMarkdownLayout.quoteBarWidth + ACPTranscriptMarkdownLayout.quoteBarGap
                addText(inline(text, role: .quote), x: x, width: max(1, width - x))
                backgrounds.append(Background(
                    rect: CGRect(x: 0, y: top, width: ACPTranscriptMarkdownLayout.quoteBarWidth, height: y - top),
                    color: theme.nsColor("accent").withAlphaComponent(ACPTranscriptMarkdownLayout.quoteBarAlpha),
                    cornerRadius: 0
                ))
            case .code(let language, let body), .streamingCode(let language, let body):
                addCode(language: language, body: body)
            case .taskList, .image, .mermaid, .table:
                break
            }
        }

        private func inline(_ text: String, role: ACPMarkdownInlineRole) -> NSAttributedString {
            ACPMarkdownInlineRenderer.makeAttributedString(source: text, theme: theme, typography: typography, role: role)
        }

        private mutating func addCode(language: String?, body: String) {
            typealias L = ACPTranscriptMarkdownLayout
            let top = y
            // The background is added first so it paints under the lines.
            backgrounds.append(Background(rect: .zero, color: .clear, cornerRadius: 0))
            let backgroundIndex = backgrounds.count - 1

            if let language, !language.isEmpty {
                let label = NSAttributedString(string: language.uppercased(), attributes: [
                    .font: typography.appKitFont(size: typography.labelSize, traits: .boldFontMask),
                    .foregroundColor: theme.nsColor("fg-faint"),
                    .kern: L.codeLabelTracking,
                ])
                y += L.codeHeaderVerticalPadding
                addText(label, x: L.codeHeaderHorizontalPadding, width: max(1, width - 2 * L.codeHeaderHorizontalPadding), lineSpacing: 0)
                y += L.codeHeaderVerticalPadding
            } else {
                y += L.codeEmptyHeaderContentHeight + 2 * L.codeHeaderVerticalPadding
            }

            y += L.codeBodyVerticalPadding
            let code = NSAttributedString(string: body, attributes: [
                .font: CenterTypography.resolveCodeFont(family: typography.fontFamily, size: typography.codeSize),
                .foregroundColor: theme.nsColor("fg"),
            ])
            addText(
                code, x: L.codeBodyHorizontalPadding, width: max(1, width - 2 * L.codeBodyHorizontalPadding),
                lineSpacing: L.codeLineSpacing
            )
            y += L.codeBodyVerticalPadding

            backgrounds[backgroundIndex] = Background(
                rect: CGRect(x: 0, y: top, width: width, height: y - top),
                color: theme.nsColor("bg-0").withAlphaComponent(L.codeBackgroundAlpha),
                cornerRadius: L.codeCornerRadius
            )
        }

        /// Breaks `text` to `width` and stacks its lines from the current `y`.
        private mutating func addText(_ text: NSAttributedString, x: CGFloat, width: CGFloat, lineSpacing: CGFloat = 0) {
            guard text.length > 0 else { return }
            let typesetter = CTTypesetterCreateWithAttributedString(text)
            var start = 0
            while start < text.length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
                // Trailing whitespace hangs past the width; the drawn line leaves it off.
                let visible = Self.lengthWithoutTrailingWhitespace(text.string as NSString, from: start, count: count)
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: visible))
                // A fallback font (emoji, CJK) can be taller than any `.font` attribute, and a
                // range without one measures 0; the line's own bounds are the floor.
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                let measured = max(Self.lineHeight(of: text, range: NSRange(location: start, length: count)), ascent + descent)
                let height = (measured > 0 ? measured : typography.paragraphSize) + lineSpacing
                lines.append(Line(line: line, origin: CGPoint(x: x, y: y), height: height))
                y += height
                start += count
            }
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
