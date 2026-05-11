import AppKit
import Markdown
import SwiftUI

/// Result of rendering a markdown document. The attributed string is the
/// only thing the preview text view consumes; the other maps support the
/// link-click handler and the async remote-image loader (filled in by
/// later tasks).
struct MarkdownRenderResult {
    let attributedString: NSAttributedString
    let anchorRanges: [String: NSRange]
    let remoteImages: [RemoteImageReference]
}

/// Captures one `https://`-image attachment in the result. The
/// MarkdownPreviewController uses this to fire off async fetches and
/// patch the text storage when each image arrives.
struct RemoteImageReference {
    let url: URL
    let attachment: NSTextAttachment
}

@MainActor
final class MarkdownRenderer {
    private var output: NSMutableAttributedString = .init()
    private var anchorRanges: [String: NSRange] = [:]
    private var remoteImages: [RemoteImageReference] = []
    private var theme: Theme!
    private var monoFamily: String = "SF Mono"
    private var monoSize: CGFloat = 13
    private var baseDirectory: URL = URL(fileURLWithPath: "/")
    private let imageLoader = MarkdownImageLoader()

    private var currentTraits: NSFontDescriptor.SymbolicTraits = []
    private var inStrikethrough: Bool = false
    private var listDepth: Int = 0
    /// Counts how many times each base slug has been seen so duplicate
    /// headings get GitHub-style `-1`, `-2`, … suffixes instead of clobbering
    /// the earlier range in `anchorRanges`.
    private var slugCounts: [String: Int] = [:]

    private static let fenceLanguageToExtension: [String: String] = [
        "swift": "swift",
        "rust": "rs", "rs": "rs",
        "json": "json",
        "markdown": "md", "md": "md",
        "python": "py", "py": "py",
        "typescript": "ts", "ts": "ts",
        "javascript": "js", "js": "js",
        "tsx": "tsx", "jsx": "jsx",
        "kotlin": "kt", "kt": "kt"
    ]

    private func extensionFor(fenceLanguage info: String?) -> String? {
        guard let info, !info.isEmpty else { return nil }
        let tag = info.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        return MarkdownRenderer.fenceLanguageToExtension[tag]
    }

    func render(
        document: Document,
        theme: Theme,
        monospacedFontFamily: String,
        monospacedFontSize: Int,
        baseDirectory: URL
    ) -> MarkdownRenderResult {
        self.output = NSMutableAttributedString()
        self.anchorRanges = [:]
        self.remoteImages = []
        self.theme = theme
        self.monoFamily = monospacedFontFamily
        self.monoSize = CGFloat(monospacedFontSize)
        self.baseDirectory = baseDirectory
        self.currentTraits = []
        self.inStrikethrough = false
        self.listDepth = 0
        self.slugCounts = [:]

        for child in document.children {
            visit(child)
        }
        return MarkdownRenderResult(
            attributedString: output.copy() as! NSAttributedString,
            anchorRanges: anchorRanges,
            remoteImages: remoteImages
        )
    }

    // MARK: - Dispatch

    private func visit(_ markup: Markup) {
        switch markup {
        case let p as Paragraph:        visitParagraph(p)
        case let t as Markdown.Text:    appendText(t.string, attributes: bodyAttributes())
        case let e as Emphasis:         withTrait(.italic) { visitChildren(e) }
        case let s as Strong:           withTrait(.bold) { visitChildren(s) }
        case let s as Strikethrough:    withStrikethrough { visitChildren(s) }
        case let c as InlineCode:       appendText(c.code, attributes: inlineCodeAttributes())
        case _ as SoftBreak:            appendPlain(" ")
        case _ as LineBreak:            appendPlain("\n")
        case let l as Markdown.Link:    visitLink(l)
        case let img as Markdown.Image: visitImage(img)
        case let h as Heading:          visitHeading(h)
        case let l as UnorderedList:    visitUnorderedList(l)
        case let l as OrderedList:      visitOrderedList(l)
        case let b as BlockQuote:       visitBlockQuote(b)
        case _ as ThematicBreak:        appendThematicBreak()
        case let c as CodeBlock:        visitCodeBlock(c)
        case let t as Markdown.Table:   visitTable(t)
        default:
            visitChildren(markup)
        }
    }

    private func visitChildren(_ markup: Markup) {
        for child in markup.children { visit(child) }
    }

    private func visitParagraph(_ p: Paragraph) {
        for child in p.children { visit(child) }
        appendPlain("\n\n")
    }

    private func visitLink(_ link: Markdown.Link) {
        let start = output.length
        visitChildren(link)
        guard let dest = link.destination, !dest.isEmpty,
              start < output.length else { return }
        guard let url = URL(string: dest) else { return }
        let range = NSRange(location: start, length: output.length - start)
        output.addAttribute(.link, value: url, range: range)
        output.addAttribute(.foregroundColor, value: NSColor(theme.color("accent")), range: range)
        output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    }

