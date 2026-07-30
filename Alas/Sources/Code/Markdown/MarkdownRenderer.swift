import AppKit
import Markdown
import SwiftUI

/// Result of rendering a markdown document. The attributed string is the
/// only thing the preview text view consumes; the other maps support the
/// link-click handler and the async remote-image loader (filled in by
/// later tasks).
struct MarkdownRenderResult {
    let revision: UUID
    let attributedString: NSAttributedString
    let anchorRanges: [String: NSRange]
    let remoteImages: [RemoteImageReference]
    let mermaidAttachments: [MermaidAttachmentReference]
}

struct MermaidAttachmentReference {
    let id: String
    let source: String
    let profile: MermaidPresentationProfile
    let theme: MermaidDiagramTheme
    let attachment: MermaidTextAttachment
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
    private var mermaidAttachments: [MermaidAttachmentReference] = []
    private var mermaidSourceOccurrences: [String: Int] = [:]
    private var mermaidSourceTotals: [String: Int] = [:]
    private var mermaidProfile: MermaidPresentationProfile = .full
    private var theme: Theme!
    private var monoFamily: String = "JetBrainsMono Nerd Font"
    private var monoSize: CGFloat = 13
    private var baseDirectory: URL = URL(fileURLWithPath: "/")
    /// Optional worktree root, used to resolve markdown-style root-relative
    /// paths like `/assets/logo.png`. Nil for external tabs (where there is
    /// no worktree-rooted view of the file).
    private var worktreeRoot: URL?
    private let imageLoader = MarkdownImageLoader()

