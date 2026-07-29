import SwiftUI
import AppKit

/// Small markdown renderer for ACP chat content. Handles block-level
/// constructs (headings, fenced code, blockquotes) ourselves and lets
/// `AttributedString(markdown:)` handle the inline grammar (bold,
/// italic, inline `code`, links) inside each paragraph.
///
/// Not a full CommonMark implementation — the agent output we see is
/// almost always prose + occasional headings + occasional code blocks.
/// Anything we don't recognise falls through as plain text so we never
/// blank out an agent message.
struct ACPMarkdownText: View {
    let raw: String
    var cache: ACPMarkdownBlockCache? = nil
    var knownAppendedSuffix: String? = nil
    var updateRevision: UInt64? = nil
    var updateSourceID: ObjectIdentifier? = nil
    var typography: ACPChatTypography = .default
    var showsCodeBlockCopyButton: Bool = true
    @Environment(\.theme) private var theme
    @State private var tableViewportWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(currentRenderBlocks().enumerated()), id: \.offset) { _, renderBlock in
                view(for: renderBlock)
            }
        }
    }

    private func currentRenderBlocks() -> [RenderBlock] {
        if let cache {
            cache.update(
                with: raw,
                knownAppendedSuffix: knownAppendedSuffix,
                revision: updateRevision,
                sourceID: updateSourceID
            )
            let tailBlocks = ACPMarkdownText.parse(cache.tailUnparsed)
            return cache.stableBlocks.map { RenderBlock(block: $0, memoizesInlineMarkdown: true) }
                + tailBlocks.map { RenderBlock(block: $0, memoizesInlineMarkdown: false) }
        }
        return ACPMarkdownText.parse(raw).map { RenderBlock(block: $0, memoizesInlineMarkdown: true) }
    }

    @ViewBuilder
    private func view(for renderBlock: RenderBlock) -> some View {
        switch renderBlock.block {
        case .heading(let level, let text):
            ACPMarkdownInlineTextView(
                source: text,
                typography: typography,
                role: .heading(level: level),
                theme: theme,
                memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
            )
                .padding(.top, level == 1 ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            ACPMarkdownInlineTextView(
                source: text,
                typography: typography,
                role: .body,
                theme: theme,
                memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        case .taskList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        ACPMarkdownTaskCheckbox(
                            isChecked: item.isChecked,
                            accessibilityLabel: ACPMarkdownInlineRenderer.plainText(item.text)
                        )
                            .frame(width: 16, height: 16)
                            .padding(.top, 1)
                        ACPMarkdownInlineTextView(
                            source: item.text,
                            typography: typography,
                            role: .body,
                            theme: theme,
                            memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(theme.color("accent").opacity(0.55))
                    .frame(width: 2)
                ACPMarkdownInlineTextView(
                    source: text,
                    typography: typography,
                    role: .quote,
                    theme: theme,
                    memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
        case .code(let lang, let body):
            CodeBlockView(
                language: lang,
                code: body,
                typography: typography,
                showsCopyButton: showsCodeBlockCopyButton,
                highlightsSyntax: true
            )
        case .streamingCode(let lang, let body):
            CodeBlockView(
                language: lang,
                code: body,
                typography: typography,
                showsCopyButton: showsCodeBlockCopyButton,
                highlightsSyntax: false
            )
        case .table(let header, let rows):
            tableView(
                header: header,
                rows: rows,
                memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
            )
        }
    }

    private func tableView(
        header: [String],
        rows: [[String]],
        memoizesInlineMarkdown: Bool
    ) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let columnWidth = Self.tableColumnWidth(
            availableWidth: tableViewportWidth,
            columnCount: columnCount
        )
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(
                    cells: header,
                    isHeader: true,
                    columnCount: columnCount,
                    columnWidth: columnWidth,
                    memoizesInlineMarkdown: memoizesInlineMarkdown
                )
                Rectangle().fill(theme.color("line")).frame(height: 0.5)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    tableRow(
                        cells: r,
                        isHeader: false,
                        columnCount: columnCount,
                        columnWidth: columnWidth,
                        memoizesInlineMarkdown: memoizesInlineMarkdown
                    )
                    if r != rows.last {
                        Rectangle().fill(theme.color("line-soft")).frame(height: 0.5)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            tableViewportWidth = width
        }
        .background(theme.color("bg-1").opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    private func tableRow(
        cells: [String],
        isHeader: Bool,
        columnCount: Int,
        columnWidth: CGFloat,
        memoizesInlineMarkdown: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { i in
                let value = i < cells.count ? cells[i] : ""
                ACPMarkdownInlineTextView(
                    source: value,
                    typography: typography,
                    role: .tableCell(isHeader: isHeader),
                    theme: theme,
                    memoizesInlineMarkdown: memoizesInlineMarkdown
                )
                    .frame(minWidth: 80, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(width: columnWidth, alignment: .leading)
                if i < columnCount - 1 {
                    Rectangle().fill(theme.color("line-soft")).frame(width: 0.5)
                }
            }
        }
        .background(isHeader ? theme.color("bg-2").opacity(0.5) : Color.clear)
    }

    static func tableColumnWidth(
        availableWidth: CGFloat,
        columnCount: Int,
        dividerWidth: CGFloat = 0.5
    ) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        return max(100, (availableWidth - dividerWidth * CGFloat(columnCount - 1)) / CGFloat(columnCount))
    }

    // MARK: - Inline memoization

    private static let inlineCache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 512
        return c
    }()

    private static let inlineCacheStatsLock = NSLock()
    nonisolated(unsafe) private static var inlineCacheInsertionCount = 0

    static var inlineCacheInsertionCountForTesting: Int {
        inlineCacheStatsLock.lock()
        defer { inlineCacheStatsLock.unlock() }
        return inlineCacheInsertionCount
    }

    static func removeAllInlineCacheObjectsForTesting() {
        inlineCache.removeAllObjects()
        inlineCacheStatsLock.lock()
        defer { inlineCacheStatsLock.unlock() }
        inlineCacheInsertionCount = 0
    }

    /// Inline parser: bold / italic / inline code / links via the
    /// system AttributedString initializer. Results are memoized in a
    /// process-static NSCache; stable blocks stay warm across chunks.
    static func inlineMarkdown(_ s: String, memoize: Bool = true) -> AttributedString {
        let key = s as NSString
        if memoize, let hit = inlineCache.object(forKey: key) {
            return AttributedString(hit)
        }
        let renderSource = ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            s,
            preserveFencedCodeBlocks: false
        )
        let attr: AttributedString
        if let parsed = try? AttributedString(
            markdown: renderSource,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            attr = parsed
        } else {
            attr = AttributedString(s)
        }
        if memoize {
            inlineCache.setObject(NSAttributedString(attr), forKey: key)
            inlineCacheStatsLock.lock()
            inlineCacheInsertionCount += 1
            inlineCacheStatsLock.unlock()
        }
        return attr
    }

    // MARK: - Block parser

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case taskList([TaskItem])
        case quote(String)
        case code(language: String?, body: String)
        case streamingCode(language: String?, body: String)
        case table(header: [String], rows: [[String]])
    }

    struct TaskItem: Equatable {
        let isChecked: Bool
        let text: String
    }

    private struct RenderBlock {
        let block: Block
        let memoizesInlineMarkdown: Bool
    }

    /// Detect a GitHub-flavoured markdown table starting at `start`:
    ///   | h1 | h2 |
    ///   |----|----|
    ///   | a  | b  |
    /// Returns header cells + body rows + number of consumed lines, or nil.
    private static func matchTable(from lines: [String], at start: Int) -> ([String], [[String]], Int)? {
        guard start + 1 < lines.count else { return nil }
        let head = lines[start].trimmingCharacters(in: .whitespaces)
        let sep = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard head.contains("|"), sep.contains("|"),
              sep.allSatisfy({ "|-: ".contains($0) }),
              sep.contains("-")
        else { return nil }
        let header = splitTableRow(head)
        let columnCount = header.count
        guard columnCount > 0 else { return nil }
        var rows: [[String]] = []
        var j = start + 2
        while j < lines.count {
            let row = lines[j].trimmingCharacters(in: .whitespaces)
            guard row.contains("|"), !row.isEmpty else { break }
            var cells = splitTableRow(row)
            // Normalise width to header length.
            if cells.count < columnCount {
                cells += Array(repeating: "", count: columnCount - cells.count)
            } else if cells.count > columnCount {
                cells = Array(cells.prefix(columnCount))
            }
            rows.append(cells)
            j += 1
        }
        return (header, rows, j - start)
    }

    private static func splitTableRow(_ raw: String) -> [String] {
        var s = raw
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Detect `# Heading` / `## Subheading` etc. (1–6 `#`s, then whitespace,
    /// then content). Returns `(level, text)` or nil.
    private static func matchHeading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level >= 1, idx < line.endIndex, line[idx].isWhitespace else { return nil }
        let body = line[idx...].drop(while: { $0.isWhitespace })
        guard !body.isEmpty else { return nil }
        return (level, String(body))
    }

    private struct FenceDelimiter {
        let marker: Character
        let length: Int
        let language: String?
    }

    private static func matchFence(_ line: String) -> FenceDelimiter? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            guard leadingSpaces <= 3 else { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let fenceText = line[index...]
        guard let marker = fenceText.first, marker == "`" || marker == "~" else { return nil }
        let length = fenceText.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let language = fenceText.dropFirst(length).trimmingCharacters(in: .whitespaces)
        return FenceDelimiter(marker: marker, length: length, language: language.isEmpty ? nil : language)
    }

    private static func closesFence(_ line: String, _ openingFence: FenceDelimiter) -> Bool {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            guard leadingSpaces <= 3 else { return false }
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == openingFence.marker else { return false }
        let markerCount = line[index...].prefix(while: { $0 == openingFence.marker }).count
        guard markerCount >= openingFence.length else { return false }
        let afterMarker = line.index(index, offsetBy: markerCount)
        return line[afterMarker...].allSatisfy(\.isWhitespace)
    }

    private static func matchTaskItem(_ line: String) -> TaskItem? {
        guard line.count >= 5 else { return nil }
        let marker = String(line.prefix(5))
        let isChecked: Bool
        switch marker {
        case "- [ ]": isChecked = false
        case "- [x]", "- [X]": isChecked = true
        default: return nil
        }

        let remainder = line.dropFirst(5)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        return TaskItem(
            isChecked: isChecked,
            text: String(remainder.drop(while: \.isWhitespace))
        )
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        let lines = text.components(separatedBy: "\n")

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if let fence = matchFence(line) {
                i += 1
                var body: [String] = []
                while i < lines.count, !closesFence(lines[i], fence) {
                    body.append(lines[i])
                    i += 1
                }
                let closesBeforeEnd = i < lines.count
                if closesBeforeEnd { i += 1 } // skip closing fence
                let codeBody = body.joined(separator: "\n")
                if closesBeforeEnd {
                    blocks.append(.code(language: fence.language, body: codeBody))
                } else {
                    blocks.append(.streamingCode(language: fence.language, body: codeBody))
                }
                continue
            }

            // Heading.
            if let (level, headingText) = matchHeading(trimmed) {
                blocks.append(.heading(level: level, text: headingText))
                i += 1
                continue
            }

            // Markdown table: a header row + separator (---|:--:|---) + body rows.
            if let (header, rows, consumed) = matchTable(from: lines, at: i) {
                blocks.append(.table(header: header, rows: rows))
                i += consumed
                continue
            }

            // Blockquote: collect contiguous `> ` prefixed lines.
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var s = lines[i].trimmingCharacters(in: .whitespaces)
                    s.removeFirst()
                    if s.first == " " { s.removeFirst() }
                    quoted.append(s)
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // Blank line — paragraph boundary.
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Task list: collect contiguous top-level GitHub-style items.
            if let task = matchTaskItem(line) {
                var items = [task]
                i += 1
                while i < lines.count, let task = matchTaskItem(lines[i]) {
                    items.append(task)
                    i += 1
                }
                blocks.append(.taskList(items))
                continue
            }

            // Paragraph: collect until blank or block-start.
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i].trimmingCharacters(in: .whitespaces)
                if next.isEmpty { break }
                if matchFence(lines[i]) != nil || next.hasPrefix(">") || matchHeading(next) != nil || matchTaskItem(lines[i]) != nil { break }
                para.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(para.joined(separator: "\n")))
        }
        return blocks
    }
}

