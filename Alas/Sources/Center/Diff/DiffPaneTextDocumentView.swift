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

    func makeNSView(context: Context) -> DiffPaneTextDocumentContainerView {
        DiffPaneTextDocumentContainerView()
    }

    func updateNSView(_ nsView: DiffPaneTextDocumentContainerView, context: Context) {
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

final class DiffPaneTextDocumentContainerView: NSView {
    private static let unwrappedTextContainerWidth: CGFloat = 1_000_000

    private let oldGutterView = DiffPaneTextDocumentContainerView.makeTextView(selectable: false)
    private let oldCodeView = DiffPaneTextDocumentContainerView.makeTextView(selectable: true)
    private let newGutterView = DiffPaneTextDocumentContainerView.makeTextView(selectable: false)
    private let newCodeView = DiffPaneTextDocumentContainerView.makeTextView(selectable: true)
    private let stackedGutterView = DiffPaneTextDocumentContainerView.makeTextView(selectable: false)
    private let stackedCodeView = DiffPaneTextDocumentContainerView.makeTextView(selectable: true)
    private let dividerView = NSView()

    private var layoutMode: DiffLayoutMode = .split
    private var wrapLines = false
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var splitLineCount = 0
    private var stackedLineCount = 0
    private var measuredHeight: CGFloat = 0
    private var measuredStackedWidth: CGFloat = 0

    private let horizontalPadding: CGFloat = 12
    private let gutterWidth: CGFloat = 48
    private let columnGap: CGFloat = 10
    private let codeGap: CGFloat = 8
    private let dividerWidth: CGFloat = 1
    private let verticalInset = CenterTypography.rowVerticalPadding + 5

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: layoutMode == .stacked && !wrapLines ? intrinsicStackedWidth : NSView.noIntrinsicMetric,
            height: intrinsicHeight
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(oldGutterView)
        addSubview(oldCodeView)
        addSubview(newGutterView)
        addSubview(newCodeView)
        addSubview(stackedGutterView)
        addSubview(stackedCodeView)
        addSubview(dividerView)
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
        self.layoutMode = layoutMode
        self.wrapLines = wrapLines
        self.font = font
        layer?.backgroundColor = NSColor(theme.color("bg-1")).cgColor
        dividerView.layer?.backgroundColor = NSColor(theme.color("line")).cgColor
        dividerView.wantsLayer = true

        switch layoutMode {
        case .split:
            let result = DiffPaneTextDocumentBuilder.buildSplit(
                group: group,
                expandedCollapsedRowIDs: expandedCollapsedRowIDs,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            )
            oldCodeView.textStorage?.setAttributedString(result.oldCode.attributedString)
            oldGutterView.textStorage?.setAttributedString(result.oldGutter)
            newCodeView.textStorage?.setAttributedString(result.newCode.attributedString)
            newGutterView.textStorage?.setAttributedString(result.newGutter)
            splitLineCount = max(result.oldCode.lines.count, result.newCode.lines.count)
            stackedLineCount = 0
        case .stacked:
            let result = DiffPaneTextDocumentBuilder.buildStacked(
                group: group,
                expandedCollapsedRowIDs: expandedCollapsedRowIDs,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            )
            stackedCodeView.textStorage?.setAttributedString(result.code.attributedString)
            stackedGutterView.textStorage?.setAttributedString(result.gutter)
            stackedLineCount = result.code.lines.count
            splitLineCount = 0
        }

        oldCodeView.insertionPointColor = NSColor(theme.color("fg"))
        newCodeView.insertionPointColor = NSColor(theme.color("fg"))
        stackedCodeView.insertionPointColor = NSColor(theme.color("fg"))
        updateVisibility()
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        updateVisibility()
        switch layoutMode {
        case .split:
            layoutSplit()
        case .stacked:
            layoutStacked()
        }
        invalidateIntrinsicContentSize()
    }

    private func layoutSplit() {
        let availableWidth = max(bounds.width - horizontalPadding * 2 - columnGap - dividerWidth, 240)
        let columnWidth = floor(availableWidth / 2)
        let codeWidth = max(columnWidth - gutterWidth - codeGap, 40)
        let oldX = horizontalPadding
        let newX = horizontalPadding + columnWidth + columnGap + dividerWidth
        let preferredHeight = lineCountHeight(splitLineCount)

        configureTextView(oldGutterView, wraps: false, width: gutterWidth)
        configureTextView(oldCodeView, wraps: false, width: codeWidth)
        configureTextView(newGutterView, wraps: false, width: gutterWidth)
        configureTextView(newCodeView, wraps: false, width: codeWidth)

        let contentHeight = max(
            preferredHeight,
            measuredTextHeight(oldCodeView),
            measuredTextHeight(newCodeView),
            measuredTextHeight(oldGutterView),
            measuredTextHeight(newGutterView)
        )

        oldGutterView.frame = NSRect(x: oldX, y: verticalInset, width: gutterWidth, height: contentHeight)
        oldCodeView.frame = NSRect(x: oldX + gutterWidth + codeGap, y: verticalInset, width: codeWidth, height: contentHeight)
        dividerView.frame = NSRect(
            x: horizontalPadding + columnWidth + floor(columnGap / 2),
            y: 0,
            width: dividerWidth,
            height: contentHeight + verticalInset * 2
        )
        newGutterView.frame = NSRect(x: newX, y: verticalInset, width: gutterWidth, height: contentHeight)
        newCodeView.frame = NSRect(x: newX + gutterWidth + codeGap, y: verticalInset, width: codeWidth, height: contentHeight)
        measuredHeight = contentHeight + verticalInset * 2
        measuredStackedWidth = 0
    }

    private func layoutStacked() {
        let codeX = horizontalPadding + gutterWidth + codeGap
        let codeWidth = max(bounds.width - codeX - horizontalPadding, 80)
        let wraps = wrapLines

        configureTextView(stackedGutterView, wraps: false, width: gutterWidth)
        configureTextView(stackedCodeView, wraps: wraps, width: codeWidth)

        let contentHeight = max(
            lineCountHeight(stackedLineCount),
            measuredTextHeight(stackedCodeView),
            measuredTextHeight(stackedGutterView)
        )
        let measuredCodeWidth = measuredTextWidth(stackedCodeView)

        stackedGutterView.frame = NSRect(x: horizontalPadding, y: verticalInset, width: gutterWidth, height: contentHeight)
        stackedCodeView.frame = NSRect(
            x: codeX,
            y: verticalInset,
            width: wraps ? codeWidth : max(codeWidth, measuredCodeWidth),
            height: contentHeight
        )
        measuredHeight = contentHeight + verticalInset * 2
        measuredStackedWidth = codeX + (wraps ? codeWidth : measuredCodeWidth) + horizontalPadding
    }

    private func configureTextView(_ textView: NSTextView, wraps: Bool, width: CGFloat) {
        textView.font = font
        textView.isHorizontallyResizable = !wraps
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: wraps ? width : Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: wraps ? width : Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func updateVisibility() {
        let split = layoutMode == .split
        oldGutterView.isHidden = !split
        oldCodeView.isHidden = !split
        newGutterView.isHidden = !split
        newCodeView.isHidden = !split
        dividerView.isHidden = !split
        stackedGutterView.isHidden = split
        stackedCodeView.isHidden = split
    }

    private var intrinsicHeight: CGFloat {
        max(measuredHeight, lineCountHeight(max(splitLineCount, stackedLineCount)) + verticalInset * 2)
    }

    private var intrinsicStackedWidth: CGFloat {
        max(measuredStackedWidth, bounds.width)
    }

    private func lineCountHeight(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * NSLayoutManager().defaultLineHeight(for: font)
    }

    private func measuredTextHeight(_ textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return 0
        }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    private func measuredTextWidth(_ textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return 0
        }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).width)
    }

    private static func makeTextView(selectable: Bool) -> NSTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = selectable
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        return textView
    }
}
