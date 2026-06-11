import AppKit
import SwiftUI

struct DiffPaneTextDocumentView: NSViewRepresentable {
    let group: DiffDisplayGroup
    let expandedCollapsedRowIDs: Set<String>
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme

    func makeNSView(context: Context) -> DiffPaneTextDocumentScrollView {
        DiffPaneTextDocumentScrollView()
    }

    func updateNSView(_ nsView: DiffPaneTextDocumentScrollView, context: Context) {
        nsView.update(
            group: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            theme: theme
        )
    }
}

final class DiffPaneTextDocumentScrollView: NSScrollView {
    private static let unwrappedTextContainerWidth: CGFloat = 1_000_000

    private let textView: NSTextView
    private var latestConfiguration: Configuration?
    private var latestViewportWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredTextHeight())
    }

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = textView

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 12, height: 6)
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func update(
        group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>,
        layoutMode: DiffLayoutMode,
        wrapLines: Bool,
        showWhitespace: Bool,
        fileExtension: String,
        font: NSFont,
        theme: Theme
    ) {
        latestConfiguration = Configuration(
            group: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            font: font,
            theme: theme
        )
        applyLatestConfiguration()
    }

    override func layout() {
        super.layout()
        if abs(contentView.bounds.width - latestViewportWidth) > 1 {
            applyLatestConfiguration()
        } else {
            updateTextLayout()
        }
    }

    private func applyLatestConfiguration() {
        guard let config = latestConfiguration else { return }
        latestViewportWidth = contentView.bounds.width
        hasHorizontalScroller = config.layoutMode == .stacked && !config.wrapLines

        let document = DiffPaneTextDocumentBuilder.build(
            group: config.group,
            expandedCollapsedRowIDs: config.expandedCollapsedRowIDs,
            layoutMode: config.layoutMode,
            fileExtension: config.fileExtension,
            font: config.font,
            showWhitespace: config.showWhitespace,
            theme: config.theme,
            splitColumnCharacterWidth: splitColumnCharacterWidth(font: config.font)
        )
        textView.textStorage?.setAttributedString(document.attributedString)
        textView.insertionPointColor = NSColor(config.theme.color("fg"))
        updateTextLayout()
        invalidateIntrinsicContentSize()
    }

    private func updateTextLayout() {
        guard let config = latestConfiguration else { return }
        let wraps = config.wrapLines || config.layoutMode == .split
        let viewportWidth = max(contentView.bounds.width, 1)

        textView.isHorizontallyResizable = !wraps
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: wraps ? viewportWidth : Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: wraps ? viewportWidth - textView.textContainerInset.width * 2 : Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: wraps ? viewportWidth : max(viewportWidth, measuredTextWidth()),
            height: measuredTextHeight()
        )
    }

    private func measuredTextHeight() -> CGFloat {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return 0
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return ceil(used.height + textView.textContainerInset.height * 2)
    }

    private func measuredTextWidth() -> CGFloat {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return 0
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return ceil(used.width + textView.textContainerInset.width * 2)
    }

    private func splitColumnCharacterWidth(font: NSFont) -> Int {
        let viewportWidth = max(latestViewportWidth, 320)
        let characterWidth = max(("0" as NSString).size(withAttributes: [.font: font]).width, 1)
        let halfPaneWidth = max((viewportWidth - 28) / 2, 120)
        let prefixWidth: CGFloat = 8 * characterWidth
        return max(Int((halfPaneWidth - prefixWidth) / characterWidth), 12)
    }

    private struct Configuration {
        let group: DiffDisplayGroup
        let expandedCollapsedRowIDs: Set<String>
        let layoutMode: DiffLayoutMode
        let wrapLines: Bool
        let showWhitespace: Bool
        let fileExtension: String
        let font: NSFont
        let theme: Theme
    }
}