private struct ACPMarkdownTaskCheckbox: NSViewRepresentable {
    let isChecked: Bool
    let accessibilityLabel: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.isEnabled = false
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.isEnabled = false
        button.state = isChecked ? .on : .off
        button.setAccessibilityLabel(accessibilityLabel)
    }
}

/// Fenced code block with optional language label and a copy button on
/// the right side of the header. Click flashes a checkmark + "Copied"
/// for ~1.5s, mirroring the SHA-copy affordance in the commit editor.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    let typography: ACPChatTypography
    var showsCopyButton: Bool = true
    var highlightsSyntax: Bool = true
    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                codeText
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .background(theme.color("bg-0").opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(typography.swiftUIFont(
                        size: typography.labelSize,
                        weight: .semibold,
                        traits: .boldFontMask
                    ))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.color("fg-faint"))
            } else {
                Color.clear.frame(height: 1)
            }
            Spacer(minLength: 0)
            if showsCopyButton {
                copyButton
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(theme.color("bg-2").opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5)
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: typography.labelSize, weight: copied ? .bold : .regular))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: typography.labelSize, weight: .medium))
            }
            .foregroundStyle(copied ? theme.color("add") : theme.color("fg-muted"))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.color("bg-3").opacity(copied ? 0.4 : 0.6))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(copied ? theme.color("add").opacity(0.5) : theme.color("line"), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Copy code")
    }

    @ViewBuilder
    private var codeText: some View {
        if highlightsSyntax {
            ACPSyntaxHighlightedText(
                text: code,
                explicitLanguage: language,
                fontFamily: typography.fontFamily,
                fontSize: typography.codeSize
            )
        } else {
            Text(verbatim: code)
                .font(Font(CenterTypography.resolveCodeFont(family: typography.fontFamily, size: typography.codeSize)))
                .foregroundStyle(theme.color("fg"))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeIn(duration: 0.2)) { copied = false }
        }
    }
}
