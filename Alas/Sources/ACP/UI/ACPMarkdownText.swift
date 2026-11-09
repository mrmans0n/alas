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
    /// Overrides the transcript spacing for surfaces that keep their own density.
    var spacing: Spacing? = nil
    @Environment(\.theme) private var theme
    @Environment(\.acpMarkdownProseMaxWidth) private var proseMaxWidth
    @Environment(\.designScale) private var scale
    @State private var tableViewportWidth: CGFloat = 0

    struct Spacing {
        let block: CGFloat
        let line: CGFloat
        /// Room kept for wrapped code lines to hang into; none unless asked for.
        var codeHangingIndent: CGFloat = 0
    }

    private var lineSpacing: CGFloat { spacing?.line ?? scale.transcriptLineSpacing }
    private var codeHangingIndent: CGFloat { spacing?.codeHangingIndent ?? scale.codeHangingIndent }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing?.block ?? scale.transcriptBlockSpacing) {
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
            ACPMarkdownInlineText(
                source: text,
                typography: typography,
                role: .heading(level: level),
                theme: theme,
                memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
            )
                .padding(.top, level == 1 ? scale.space[1] : scale.space[0])
                .frame(maxWidth: proseMaxWidth ?? .infinity, alignment: .leading)
        case .paragraph(let text):
            ACPMarkdownInlineText(
                source: text,
                typography: typography,
                role: .body,
                theme: theme,
                memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
            )
                .lineSpacing(lineSpacing)
                .frame(maxWidth: proseMaxWidth ?? .infinity, alignment: .leading)
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
                            .padding(.top, 1) // design-literal: centers a 16pt checkbox on the first text line
                        ACPMarkdownInlineText(
                            source: item.text,
                            typography: typography,
                            role: .body,
                            theme: theme,
                            memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
                        )
                            .lineSpacing(lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: proseMaxWidth ?? .infinity, alignment: .leading)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(theme.color("accent").opacity(0.55))
                    .frame(width: 2)
                ACPMarkdownInlineText(
                    source: text,
                    typography: typography,
                    role: .quote,
                    theme: theme,
                    memoizesInlineMarkdown: renderBlock.memoizesInlineMarkdown
                )
                    .lineSpacing(lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: proseMaxWidth ?? .infinity, alignment: .leading)
        case .code(let lang, let body):
            CodeBlockView(
                language: lang,
                code: body,
                typography: typography,
                showsCopyButton: showsCodeBlockCopyButton,
                highlightsSyntax: true,
                hangingIndent: codeHangingIndent
            )
        case .streamingCode(let lang, let body):
            CodeBlockView(
                language: lang,
                code: body,
                typography: typography,
                showsCopyButton: showsCodeBlockCopyButton,
                highlightsSyntax: false,
                hangingIndent: codeHangingIndent
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
        let columns = ACPTranscriptMarkdownLayout.tableColumns(header: header, rows: rows, typography: typography) { row, _, source in
            ACPMarkdownInlineRenderer.makeAttributedString(
                source: source, theme: theme, typography: typography, role: .tableCell(isHeader: row == 0)
            )
        }
        let widths = ACPTranscriptMarkdownLayout.tableColumnWidths(columns, available: tableViewportWidth)
        return ACPHorizontalScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(
                    cells: header,
                    isHeader: true,
                    columns: columns,
                    widths: widths,
                    memoizesInlineMarkdown: memoizesInlineMarkdown
                )
                Rectangle().fill(theme.color("line")).frame(height: 0.5)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    tableRow(
                        cells: r,
                        isHeader: false,
                        columns: columns,
                        widths: widths,
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
        .background(theme.color("bg-0").opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line-soft"), lineWidth: ACPTranscriptMarkdownLayout.tableDividerWidth)
        }
    }

    private func tableRow(
        cells: [String],
        isHeader: Bool,
        columns: [ACPTranscriptMarkdownLayout.TableColumn],
        widths: [CGFloat],
        memoizesInlineMarkdown: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { i in
                let value = i < cells.count ? cells[i] : ""
                ACPMarkdownInlineText(
                    source: value,
                    typography: typography,
                    role: .tableCell(isHeader: isHeader),
                    theme: theme,
                    memoizesInlineMarkdown: memoizesInlineMarkdown
                )
                    .multilineTextAlignment(columns[i].isNumeric ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: columns[i].isNumeric ? .trailing : .leading)
                    .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
                    .frame(width: widths[i], alignment: .leading)
                if i < columns.count - 1 {
                    Rectangle().fill(theme.color("line-soft")).frame(width: 0.5)
                }
            }
        }
        .background(isHeader ? theme.color("bg-2").opacity(0.5) : Color.clear)
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
struct CodeBlockView: View {
    let language: String?
    let code: String
    let typography: ACPChatTypography
    var showsCopyButton: Bool = true
    var highlightsSyntax: Bool = true
    /// How far `ACPTranscriptMarkdownLayout` hangs a wrapped line; the text
    /// breaks that much short of the width so both break alike.
    var hangingIndent: CGFloat = 0
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Wraps rather than scrolling sideways: a horizontal SwiftUI
            // ScrollView here swallowed vertical trackpad gestures, freezing
            // the transcript while the pointer hovered a code block.
            codeText
                .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        }
        .background(theme.color("bg-0").opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line-soft"), lineWidth: ACPTranscriptMarkdownLayout.tableDividerWidth)
        }
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
                    .foregroundStyle(theme.color("fg-dim"))
            } else {
                Color.clear.frame(height: 1)
            }
            Spacer(minLength: 0)
            if showsCopyButton {
                copyButton
            }
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[1])
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
                    .font(Self.labelFont(typography, weight: copied ? .bold : .regular))
                Text(copied ? "Copied" : "Copy")
                    .font(Self.labelFont(typography, weight: .medium))
            }
            .frame(height: ACPTranscriptMarkdownLayout.copyButtonContentHeight(typography))
            .foregroundStyle(copied ? theme.color("add") : theme.color("fg-muted"))
            .padding(.horizontal, scale.space[1]).padding(.vertical, scale.space[0])
            .background(theme.color("bg-3").opacity(copied ? 0.4 : 0.6))
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
        }
        .buttonStyle(.plain)
        .help("Copy code")
    }

    /// Sized from the chat font rather than the scale, as the rest of the block is.
    private static func labelFont(_ typography: ACPChatTypography, weight: Font.Weight) -> Font {
        .system(size: typography.labelSize, weight: weight)
    }

    /// Breaks where the native row does, which hangs wrapped lines under their
    /// first line. The continuations are not moved in here: `Text` has no
    /// hanging indent, and drawing them shifted would leave text selection and
    /// hit-testing on the unshifted glyphs.
    @ViewBuilder
    private var codeText: some View {
        Group {
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
        .padding(.trailing, hangingIndent)
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
    /// Session root for local or SSH image paths. Peer transcripts install
    /// their own reader instead of reading this machine's filesystem.
    @Entry var acpTrustedImageRoot: URL? = nil
    @Entry var acpTranscriptImageReader: ACPTranscriptImageReader? = nil
}

/// A peer reader captures its host/worktree so a later selection cannot redirect a read.
struct ACPTranscriptImageReader: Sendable {
    let id: String
    let read: @MainActor @Sendable (String) async -> Data?
}

/// `![alt](source)` on its own line, clickable and full width,
/// never upscaled, capped at the transcript diagram height. Sources resolve
/// through the tool-call asset reader, including SSH and peer sessions,
/// with relative paths resolved against the owning worktree.
private struct ACPMarkdownImageBlockView: View {
    let alt: String
    let source: String
    @Environment(\.acpTrustedImageRoot) private var trustedRoot
    @Environment(\.acpTranscriptImageReader) private var imageReader
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        let asset = ACPMessage.ToolCallAsset.image(uri: source, name: alt.isEmpty ? nil : alt)
        let trustedRoot = trustedRoot
        if imageReader != nil || trustedRoot != nil || asset.canLoadImage(trustedRoot: trustedRoot) {
            ACPCachedThumbnail(
                cacheKey: asset.transcriptImageCacheKey(trustedRoot: trustedRoot, reader: imageReader),
                loadImage: { await asset.loadedTranscriptImage(trustedRoot: trustedRoot, reader: imageReader) }
            ) { image in
                Button {
                    ACPImagePreview.shared.show(image, title: asset.displayTitle)
                } label: {
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open image")
                .frame(maxWidth: .infinity)
            } placeholder: {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            } failure: {
                unavailable(asset)
            }
        } else {
            unavailable(asset)
        }
    }

    private func unavailable(_ asset: ACPMessage.ToolCallAsset) -> some View {
        Label(asset.displayText, systemImage: "photo")
            .font(scale.metaFont)
            .foregroundStyle(theme.color("fg-faint"))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(source)
    }
}