    private func visitImage(_ image: Markdown.Image) {
        let alt = image.plainText
        let src = image.source ?? ""
        switch MarkdownImageLoader.classify(src) {
        case .invalid:
            if !alt.isEmpty {
                output.append(NSAttributedString(string: alt, attributes: mutedAttributes()))
            }
        case .local(let path):
            if let loaded = imageLoader.loadLocal(src: path, baseDirectory: baseDirectory) {
                output.append(attachmentString(for: loaded))
            } else if !alt.isEmpty {
                output.append(NSAttributedString(string: alt, attributes: mutedAttributes()))
            }
        case .remote(let url):
            let attachment = NSTextAttachment()
            attachment.bounds = NSRect(x: 0, y: 0, width: 200, height: 16)
            remoteImages.append(RemoteImageReference(url: url, attachment: attachment))
            output.append(NSAttributedString(attachment: attachment))
        }
    }

    private func attachmentString(for image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        let maxWidth: CGFloat = 600
        if image.size.width > maxWidth {
            let scale = maxWidth / image.size.width
            attachment.bounds = NSRect(x: 0, y: 0, width: maxWidth, height: image.size.height * scale)
        } else {
            attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        }
        return NSAttributedString(attachment: attachment)
    }

    private func mutedAttributes() -> [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor(theme.color("fg-muted")), .font: bodyFont()]
    }

    private func visitHeading(_ heading: Heading) {
        let start = output.length
        let plain = heading.plainText
        let size = headingFontSize(level: heading.level)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor(theme.color("fg"))
        ]
        output.append(NSAttributedString(string: plain, attributes: attrs))
        let length = output.length - start
        let baseSlug = MarkdownRenderer.slugify(plain)
        if !baseSlug.isEmpty, length > 0 {
            // GitHub-style disambiguation: first occurrence keeps the bare slug,
            // subsequent occurrences get `-1`, `-2`, … so `[link](#install)`
            // resolves to the first `## Install` heading instead of the last.
            let count = slugCounts[baseSlug, default: 0]
            let finalSlug = count == 0 ? baseSlug : "\(baseSlug)-\(count)"
            anchorRanges[finalSlug] = NSRange(location: start, length: length)
            slugCounts[baseSlug] = count + 1
        }
        appendPlain("\n\n")
    }

    private func headingFontSize(level: Int) -> CGFloat {
        switch level {
        case 1: return 28
        case 2: return 22
        case 3: return 18
        case 4: return 16
        case 5: return 14
        default: return 13
        }
    }

    private func visitUnorderedList(_ list: UnorderedList) {
        listDepth += 1
        defer { listDepth -= 1 }
        for item in list.listItems {
            appendListItem(item, marker: marker(for: item))
        }
        if listDepth == 0 { appendPlain("\n") }
    }

    private func visitOrderedList(_ list: OrderedList) {
        listDepth += 1
        defer { listDepth -= 1 }
        var n = 1
        for item in list.listItems {
            appendListItem(item, marker: "\(n). ")
            n += 1
        }
        if listDepth == 0 { appendPlain("\n") }
    }

    private func visitBlockQuote(_ quote: BlockQuote) {
        let startOfBlock = output.length
        for child in quote.children { visit(child) }
        // Insert a "│ " prefix on every line of the just-rendered block.
        let nsOutput = output.string as NSString
        let blockNS = NSRange(location: startOfBlock, length: nsOutput.length - startOfBlock)
        guard blockNS.length > 0 else { return }
        let blockText = nsOutput.substring(with: blockNS)
        let lines = blockText.split(separator: "\n", omittingEmptySubsequences: false)
        let rebuilt = lines.map { "│ \($0)" }.joined(separator: "\n")
        output.replaceCharacters(in: blockNS, with: rebuilt)
        // Color the entire rebuilt block in muted foreground.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(theme.color("fg-muted")),
            .font: bodyFont()
        ]
        output.addAttributes(attrs, range: NSRange(location: startOfBlock, length: (rebuilt as NSString).length))
    }

    private func appendThematicBreak() {
        let line = String(repeating: "─", count: 32)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(theme.color("fg-faint")),
            .font: bodyFont()
        ]
        output.append(NSAttributedString(string: line + "\n\n", attributes: attrs))
    }

    private func visitCodeBlock(_ block: CodeBlock) {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: monospaceFont(size: monoSize),
            .foregroundColor: NSColor(theme.color("fg")),
            .backgroundColor: NSColor(theme.color("bg-2"))
        ]
        let start = output.length
        output.append(NSAttributedString(string: block.code, attributes: baseAttrs))
        let length = output.length - start

        if let ext = extensionFor(fenceLanguage: block.language) {
            let spans = TreeSitterHighlighter.highlight(source: block.code, fileExtension: ext)
            let editorTheme = EditorTheme(theme: theme)
            let blockRange = NSRange(location: start, length: length)
            for span in spans {
                let absolute = NSRange(location: start + span.range.location,
                                       length: span.range.length)
                // Guard against spans that escape the block (shouldn't happen,
                // but defensive: TreeSitter is sometimes imprecise).
                guard NSIntersectionRange(absolute, blockRange).length == absolute.length else { continue }
                let attrs = editorTheme.attributes(for: span.capture)
                for (key, value) in attrs {
                    output.addAttribute(key, value: value, range: absolute)
                }
            }
        }
        appendPlain("\n")
    }

    private func visitTable(_ table: Markdown.Table) {
        let header: [String] = table.head.cells.map { $0.plainText }
        let bodyRows: [[String]] = table.body.rows.map { (row: Markdown.Table.Row) -> [String] in
            row.cells.map { (cell: Markdown.Table.Cell) -> String in cell.plainText }
        }
        let allRows: [[String]] = [header] + bodyRows
        let columnCount = allRows.map { (r: [String]) -> Int in r.count }.max() ?? 0
        guard columnCount > 0 else { return }

        var widths = Array(repeating: 0, count: columnCount)
        for row in allRows {
            for (i, cell) in row.enumerated() where i < columnCount {
                widths[i] = max(widths[i], cell.count)
            }
        }

        func formatRow(_ row: [String]) -> String {
            let padded = (0..<columnCount).map { i -> String in
                let cell = i < row.count ? row[i] : ""
                return cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }

        let separator = "|-" + widths.map { String(repeating: "-", count: $0) }.joined(separator: "-|-") + "-|"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: monospaceFont(size: monoSize),
            .foregroundColor: NSColor(theme.color("fg"))
        ]
        output.append(NSAttributedString(string: formatRow(header) + "\n", attributes: attrs))
        output.append(NSAttributedString(string: separator + "\n", attributes: attrs))
        for row in bodyRows {
            output.append(NSAttributedString(string: formatRow(row) + "\n", attributes: attrs))
        }
        appendPlain("\n")
    }

    private func marker(for item: ListItem) -> String {
        switch item.checkbox {
        case .checked:   return "☑ "
        case .unchecked: return "☐ "
        case .none:      return "• "
        }
    }

    private func appendListItem(_ item: ListItem, marker: String) {
        let indent = String(repeating: "  ", count: max(0, listDepth - 1))
        appendPlain(indent + marker)
        // Render the first Paragraph child inline (no surrounding blank line),
        // so the marker sits on the same line as the text. Subsequent block
        // children (nested lists, code blocks) are visited normally.
        var firstParagraphConsumed = false
        for child in item.children {
            if !firstParagraphConsumed, let p = child as? Paragraph {
                for inline in p.children { visit(inline) }
                appendPlain("\n")
                firstParagraphConsumed = true
            } else {
                visit(child)
            }
        }
    }

    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if scalar == " " || scalar == "-" || scalar == "_" {
                if !lastWasDash {
                    out.append("-")
                    lastWasDash = true
                }
            }
            // All other punctuation (apostrophes, commas, question marks, etc) is dropped.
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: - Trait scoping

    private func withTrait(_ t: NSFontDescriptor.SymbolicTraits, body: () -> Void) {
        let previous = currentTraits
        currentTraits.insert(t)
        body()
        currentTraits = previous
    }

    private func withStrikethrough(body: () -> Void) {
        let previous = inStrikethrough
        inStrikethrough = true
        body()
        inStrikethrough = previous
    }

    // MARK: - Attributes

    private func bodyAttributes() -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont(),
            .foregroundColor: NSColor(theme.color("fg"))
        ]
        if inStrikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    private func inlineCodeAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: monospaceFont(size: monoSize - 1),
            .foregroundColor: NSColor(theme.color("fg")),
            .backgroundColor: NSColor(theme.color("bg-2"))
        ]
    }

    private func bodyFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if currentTraits.isEmpty { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(currentTraits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    private func monospaceFont(size: CGFloat) -> NSFont {
        NSFont(name: monoFamily, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Append helpers

    private func appendText(_ s: String, attributes: [NSAttributedString.Key: Any]) {
        output.append(NSAttributedString(string: s, attributes: attributes))
    }

    private func appendPlain(_ s: String) {
        output.append(NSAttributedString(string: s, attributes: bodyAttributes()))
    }
}
