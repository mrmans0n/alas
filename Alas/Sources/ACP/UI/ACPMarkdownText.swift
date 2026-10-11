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
    var noninteractiveTapAction: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var tableViewportWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(currentRenderBlocks().enumerated()), id: \.offset) { _, renderBlock in
                view(for: renderBlock)
                    .modifier(ACPMarkdownNoninteractiveTapModifier(
                        action: renderBlock.block.allowsNoninteractiveTapAction ? noninteractiveTapAction : nil
                    ))
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
                            accessibilityLabel: ACPMarkdownInlineRenderer.plainText(
                                item.text,
                                memoizeInlineMarkdown: renderBlock.memoizesInlineMarkdown
                            )
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
        case .mermaid(let source):
            MermaidDiagramBlockView(source: source, profile: .transcript)
        case .image(let alt, let source):
            ACPMarkdownImageBlockView(alt: alt, source: source)
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
        return ACPHorizontalScrollView {
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

    typealias Block = ACPMarkdownParser.Block
    typealias TaskItem = ACPMarkdownParser.TaskItem

    private struct RenderBlock {
        let block: Block
        let memoizesInlineMarkdown: Bool
    }

    private struct ACPMarkdownNoninteractiveTapModifier: ViewModifier {
        let action: (() -> Void)?

        @ViewBuilder
        func body(content: Content) -> some View {
            if let action {
                content
                    .contentShape(Rectangle())
                    .onTapGesture(perform: action)
            } else {
                content
            }
        }
    }

    static func parse(_ text: String) -> [Block] {
        ACPMarkdownParser.parse(text)
    }
}

private extension ACPMarkdownText.Block {
    var allowsNoninteractiveTapAction: Bool {
        switch self {
        case .mermaid, .image:
            false
        case .heading, .paragraph, .taskList, .quote, .code, .streamingCode, .table:
            true
        }
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
            // Wraps rather than scrolling sideways: a horizontal SwiftUI
            // ScrollView here swallowed vertical trackpad gestures, freezing
            // the transcript while the pointer hovered a code block.
            codeText
                .padding(.horizontal, 10).padding(.vertical, 8)
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

extension EnvironmentValues {
    /// Worktree an agent's markdown images may load from. Without one only
    /// inline `data:` images render, the same rule tool-call assets follow.
    @Entry var acpTrustedImageRoot: URL? = nil
}

/// `![alt](source)` on its own line, drawn like a Mermaid block: full width,
/// never upscaled, capped at the transcript diagram height. Sources resolve
/// through the tool-call asset rules, so only files inside the worktree and
/// `data:` URIs load; anything else stays a labelled row.
private struct ACPMarkdownImageBlockView: View {
    let alt: String
    let source: String
    @Environment(\.acpTrustedImageRoot) private var trustedRoot
    @Environment(\.theme) private var theme

    var body: some View {
        let asset = ACPMessage.ToolCallAsset.image(uri: source, name: alt.isEmpty ? nil : alt)
        let trustedRoot = trustedRoot
        if asset.canLoadImage(trustedRoot: trustedRoot) {
            ACPCachedThumbnail(
                cacheKey: asset.thumbnailCacheKey(trustedRoot: trustedRoot),
                loadImage: { asset.loadedImage(trustedRoot: trustedRoot) }
            ) { image in
                chrome(asset) {
                    MermaidFittedDiagramLayout(
                        intrinsicSize: image.size,
                        maxHeight: MermaidPresentationProfile.transcript.maxEmbeddedHeight
                    ) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .accessibilityLabel(asset.displayTitle)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                }
            } placeholder: {
                chrome(asset) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                }
            } failure: {
                unavailable(asset)
            }
        } else {
            unavailable(asset)
        }
    }

    private func chrome(
        _ asset: ACPMessage.ToolCallAsset,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(asset.displayTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let url = ACPMessage.ToolCallAsset.trustedLocalURL(from: source, trustedRoot: trustedRoot) {
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(theme.color("bg-2").opacity(0.6))
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.color("line-soft")).frame(height: 0.5)
            }
            content()
        }
        .background(theme.color("bg-0").opacity(0.6))
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5)
        }
    }

    private func unavailable(_ asset: ACPMessage.ToolCallAsset) -> some View {
        Label(asset.displayText, systemImage: "photo")
            .font(.system(size: 11.5))
            .foregroundStyle(theme.color("fg-faint"))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(source)
    }
}