    private var currentTraits: NSFontDescriptor.SymbolicTraits = []
    private var inStrikethrough: Bool = false
    private var subscriptDepth: Int = 0
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
        frontmatter: MarkdownFrontmatter? = nil,
        theme: Theme,
        monospacedFontFamily: String,
        monospacedFontSize: Int,
        baseDirectory: URL,
        worktreeRoot: URL? = nil,
        mermaidProfile: MermaidPresentationProfile = .full
    ) -> MarkdownRenderResult {
        self.output = NSMutableAttributedString()
        self.anchorRanges = [:]
        self.remoteImages = []
        self.mermaidAttachments = []
        self.mermaidSourceOccurrences = [:]
        self.mermaidSourceTotals = Self.mermaidSourceTotals(in: document)
        self.mermaidProfile = mermaidProfile
        self.theme = theme
        self.monoFamily = monospacedFontFamily
        self.monoSize = CGFloat(monospacedFontSize)
        self.baseDirectory = baseDirectory
        self.worktreeRoot = worktreeRoot
        self.currentTraits = []
        self.inStrikethrough = false
        self.subscriptDepth = 0
        self.listDepth = 0
        self.slugCounts = [:]

        if let frontmatter, !frontmatter.isEmpty {
            renderFrontmatterTable(frontmatter)
        }

        for child in document.children {
            visit(child)
        }
        return MarkdownRenderResult(
            revision: UUID(),
            attributedString: output.copy() as! NSAttributedString,
            anchorRanges: anchorRanges,
            remoteImages: remoteImages,
            mermaidAttachments: mermaidAttachments
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
        case let h as InlineHTML:       visitInlineHTML(h)
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
            // Path resolution for local images:
            //  * `/foo.png` in an in-worktree document → worktree root + foo.png
            //    (mirrors how the link handler treats `/README.md`).
            //  * `/foo.png` in an external preview → real filesystem-absolute
            //    path; load directly without prepending baseDirectory.
            //  * everything else → resolve against the document's directory.
            let loaded: NSImage?
            if path.hasPrefix("/"), let root = worktreeRoot {
                loaded = imageLoader.loadLocal(src: String(path.dropFirst()), baseDirectory: root)
            } else if path.hasPrefix("/") {
                loaded = NSImage(contentsOf: URL(fileURLWithPath: path))
            } else {
                loaded = imageLoader.loadLocal(src: path, baseDirectory: baseDirectory)
            }
            if let loaded {
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

    private func visitInlineHTML(_ html: InlineHTML) {
        let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isSubscriptOpenTag(raw) {
            subscriptDepth += 1
        } else if raw.caseInsensitiveCompare("</sub>") == .orderedSame {
            subscriptDepth = max(0, subscriptDepth - 1)
        }
    }

    private static func isSubscriptOpenTag(_ raw: String) -> Bool {
        guard raw.hasPrefix("<") else { return false }
        let lower = raw.lowercased()
        guard lower.hasPrefix("<sub") else { return false }
        let nameEnd = lower.index(lower.startIndex, offsetBy: 4)
        guard nameEnd < lower.endIndex else { return false }
        let next = lower[nameEnd]
        guard next == ">" || next.isWhitespace else { return false }
        return lower.last == ">"
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
        let blockNS = NSRange(location: startOfBlock, length: output.length - startOfBlock)
        guard blockNS.length > 0 else { return }
        // Insert a muted "│ " prefix at the start of every line in the just-
        // rendered block. We work on the attributed substring so existing
        // inline attributes (links, bold, italic, inline code) survive — a
        // plain-`String` rebuild would drop them and turn `> see [docs](url)`
        // into inert text.
        let blockAttr = output.attributedSubstring(from: blockNS)
        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(theme.color("fg-muted")),
            .font: bodyFont()
        ]
        let prefix = NSAttributedString(string: "│ ", attributes: prefixAttrs)
        let rebuilt = NSMutableAttributedString(attributedString: blockAttr)
        let raw = rebuilt.string as NSString
        var insertions: [Int] = [0]
        for i in 0..<raw.length where raw.character(at: i) == 0x0A && i + 1 < raw.length {
            insertions.append(i + 1)
        }
        // Insert from end to start so earlier positions stay valid.
        for pos in insertions.reversed() {
            rebuilt.insert(prefix, at: pos)
        }
        output.replaceCharacters(in: blockNS, with: rebuilt)
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
        if let source = Self.mermaidSource(from: block) {
            let id = mermaidID(for: source, block: block)
            let attachment = MermaidTextAttachment(
                id: id,
                source: source,
                profile: mermaidProfile
            )
            output.append(NSAttributedString(attachment: attachment))
            output.append(NSAttributedString(string: "\n"))
            mermaidAttachments.append(MermaidAttachmentReference(
                id: id,
                source: source,
                profile: mermaidProfile,
                theme: MermaidDiagramTheme(theme: theme),
                attachment: attachment
            ))
            return
        }

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

    private func mermaidID(for source: String, block: CodeBlock) -> String {
        let key = Self.stableMermaidSourceKey(source)
        if mermaidSourceTotals[key, default: 0] <= 1 {
            return "mermaid-\(key)"
        }
        if let locationKey = Self.stableMermaidLocationKey(block.range) {
            return "mermaid-\(key)-\(locationKey)"
        }
        let occurrence = mermaidSourceOccurrences[key, default: 0]
        mermaidSourceOccurrences[key] = occurrence + 1
        if occurrence == 0 {
            return "mermaid-\(key)"
        }
        return "mermaid-\(key)-\(occurrence)"
    }

    static func stableMermaidSourceKey(_ source: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func mermaidSource(from block: CodeBlock) -> String? {
        guard MermaidFence.isMermaid(language: block.language),
              !block.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return block.code.hasSuffix("\n")
            ? String(block.code.dropLast())
            : block.code
    }

    private static func mermaidSourceTotals(in markup: Markup) -> [String: Int] {
        var totals: [String: Int] = [:]
        collectMermaidSourceTotals(in: markup, into: &totals)
        return totals
    }

    private static func collectMermaidSourceTotals(
        in markup: Markup,
        into totals: inout [String: Int]
    ) {
        if let block = markup as? CodeBlock,
           let source = mermaidSource(from: block) {
            totals[stableMermaidSourceKey(source), default: 0] += 1
        }
        for child in markup.children {
            collectMermaidSourceTotals(in: child, into: &totals)
        }
    }

    private static func stableMermaidLocationKey(_ range: SourceRange?) -> String? {
        guard let range else { return nil }
        return [
            range.lowerBound.line,
            range.lowerBound.column,
            range.upperBound.line,
            range.upperBound.column
        ]
        .map(String.init)
        .joined(separator: "-")
    }

    private struct RenderedTableCell {
        let content: NSAttributedString
        let row: Int
        let column: Int
        let isHeader: Bool
        let alignment: NSTextAlignment
    }

    private func textAlignment(for alignment: Markdown.Table.ColumnAlignment?) -> NSTextAlignment {
        switch alignment {
        case .center: return .center
        case .right: return .right
        case .left, .none: return .left
        }
    }

    private func renderTableCell(_ cell: Markdown.Table.Cell) -> NSAttributedString {
        let savedOutput = output
        let savedTraits = currentTraits
        let savedStrikethrough = inStrikethrough
        let savedSubscriptDepth = subscriptDepth
        let cellOutput = NSMutableAttributedString()

        output = cellOutput
        currentTraits = []
        inStrikethrough = false
        subscriptDepth = 0

        for child in cell.children {
            if let paragraph = child as? Paragraph {
                for inline in paragraph.children {
                    visit(inline)
                }
            } else {
                visit(child)
            }
        }

        let rendered = cellOutput.copy() as! NSAttributedString
        output = savedOutput
        currentTraits = savedTraits
        inStrikethrough = savedStrikethrough
        subscriptDepth = savedSubscriptDepth

        if rendered.length > 0 {
            return rendered
        }
        return NSAttributedString(string: "", attributes: bodyAttributes())
    }

    private func tableParagraphStyle(
        table: NSTextTable,
        row: Int,
        column: Int,
        columnCount: Int,
        isHeader: Bool,
        isBandedRow: Bool,
        alignment: NSTextAlignment
    ) -> NSParagraphStyle {
        let block = NSTextTableBlock(
            table: table,
            startingRow: row,
            rowSpan: 1,
            startingColumn: column,
            columnSpan: 1
        )
        block.verticalAlignment = .middleAlignment
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(0.5, type: .absoluteValueType, for: .border)
        block.setBorderColor(NSColor(theme.color("fg-faint")))
        let backgroundToken: String
        if isHeader {
            backgroundToken = "bg-3"
        } else if isBandedRow {
            backgroundToken = "bg-2"
        } else {
            backgroundToken = "bg-1"
        }
        block.backgroundColor = NSColor(theme.color(backgroundToken))

        if columnCount > 0 {
            block.setContentWidth(100 / CGFloat(columnCount), type: .percentageValueType)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [block]
        paragraph.alignment = alignment
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = CenterTypography.lineHeightMultiple
        return paragraph
    }

    private func renderFrontmatterTable(_ frontmatter: MarkdownFrontmatter) {
        let columnCount = 2
        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        var renderedCells: [RenderedTableCell] = [
            RenderedTableCell(
                content: NSAttributedString(string: "Key", attributes: bodyAttributes()),
                row: 0,
                column: 0,
                isHeader: true,
                alignment: .left
            ),
            RenderedTableCell(
                content: NSAttributedString(string: "Value", attributes: bodyAttributes()),
                row: 0,
                column: 1,
                isHeader: true,
                alignment: .left
            )
        ]

        for (index, entry) in frontmatter.entries.enumerated() {
            renderedCells.append(RenderedTableCell(
                content: NSAttributedString(string: entry.key, attributes: bodyAttributes()),
                row: index + 1,
                column: 0,
                isHeader: false,
                alignment: .left
            ))
            renderedCells.append(RenderedTableCell(
                content: NSAttributedString(string: entry.value, attributes: bodyAttributes()),
                row: index + 1,
                column: 1,
                isHeader: false,
                alignment: .left
            ))
        }

        appendTableCells(renderedCells, table: textTable, columnCount: columnCount)
    }

    private func visitTable(_ table: Markdown.Table) {
        let headerCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows)
        let columnCount = max(
            headerCells.count,
            bodyRows.map { (row: Markdown.Table.Row) in Array(row.cells).count }.max() ?? 0
        )
        guard columnCount > 0 else { return }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        let alignments = table.columnAlignments
        var renderedCells: [RenderedTableCell] = []

        for column in 0..<columnCount {
            let content: NSAttributedString
            if column < headerCells.count {
                content = renderTableCell(headerCells[column])
            } else {
                content = NSAttributedString(string: "", attributes: bodyAttributes())
            }
            renderedCells.append(RenderedTableCell(
                content: content,
                row: 0,
                column: column,
                isHeader: true,
                alignment: textAlignment(for: column < alignments.count ? alignments[column] : nil)
            ))
        }

        for (bodyIndex, row) in bodyRows.enumerated() {
            let rowCells = Array(row.cells)
            for column in 0..<columnCount {
                let content: NSAttributedString
                if column < rowCells.count {
                    content = renderTableCell(rowCells[column])
                } else {
                    content = NSAttributedString(string: "", attributes: bodyAttributes())
                }
                renderedCells.append(RenderedTableCell(
                    content: content,
                    row: bodyIndex + 1,
                    column: column,
                    isHeader: false,
                    alignment: textAlignment(for: column < alignments.count ? alignments[column] : nil)
                ))
            }
        }

        appendTableCells(renderedCells, table: textTable, columnCount: columnCount)
    }

    private func appendTableCells(
        _ renderedCells: [RenderedTableCell],
        table textTable: NSTextTable,
        columnCount: Int
    ) {
        for cell in renderedCells {
            let mutable = NSMutableAttributedString(attributedString: cell.content)
            let style = tableParagraphStyle(
                table: textTable,
                row: cell.row,
                column: cell.column,
                columnCount: columnCount,
                isHeader: cell.isHeader,
                isBandedRow: !cell.isHeader && cell.row.isMultiple(of: 2),
                alignment: cell.alignment
            )
            let fullRange = NSRange(location: 0, length: mutable.length)
            if fullRange.length > 0 {
                mutable.addAttribute(.paragraphStyle, value: style, range: fullRange)
                if cell.isHeader {
                    applyHeaderTableFont(to: mutable, range: fullRange)
                }
            } else {
                mutable.append(NSAttributedString(string: " ", attributes: [
                    .font: cell.isHeader ? headerTableFont() : bodyFont(),
                    .foregroundColor: NSColor(theme.color("fg")),
                    .paragraphStyle: style
                ]))
            }
            output.append(mutable)
            output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
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
        let isSubscript = subscriptDepth > 0
        var attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont(size: isSubscript ? subscriptFontSize(base: NSFont.systemFontSize) : NSFont.systemFontSize),
            .foregroundColor: NSColor(theme.color("fg"))
        ]
        if inStrikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if isSubscript {
            attrs[.baselineOffset] = -max(1, subscriptFontSize(base: NSFont.systemFontSize) * 0.22)
        }
        return attrs
    }

    private func inlineCodeAttributes() -> [NSAttributedString.Key: Any] {
        let isSubscript = subscriptDepth > 0
        var attrs: [NSAttributedString.Key: Any] = [
            .font: monospaceFont(size: isSubscript ? subscriptFontSize(base: monoSize - 1) : monoSize - 1),
            .foregroundColor: NSColor(theme.color("fg")),
            .backgroundColor: NSColor(theme.color("bg-2"))
        ]
        if isSubscript {
            attrs[.baselineOffset] = -max(1, subscriptFontSize(base: monoSize - 1) * 0.22)
        }
        return attrs
    }

    private func bodyFont(size: CGFloat = NSFont.systemFontSize) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if currentTraits.isEmpty { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(currentTraits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    private func subscriptFontSize(base: CGFloat) -> CGFloat {
        max(7, base * 0.82)
    }

    private func headerTableFont() -> NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    }

    private func applyHeaderTableFont(to mutable: NSMutableAttributedString, range: NSRange) {
        mutable.enumerateAttribute(.font, in: range) { value, range, _ in
            guard let font = value as? NSFont else {
                mutable.addAttribute(.font, value: headerTableFont(), range: range)
                return
            }
            guard !font.isFixedPitch else { return }

            let traits = font.fontDescriptor.symbolicTraits
            if traits.isEmpty {
                mutable.addAttribute(.font, value: headerTableFont(), range: range)
                return
            }

            let headerTraits = traits.union(.bold)
            let descriptor = font.fontDescriptor.withSymbolicTraits(headerTraits)
            guard let headerFont = NSFont(descriptor: descriptor, size: font.pointSize) else {
                return
            }
            mutable.addAttribute(.font, value: headerFont, range: range)
        }
    }

    private func monospaceFont(size: CGFloat) -> NSFont {
        CenterTypography.resolveCodeFont(family: monoFamily, size: size)
    }

    // MARK: - Append helpers

    private func appendText(_ s: String, attributes: [NSAttributedString.Key: Any]) {
        output.append(NSAttributedString(string: s, attributes: attributes))
    }

    private func appendPlain(_ s: String) {
        output.append(NSAttributedString(string: s, attributes: bodyAttributes()))
    }
}
