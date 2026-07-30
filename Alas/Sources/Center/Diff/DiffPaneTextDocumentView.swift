import AppKit
import SwiftUI

private let diffContextExpansionChunkSize = 10

typealias DiffContextExpansionHandler = (DiffContextExpansionKey, DiffContextExpansionMode, DiffContextExpansionEdge?) -> Void

struct DiffReviewLineAnchor: Equatable, Hashable, Sendable {
    struct SelectedLine: Equatable, Hashable, Sendable {
        let side: DiffReviewInlineFeedbackSide
        let line: Int
        let isChange: Bool
    }

    let path: String
    let side: DiffReviewInlineFeedbackSide
    let line: Int
    let endLine: Int?
    let rowIndex: Int
    let endRowIndex: Int
    let selectedLines: [SelectedLine]
    let selectedText: String

    init(
        path: String,
        side: DiffReviewInlineFeedbackSide,
        line: Int,
        endLine: Int? = nil,
        rowIndex: Int,
        endRowIndex: Int? = nil,
        selectedLines: [SelectedLine]? = nil,
        selectedText: String
    ) {
        self.path = path
        self.side = side
        self.line = line
        self.endLine = endLine
        self.rowIndex = rowIndex
        self.endRowIndex = endRowIndex ?? rowIndex
        self.selectedLines = selectedLines ?? [
            SelectedLine(side: side, line: line, isChange: side != .unknown),
        ]
        self.selectedText = selectedText
    }
}

struct DiffReviewCommentHighlight: Equatable, Hashable, Sendable {
    let path: String
    let side: DiffReviewInlineFeedbackSide
    let lineRange: ClosedRange<Int>

    init(path: String, side: DiffReviewInlineFeedbackSide, lineRange: ClosedRange<Int>) {
        self.path = path
        self.side = side
        self.lineRange = lineRange
    }

    init(path: String, side: DiffReviewInlineFeedbackSide, line: Int, endLine: Int? = nil) {
        self.init(path: path, side: side, lineRange: min(line, endLine ?? line)...max(line, endLine ?? line))
    }

    func highlightedRowRange(in lines: [DiffPaneTextDocumentBuilder.LineMetadata]) -> ClosedRange<Int>? {
        let matchingRows = lines.indices.filter { index in
            matchesVisibleSourceLine(lines[index].sourceLine)
        }
        guard let first = matchingRows.first, let last = matchingRows.last else { return nil }
        return first...last
    }

    func matchesVisibleSourceLine(_ sourceLine: DiffDisplayLine?) -> Bool {
        guard let sourceLine,
              sourceLine.anchor.filePath == path,
              let lineNumber = sourceLine.highlightLineNumber(for: side),
              lineRange.contains(lineNumber)
        else {
            return false
        }
        return side.matches(sourceLine.anchor.side)
    }
}

extension DiffReviewInlineFeedbackSide {
    func matches(_ lineSide: DiffLineSide) -> Bool {
        switch (self, lineSide) {
        case (.old, .old), (.new, .new), (.unknown, _), (.old, .paired), (.new, .paired):
            return true
        default:
            return false
        }
    }
}

private extension DiffDisplayLine {
    func highlightLineNumber(for side: DiffReviewInlineFeedbackSide) -> Int? {
        switch side {
        case .old:
            return anchor.oldLine
        case .new:
            return anchor.newLine
        case .unknown:
            return lineNumber ?? anchor.newLine ?? anchor.oldLine
        }
    }
}

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
    let lspContext: DiffPaneLSPContext?
    let activeCommentHighlight: DiffReviewCommentHighlight?
    var allowsReviewLineSelection: Bool = true
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    var onContextExpansion: DiffContextExpansionHandler = { _, _, _ in }

    init(
        group: DiffDisplayGroup,
        expandedCollapsedRowIDs: Set<String>,
        layoutMode: DiffLayoutMode,
        wrapLines: Bool,
        showWhitespace: Bool,
        fileExtension: String,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        theme: Theme,
        lspContext: DiffPaneLSPContext?,
        activeCommentHighlight: DiffReviewCommentHighlight? = nil,
        allowsReviewLineSelection: Bool = true,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in }
    ) {
        self.group = group
        self.expandedCollapsedRowIDs = expandedCollapsedRowIDs
        self.layoutMode = layoutMode
        self.wrapLines = wrapLines
        self.showWhitespace = showWhitespace
        self.fileExtension = fileExtension
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self.theme = theme
        self.lspContext = lspContext
        self.activeCommentHighlight = activeCommentHighlight
        self.allowsReviewLineSelection = allowsReviewLineSelection
        self.onReviewLineSelected = onReviewLineSelected
        self.onContextExpansion = onContextExpansion
    }

    func makeNSView(context: Context) -> DiffPaneTextDocumentContainerView {
        DiffPaneTextDocumentContainerView()
    }

    func updateNSView(_ nsView: DiffPaneTextDocumentContainerView, context: Context) {
        let visibleRows = DiffPaneRowProjection.visibleRows(
            in: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs
        )
        nsView.update(
            group: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            theme: theme,
            lspContext: lspContext,
            activeCommentHighlight: activeCommentHighlight,
            allowsReviewLineSelection: allowsReviewLineSelection,
            onReviewLineSelected: { anchor in
                onReviewLineSelected(ReviewDraftCommentRowSegmentation.sourceIndexedAnchor(anchor, in: visibleRows))
            },
            onContextExpansion: onContextExpansion
        )
    }
}

struct DiffPaneSegmentView: NSViewRepresentable {
    let rowsSnapshot: DiffDisplayRowsSnapshot
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme
    let lspContext: DiffPaneLSPContext?
    var activeCommentHighlight: DiffReviewCommentHighlight? = nil
    var allowsReviewLineSelection: Bool = true
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    let onContextExpansion: DiffContextExpansionHandler

    init(
        rows: [DiffDisplayRow],
        rowsSignature: DiffDisplayRowsSignature? = nil,
        layoutMode: DiffLayoutMode,
        wrapLines: Bool,
        showWhitespace: Bool,
        fileExtension: String,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        theme: Theme,
        lspContext: DiffPaneLSPContext?,
        activeCommentHighlight: DiffReviewCommentHighlight? = nil,
        allowsReviewLineSelection: Bool = true,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
        onContextExpansion: @escaping DiffContextExpansionHandler
    ) {
        self.rowsSnapshot = DiffDisplayRowsSnapshot(rows: rows, signature: rowsSignature)
        self.layoutMode = layoutMode
        self.wrapLines = wrapLines
        self.showWhitespace = showWhitespace
        self.fileExtension = fileExtension
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self.theme = theme
        self.lspContext = lspContext
        self.activeCommentHighlight = activeCommentHighlight
        self.allowsReviewLineSelection = allowsReviewLineSelection
        self.onReviewLineSelected = onReviewLineSelected
        self.onContextExpansion = onContextExpansion
    }

    func makeNSView(context: Context) -> DiffPaneTextDocumentContainerView {
        DiffPaneTextDocumentContainerView()
    }

    func updateNSView(_ nsView: DiffPaneTextDocumentContainerView, context: Context) {
        nsView.update(
            rows: rowsSnapshot.rows,
            rowsSignature: rowsSnapshot.signature,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            theme: theme,
            lspContext: lspContext,
            activeCommentHighlight: activeCommentHighlight,
            allowsReviewLineSelection: allowsReviewLineSelection,
            onReviewLineSelected: { anchor in
                onReviewLineSelected(ReviewDraftCommentRowSegmentation.sourceIndexedAnchor(anchor, in: rowsSnapshot.rows))
            },
            onContextExpansion: onContextExpansion
        )
    }
}

final class DiffPaneTextDocumentContainerView: NSView {
    private let oldPane = DiffPaneTextScrollView()
    private let newPane = DiffPaneTextScrollView()
    private let stackedPane = DiffPaneTextScrollView()
    private let dividerView = NSView()

    private var layoutMode: DiffLayoutMode = .split
    private var measuredHeight: CGFloat = 0
    private var lastUpdateSignature: UpdateSignature?
    private var lastRowsUpdateSignature: RowsUpdateSignature?
    private var pendingIntrinsicContentSizeInvalidation = false

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    #if DEBUG
    func invokeExpansionForTesting(row: Int, side: DiffLineSide, optionKey: Bool = false) {
        let pane = switch side {
        case .old: oldPane
        case .new: newPane
        case .paired: stackedPane
        }
        (pane.verticalRulerView as? DiffPaneLineNumberRulerView)?
            .invokeExpansionForTesting(row: row, optionKey: optionKey)
    }
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(oldPane)
        addSubview(newPane)
        addSubview(stackedPane)
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
        theme: Theme,
        lspContext: DiffPaneLSPContext?,
        activeCommentHighlight: DiffReviewCommentHighlight? = nil,
        allowsReviewLineSelection: Bool = true,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in }
    ) {
        oldPane.allowsReviewLineSelection = allowsReviewLineSelection
        newPane.allowsReviewLineSelection = allowsReviewLineSelection
        stackedPane.allowsReviewLineSelection = allowsReviewLineSelection
        oldPane.onReviewLineSelected = onReviewLineSelected
        newPane.onReviewLineSelected = onReviewLineSelected
        stackedPane.onReviewLineSelected = onReviewLineSelected
        oldPane.onContextExpansion = onContextExpansion
        newPane.onContextExpansion = onContextExpansion
        stackedPane.onContextExpansion = onContextExpansion
        if oldPane.activeCommentHighlight != activeCommentHighlight {
            oldPane.activeCommentHighlight = activeCommentHighlight
            newPane.activeCommentHighlight = activeCommentHighlight
            stackedPane.activeCommentHighlight = activeCommentHighlight
        }

        let signature = UpdateSignature(
            groupID: group.id,
            groupContentHash: group.contentHash,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            fontName: font.fontName,
            fontSize: font.pointSize,
            theme: theme,
            lspContext: lspContext.map(UpdateSignature.LSPContextSignature.init)
        )
        guard signature != lastUpdateSignature else { return }
        lastUpdateSignature = signature

        self.layoutMode = layoutMode
        layer?.backgroundColor = NSColor(theme.color("bg-1")).cgColor
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor(theme.color("line")).cgColor

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
            oldPane.update(
                document: result.oldCode,
                lineLabels: lineLabels(from: result.oldGutter),
                wraps: wrapLines,
                font: font,
                theme: theme,
                lspContext: nil,
                allowedLSPSide: .new,
                onContextExpansion: onContextExpansion
            )
            newPane.update(
                document: result.newCode,
                lineLabels: lineLabels(from: result.newGutter),
                wraps: wrapLines,
                font: font,
                theme: theme,
                lspContext: lspContext,
                allowedLSPSide: .new,
                onContextExpansion: onContextExpansion
            )
            stackedPane.clearLSPContext()
            measuredHeight = max(oldPane.documentHeight, newPane.documentHeight)
        case .stacked:
            let result = DiffPaneTextDocumentBuilder.buildStacked(
                group: group,
                expandedCollapsedRowIDs: expandedCollapsedRowIDs,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            )
            stackedPane.update(
                document: result.code,
                lineLabels: lineLabels(from: result.gutter),
                wraps: wrapLines,
                font: font,
                theme: theme,
                lspContext: lspContext,
                allowedLSPSide: .new,
                onContextExpansion: onContextExpansion
            )
            oldPane.clearLSPContext()
            newPane.clearLSPContext()
            measuredHeight = stackedPane.documentHeight
        }

        updateVisibility()
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        updateVisibility()
        let previousMeasuredHeight = measuredHeight
        switch layoutMode {
        case .split:
            layoutSplit()
        case .stacked:
            layoutStacked()
        }
        if abs(measuredHeight - previousMeasuredHeight) > 0.5 {
            invalidateIntrinsicContentSizeAfterLayout()
        }
    }

    private func invalidateIntrinsicContentSizeAfterLayout() {
        guard !pendingIntrinsicContentSizeInvalidation else { return }
        pendingIntrinsicContentSizeInvalidation = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingIntrinsicContentSizeInvalidation = false
            invalidateIntrinsicContentSize()
        }
    }

    private func layoutSplit() {
        let splitFrames = DiffPaneSplitGeometry.frames(containerWidth: bounds.width)
        let height = max(bounds.height, measuredHeight)
        oldPane.frame = NSRect(
            x: splitFrames.oldPane.minX,
            y: 0,
            width: splitFrames.oldPane.width,
            height: height
        )
        dividerView.frame = NSRect(
            x: splitFrames.divider.minX,
            y: 0,
            width: splitFrames.divider.width,
            height: height
        )
        newPane.frame = NSRect(
            x: splitFrames.newPane.minX,
            y: 0,
            width: splitFrames.newPane.width,
            height: height
        )

        oldPane.layoutSubtreeIfNeeded()
        newPane.layoutSubtreeIfNeeded()
        synchronizeSplitRowHeights()
        measuredHeight = max(oldPane.documentHeight, newPane.documentHeight)
        oldPane.frame.size.height = measuredHeight
        newPane.frame.size.height = measuredHeight
        dividerView.frame.size.height = measuredHeight
    }

    private func synchronizeSplitRowHeights() {
        let oldRows = oldPane.diffRowRects()
        let newRows = newPane.diffRowRects()
        let count = min(oldRows.count, newRows.count)
        guard count > 0 else { return }

        let rowHeights = (0..<count).map { index in
            max(oldRows[index].height, newRows[index].height)
        }
        oldPane.synchronizeRowHeights(rowHeights)
        newPane.synchronizeRowHeights(rowHeights)
        oldPane.layoutSubtreeIfNeeded()
        newPane.layoutSubtreeIfNeeded()
    }

    private func layoutStacked() {
        stackedPane.frame = NSRect(x: 0, y: 0, width: max(bounds.width, 1), height: max(bounds.height, measuredHeight))
        stackedPane.layoutSubtreeIfNeeded()
        measuredHeight = stackedPane.documentHeight
        stackedPane.frame.size.height = measuredHeight
    }

    private func updateVisibility() {
        let split = layoutMode == .split
        oldPane.isHidden = !split
        newPane.isHidden = !split
        dividerView.isHidden = !split
        stackedPane.isHidden = split
    }

    private func lineLabels(from attributedString: NSAttributedString) -> [String] {
        attributedString.string.components(separatedBy: "\n")
    }

    func update(
        rows: [DiffDisplayRow],
        rowsSignature: DiffDisplayRowsSignature? = nil,
        layoutMode: DiffLayoutMode,
        wrapLines: Bool,
        showWhitespace: Bool,
        fileExtension: String,
        font: NSFont,
        theme: Theme,
        lspContext: DiffPaneLSPContext?,
        activeCommentHighlight: DiffReviewCommentHighlight? = nil,
        allowsReviewLineSelection: Bool = true,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in }
    ) {
        oldPane.allowsReviewLineSelection = allowsReviewLineSelection
        newPane.allowsReviewLineSelection = allowsReviewLineSelection
        stackedPane.allowsReviewLineSelection = allowsReviewLineSelection
        oldPane.onReviewLineSelected = onReviewLineSelected
        newPane.onReviewLineSelected = onReviewLineSelected
        stackedPane.onReviewLineSelected = onReviewLineSelected
        oldPane.onContextExpansion = onContextExpansion
        newPane.onContextExpansion = onContextExpansion
        stackedPane.onContextExpansion = onContextExpansion
        if oldPane.activeCommentHighlight != activeCommentHighlight {
            oldPane.activeCommentHighlight = activeCommentHighlight
            newPane.activeCommentHighlight = activeCommentHighlight
            stackedPane.activeCommentHighlight = activeCommentHighlight
        }

        let signature = RowsUpdateSignature(
            rowsSignature: rowsSignature ?? DiffDisplayRowsSignature(rows),
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            fontName: font.fontName,
            fontSize: font.pointSize,
            theme: theme,
            lspContext: lspContext.map(UpdateSignature.LSPContextSignature.init)
        )
        guard signature != lastRowsUpdateSignature else { return }
        lastRowsUpdateSignature = signature

        self.layoutMode = layoutMode
        layer?.backgroundColor = NSColor(theme.color("bg-1")).cgColor
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor(theme.color("line")).cgColor

        switch layoutMode {
        case .split:
            let result = DiffPaneTextDocumentBuilder.buildSplit(
                rows: rows,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            )
            oldPane.update(
                document: result.oldCode,
                lineLabels: lineLabels(from: result.oldGutter),
                wraps: wrapLines,
                font: font,
                theme: theme,
                lspContext: nil,
                allowedLSPSide: .new,
                onContextExpansion: onContextExpansion
            )
            newPane.update(
                document: result.newCode,
                lineLabels: lineLabels(from: result.newGutter),
                wraps: wrapLines,
                font: font,
                theme: theme,
                lspContext: lspContext,
                allowedLSPSide: .new,
                onContextExpansion: onContextExpansion
            )
            stackedPane.clearLSPContext()
            measuredHeight = max(oldPane.documentHeight, newPane.documentHeight)
        case .stacked:
            let result = DiffPaneTextDocumentBuilder.buildStacked(
                rows: rows,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            )
            stackedPane.update(
                document: result.code,
                lineLabels: lineLabels(from: result.gutter),
                wraps: wrapLines,
                font: font,
                theme: theme,
                lspContext: lspContext,
                allowedLSPSide: .new,
                onContextExpansion: onContextExpansion
            )
            oldPane.clearLSPContext()
            newPane.clearLSPContext()
            measuredHeight = stackedPane.documentHeight
        }

        updateVisibility()
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private struct UpdateSignature: Equatable {
        let groupID: String
        let groupContentHash: Int
        let expandedCollapsedRowIDs: Set<String>
        let layoutMode: DiffLayoutMode
        let wrapLines: Bool
        let showWhitespace: Bool
        let fileExtension: String
        let fontName: String
        let fontSize: CGFloat
        let theme: Theme
        let lspContext: LSPContextSignature?

        struct LSPContextSignature: Equatable {
            let worktreeRoot: URL
            let relativePath: String
            let language: String
            let lsp: ObjectIdentifier

            init(_ context: DiffPaneLSPContext) {
                worktreeRoot = context.worktreeRoot
                relativePath = context.relativePath
                language = context.language
                lsp = ObjectIdentifier(context.lsp)
            }
        }
    }

    private struct RowsUpdateSignature: Equatable {
        let rowsSignature: DiffDisplayRowsSignature
        let layoutMode: DiffLayoutMode
        let wrapLines: Bool
        let showWhitespace: Bool
        let fileExtension: String
        let fontName: String
        let fontSize: CGFloat
        let theme: Theme
        let lspContext: UpdateSignature.LSPContextSignature?
    }
}

final class DiffPaneTextScrollView: NSScrollView {
    private static let unwrappedTextContainerWidth: CGFloat = 1_000_000

    private struct TextLayoutConfiguration: Equatable {
        let wraps: Bool
        let containerWidth: CGFloat
    }

    private let textView: DiffPaneCodeTextView
    private var lineLabels: [String] = []
    private var rowKinds: [DiffDisplayRow.Kind] = []
    private var lineTones: [DiffPaneLineTone] = []
    private var expansionRequests: [(key: DiffContextExpansionKey, edge: DiffContextExpansionEdge?)?] = []
    private var baseDocument: DiffPaneTextDocumentBuilder.CodeDocument?
    private var synchronizedRowLineHeights: [CGFloat?] = []
    private var shouldResetHorizontalOrigin = false
    private var wraps = false
    private var appliedTextLayoutConfiguration: TextLayoutConfiguration?
    private var rowGeometryPresentationWidth: CGFloat?
    private var textLayoutConfigurationApplicationCount = 0
    private var horizontalScrollerVisibilityChangeCount = 0
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var theme: Theme?
    var activeCommentHighlight: DiffReviewCommentHighlight? {
        didSet {
            guard activeCommentHighlight != oldValue else { return }
            textView.activeCommentHighlight = activeCommentHighlight
            (verticalRulerView as? DiffPaneLineNumberRulerView)?.activeCommentHighlight = activeCommentHighlight
        }
    }
    var allowsReviewLineSelection: Bool = true {
        didSet {
            textView.allowsReviewLineSelection = allowsReviewLineSelection
            (verticalRulerView as? DiffPaneLineNumberRulerView)?.allowsReviewLineSelection = allowsReviewLineSelection
        }
    }
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in } {
        didSet {
            textView.onReviewLineSelected = onReviewLineSelected
        }
    }
    var onContextExpansion: DiffContextExpansionHandler = { _, _, _ in } {
        didSet {
            textView.contextExpansionHandler = onContextExpansion
            (verticalRulerView as? DiffPaneLineNumberRulerView)?.onContextExpansion = onContextExpansion
        }
    }

    var documentHeight: CGFloat {
        if let lastRow = textView.diffRowRects().last {
            return max(ceil(lastRow.maxY + textView.textContainerInset.height), fallbackTextHeight())
        }
        return max(measuredTextHeight() + textView.textContainerInset.height * 2, fallbackTextHeight())
    }

    var textLayoutConfigurationApplicationCountForTesting: Int {
        textLayoutConfigurationApplicationCount
    }

    var horizontalScrollerVisibilityChangeCountForTesting: Int {
        horizontalScrollerVisibilityChangeCount
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
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        textView = DiffPaneCodeTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        contentView = DiffPaneLeadingClipView(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        setHorizontalScrollerVisible(true)
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = textView
        hasVerticalRuler = true
        rulersVisible = true
        let ruler = DiffPaneLineNumberRulerView(scrollView: self)
        ruler.onReviewLineSelected = { [weak self] anchor in
            self?.onReviewLineSelected(anchor)
        }
        verticalRulerView = ruler
        textView.allowsReviewLineSelection = allowsReviewLineSelection
        textView.onReviewLineSelected = onReviewLineSelected

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.autoresizingMask = [.width]
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

    override func setFrameSize(_ newSize: NSSize) {
        let wasSuppressingFrameWidthGeometryInvalidation = textView.suppressesFrameWidthGeometryInvalidation
        textView.suppressesFrameWidthGeometryInvalidation = true
        super.setFrameSize(newSize)
        textView.suppressesFrameWidthGeometryInvalidation = wasSuppressingFrameWidthGeometryInvalidation
    }

    func update(
        document: DiffPaneTextDocumentBuilder.CodeDocument,
        lineLabels: [String],
        wraps: Bool,
        font: NSFont,
        theme: Theme,
        lspContext: DiffPaneLSPContext?,
        allowedLSPSide: DiffLineSide,
        onContextExpansion: @escaping DiffContextExpansionHandler = { _, _, _ in }
    ) {
        self.lineLabels = lineLabels
        self.rowKinds = document.lines.map(\.kind)
        self.lineTones = document.lines.enumerated().map { index, line in
            line.tone ?? DiffPaneLineTone(
                label: index < lineLabels.count ? lineLabels[index] : "",
                rowKind: line.kind
            )
        }
        self.expansionRequests = document.lines.map { metadata in
            metadata.expansionKey.map { (key: $0, edge: metadata.expansionEdge) }
        }
        self.baseDocument = document
        self.synchronizedRowLineHeights = []
        self.shouldResetHorizontalOrigin = true
        self.wraps = wraps
        self.font = font
        self.theme = theme
        self.onContextExpansion = onContextExpansion
        setHorizontalScrollerVisible(!wraps)

        textView.textStorage?.setAttributedString(document.attributedString)
        textView.font = font
        textView.lineMetadata = document.lines
        textView.lineTones = lineTones
        textView.contextExpansionHandler = onContextExpansion
        textView.theme = theme
        textView.activeCommentHighlight = activeCommentHighlight
        textView.lspContext = lspContext
        textView.allowedLSPSide = allowedLSPSide
        textView.updateLSPController()
        textView.insertionPointColor = NSColor(theme.color("fg"))

        if let ruler = verticalRulerView as? DiffPaneLineNumberRulerView {
            ruler.update(
                labels: lineLabels,
                lineTones: lineTones,
                rowHeight: lineHeight(),
                contentTopInset: textView.textContainerInset.height,
                theme: theme,
                expansionRequests: expansionRequests,
                activeCommentHighlight: activeCommentHighlight,
                onContextExpansion: onContextExpansion
            )
        }

        resetHorizontalOriginToLeading()
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func clearLSPContext() {
        textView.lspContext = nil
        textView.updateLSPController()
    }

    func diffRowRects() -> [NSRect] {
        textView.diffRowRects()
    }

    func synchronizeRowHeights(_ rowHeights: [CGFloat]) {
        guard let baseDocument else { return }
        guard rowHeights.count > 0 else { return }

        let currentRows = textView.diffRowRects()
        guard let textStorage = textView.textStorage else { return }
        var nextLineHeights = Array<CGFloat?>(repeating: nil, count: rowHeights.count)
        var changedParagraphs = false
        let affectedCount = min(max(rowHeights.count, synchronizedRowLineHeights.count), baseDocument.lines.count, currentRows.count)

        textStorage.beginEditing()
        for index in 0..<affectedCount {
            let targetHeight = index < rowHeights.count ? rowHeights[index] : nil
            let previousLineHeight = index < synchronizedRowLineHeights.count ? synchronizedRowLineHeights[index] : nil

            // Always re-derive the ideal per-line height from the row's
            // CURRENT geometry (rather than gating on "did the target height
            // change since last time"): a resize can change how many visual
            // lines this row's own text wraps to while the target height
            // (driven by the paired old/new row) stays the same, which would
            // otherwise leave a stale per-line height in place and make the
            // row too short to match its counterpart.
            var candidateLineHeight: CGFloat?
            var lineCount = 1
            if let targetHeight {
                let lineCountHeight = previousLineHeight ?? lineHeight()
                lineCount = max(1, Int(round(currentRows[index].height / max(lineCountHeight, 1))))
                let computed = targetHeight / CGFloat(lineCount)
                if computed > lineHeight() + 0.5 {
                    candidateLineHeight = computed
                }
            }

            // Only touch textStorage (and invalidate layout) when the
            // derived value actually differs from what's already applied —
            // recomputing an identical value every pass is what previously
            // turned a single legitimate height change into an unbounded
            // apply/strip/reapply cycle that re-triggered
            // `invalidateIntrinsicContentSize()` forever. Compare the TOTAL
            // row height (per-line delta × line count), not the per-line
            // delta alone — a row wrapped into many fragments can have a
            // genuine multi-point total height change that rounds to well
            // under 0.5pt per line, which would otherwise be skipped.
            let valueUnchanged: Bool
            switch (previousLineHeight, candidateLineHeight) {
            case (nil, nil):
                valueUnchanged = true
            case let (previous?, candidate?):
                valueUnchanged = abs(previous - candidate) * CGFloat(lineCount) <= 0.5
            default:
                valueUnchanged = false
            }
            guard !valueUnchanged else {
                nextLineHeights[index] = previousLineHeight
                continue
            }

            let range = baseDocument.lines[index].range
            guard range.location < textStorage.length else { continue }
            let paragraphRange = (textStorage.string as NSString).paragraphRange(for: NSRange(
                location: range.location,
                length: max(range.length, 1)
            ))
            let baseParagraph = paragraphStyle(from: baseDocument, at: range.location)
            let paragraph = NSMutableParagraphStyle()
            paragraph.setParagraphStyle(baseParagraph)

            if let candidateLineHeight {
                paragraph.minimumLineHeight = candidateLineHeight
                paragraph.maximumLineHeight = candidateLineHeight
                nextLineHeights[index] = candidateLineHeight
            }

            textStorage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
            changedParagraphs = true
        }
        textStorage.endEditing()

        synchronizedRowLineHeights = nextLineHeights
        // `lineTones`'s didSet unconditionally invalidates cached row
        // geometry, so only forward these when they actually differ —
        // otherwise a fully-stable call (nothing above changed) would still
        // force a row-geometry recompute on every parent layout pass.
        if textView.lineTones != lineTones {
            textView.lineTones = lineTones
        }
        if textView.theme != theme {
            textView.theme = theme
        }
        if changedParagraphs {
            // Explicit, rather than relying on the paragraph-style edit to
            // indirectly trigger it (e.g. via a `lineTones` reassignment):
            // `diffRowRects()` is typically already cached from an earlier
            // read in this same layout pass (the row heights this method was
            // just handed were measured from it), so a just-applied padding
            // change must invalidate it directly or callers later in the same
            // pass (e.g. `documentHeight`) read pre-padding geometry.
            textView.invalidateDiffRowGeometry()
            needsLayout = true
            invalidateIntrinsicContentSize()
            (verticalRulerView as? DiffPaneLineNumberRulerView)?.needsDisplay = true
        }
    }

    private func paragraphStyle(
        from document: DiffPaneTextDocumentBuilder.CodeDocument,
        at location: Int
    ) -> NSParagraphStyle {
        document.attributedString.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            ?? CenterTypography.paragraphStyle()
    }

    override func layout() {
        let wasSuppressingFrameWidthGeometryInvalidation = textView.suppressesFrameWidthGeometryInvalidation
        textView.suppressesFrameWidthGeometryInvalidation = true
        defer {
            textView.suppressesFrameWidthGeometryInvalidation = wasSuppressingFrameWidthGeometryInvalidation
        }

        super.layout()
        tile()
        let configuration = desiredTextLayoutConfiguration()
        let configurationChanged = !textLayoutConfigurationMatches(configuration)
        if configurationChanged, configuration.wraps {
            setTextViewSize(
                width: max(contentView.bounds.width, 1),
                height: textView.frame.height
            )
        }
        applyTextLayoutConfigurationIfNeeded(configuration)
        let finalTextViewWidth = textViewWidth()
        let presentationWidthChanged = !configuration.wraps
            && rowGeometryPresentationWidth.map { abs($0 - finalTextViewWidth) > 0.5 } == true
        setTextViewSize(width: finalTextViewWidth, height: textView.frame.height)
        if presentationWidthChanged {
            textView.invalidateDiffRowGeometry()
        }
        let geometryWillBeMeasured = !textView.hasCachedDiffRowGeometry
        let measuredDocumentHeight = documentHeight
        setTextViewSize(width: finalTextViewWidth, height: measuredDocumentHeight)
        if geometryWillBeMeasured {
            rowGeometryPresentationWidth = finalTextViewWidth
        }
        if shouldResetHorizontalOrigin {
            resetHorizontalOriginToLeading()
            shouldResetHorizontalOrigin = false
        }
        (verticalRulerView as? DiffPaneLineNumberRulerView)?.rowHeight = lineHeight()
    }

    override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView else { return }

        let rulerWidth = ruler.ruleThickness
        var clipFrame = contentView.frame
        guard clipFrame.minX < rulerWidth - 0.5 else { return }

        clipFrame.origin.x = rulerWidth
        clipFrame.size.width = max(bounds.width - rulerWidth, 1)
        contentView.frame = clipFrame
        var clipBounds = contentView.bounds
        clipBounds.size = clipFrame.size
        contentView.bounds = clipBounds
        if wraps {
            setTextViewSizeSuppressingFrameWidthGeometryInvalidation(
                width: max(clipFrame.width, 1),
                height: textView.frame.height
            )
        }
        ruler.frame = NSRect(
            x: 0,
            y: clipFrame.minY,
            width: rulerWidth,
            height: clipFrame.height
        )
    }

    func resetHorizontalOriginToLeading() {
        let currentY = contentView.bounds.origin.y
        contentView.scroll(to: NSPoint(x: 0, y: currentY))
        reflectScrolledClipView(contentView)
        (verticalRulerView as? DiffPaneLineNumberRulerView)?.needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }

    private func desiredTextLayoutConfiguration() -> TextLayoutConfiguration {
        TextLayoutConfiguration(
            wraps: wraps,
            containerWidth: wraps
                ? max(contentView.bounds.width - textView.textContainerInset.width * 2, 1)
                : Self.unwrappedTextContainerWidth
        )
    }

    private func applyTextLayoutConfigurationIfNeeded(_ configuration: TextLayoutConfiguration) {
        guard !textLayoutConfigurationMatches(configuration) else { return }

        textView.invalidateDiffRowGeometry()
        textView.isHorizontallyResizable = !configuration.wraps
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: configuration.containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: configuration.containerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        appliedTextLayoutConfiguration = configuration
        textLayoutConfigurationApplicationCount += 1
    }

    private func textLayoutConfigurationMatches(_ configuration: TextLayoutConfiguration) -> Bool {
        guard let appliedTextLayoutConfiguration else { return false }
        return appliedTextLayoutConfiguration.wraps == configuration.wraps
            && abs(appliedTextLayoutConfiguration.containerWidth - configuration.containerWidth) <= 0.5
    }

    private func setTextViewSize(width: CGFloat, height: CGFloat) {
        var size = textView.frame.size
        if size.width != width {
            size.width = width
        }
        if abs(size.height - height) > 0.5 {
            size.height = height
        }
        guard size != textView.frame.size else { return }
        textView.setFrameSize(size)
    }

    private func setTextViewSizeSuppressingFrameWidthGeometryInvalidation(width: CGFloat, height: CGFloat) {
        let wasSuppressingFrameWidthGeometryInvalidation = textView.suppressesFrameWidthGeometryInvalidation
        textView.suppressesFrameWidthGeometryInvalidation = true
        defer {
            textView.suppressesFrameWidthGeometryInvalidation = wasSuppressingFrameWidthGeometryInvalidation
        }
        setTextViewSize(width: width, height: height)
    }

    private func setHorizontalScrollerVisible(_ visible: Bool) {
        guard hasHorizontalScroller != visible else { return }
        hasHorizontalScroller = visible
        horizontalScrollerVisibilityChangeCount += 1
    }

    private func textViewWidth() -> CGFloat {
        let contentWidth = max(contentView.bounds.width, 1)
        if wraps {
            return contentWidth
        }
        return max(contentWidth, measuredTextWidth() + textView.textContainerInset.width * 2)
    }

    private func measuredTextHeight() -> CGFloat {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return 0
        }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    private func measuredTextWidth() -> CGFloat {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
            return 0
        }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).width)
    }

    private func fallbackTextHeight() -> CGFloat {
        CGFloat(max(lineLabels.count, 1)) * lineHeight() + textView.textContainerInset.height * 2
    }

    private func lineHeight() -> CGFloat {
        ceil(font.ascender + abs(font.descender) + font.leading)
    }
}

enum DiffPaneLineTone: Equatable {
    case context
    case add
    case delete
    case placeholder
    case collapsed

    init(label: String, rowKind: DiffDisplayRow.Kind) {
        if rowKind == .collapsed || rowKind == .expandableContext {
            self = .collapsed
        } else if label.isEmpty, rowKind != .context, rowKind != .expandedContext {
            self = .placeholder
        } else {
            switch rowKind {
            case .add:
                self = .add
            case .delete:
                self = .delete
            case .context, .expandedContext, .replacement:
                self = .context
            case .collapsed, .expandableContext:
                self = .collapsed
            }
        }
    }
}

final class DiffPaneCodeTextView: NSTextView {
    private struct RowGeometry {
        let rowRects: [NSRect]
        let firstLineFragmentRects: [NSRect]
    }

    private struct ExpansionTarget: Equatable {
        let row: Int
        let action: DiffPaneTextDocumentBuilder.ContextExpansionAction
    }

    static func placeholderHatchRect(in rowRect: NSRect) -> NSRect {
        rowRect.insetBy(dx: 0, dy: 1)
    }

    static func changeRailRect(in rowRect: NSRect, tone: DiffPaneLineTone) -> NSRect? {
        nil
    }

    static func commentHighlightRect(
        rowRects: [NSRect],
        rowRange: ClosedRange<Int>,
        visibleMinY: CGFloat,
        contentWidth: CGFloat
    ) -> NSRect {
        let rows = rowRange.compactMap { index in
            rowRects.indices.contains(index) ? rowRects[index] : nil
        }
        guard let first = rows.first else { return .zero }
        let union = rows.dropFirst().reduce(first) { $0.union($1) }
        return NSRect(
            x: 4,
            y: union.minY - visibleMinY,
            width: max(contentWidth - 8, 1),
            height: union.height
        )
    }

    private var ownedTextStorage: NSTextStorage?
    private var customTrackingArea: NSTrackingArea?
    private var lspController: DiffPaneLSPController?
    private var cachedRowGeometry: RowGeometry?
    private var rowGeometryComputationCount = 0
    var suppressesFrameWidthGeometryInvalidation = false
    private var hoverExpansionTarget: ExpansionTarget? {
        didSet { if hoverExpansionTarget != oldValue { needsDisplay = true } }
    }
    private var pressedExpansionTarget: ExpansionTarget? {
        didSet { if pressedExpansionTarget != oldValue { needsDisplay = true } }
    }
    private var armedExpansionTarget: ExpansionTarget?
    private var armedExpansionOptionKey = false
    /// Whether we last forced the pointing-hand cursor, so it can be restored to
    /// the default when the mouse leaves the view.
    private var didSetPointerCursor = false

    nonisolated static func expandPillFillAlpha(hovered: Bool, pressed: Bool) -> CGFloat {
        if pressed { return 0.36 }
        if hovered { return 0.28 }
        return 0
    }

    nonisolated static func expandPillRect(
        textRect: NSRect,
        firstLineRect: NSRect,
        rowRect: NSRect,
        chevronSize: NSSize,
        chevronGap: CGFloat = 5,
        horizontalPadding: CGFloat = 12,
        verticalInset: CGFloat = DiffPaneTextDocumentBuilder.expandableContextPillVerticalInset
    ) -> NSRect {
        let anchorRect = textRect.isEmpty ? (firstLineRect.isEmpty ? rowRect : firstLineRect) : textRect
        let pillHeight = max(anchorRect.height + verticalInset * 2, 1)
        let chevronLeftX = textRect.minX - chevronGap - chevronSize.width
        let pillLeft = (chevronSize == .zero ? textRect.minX : chevronLeftX) - horizontalPadding
        let idealY = anchorRect.midY - pillHeight / 2
        let pillY: CGFloat
        if !rowRect.isEmpty, rowRect.height >= pillHeight {
            pillY = min(max(idealY, rowRect.minY), rowRect.maxY - pillHeight)
        } else {
            pillY = idealY
        }
        return NSRect(
            x: pillLeft,
            y: pillY,
            width: textRect.maxX + horizontalPadding - pillLeft,
            height: pillHeight
        )
    }

    nonisolated static func expandChevronRect(
        chevronLeftX: CGFloat,
        chevronSize: NSSize,
        pillRect: NSRect
    ) -> NSRect {
        NSRect(
            x: chevronLeftX,
            y: pillRect.midY - chevronSize.height / 2,
            width: chevronSize.width,
            height: chevronSize.height
        )
    }

    var rowGeometryComputationCountForTesting: Int {
        rowGeometryComputationCount
    }

    var hasCachedDiffRowGeometry: Bool {
        cachedRowGeometry != nil
    }

    var lineTones: [DiffPaneLineTone] = [] {
        didSet {
            invalidateDiffRowGeometry()
            needsDisplay = true
        }
    }
    var lineMetadata: [DiffPaneTextDocumentBuilder.LineMetadata] = [] {
        didSet {
            invalidateDiffRowGeometry()
            needsDisplay = true
        }
    }
    var activeCommentHighlight: DiffReviewCommentHighlight? {
        didSet { needsDisplay = true }
    }
    var hoverHandler: ((NSPoint) -> Void)?
    var commandClickHandler: ((NSPoint) -> Void)?
    var flagsChangedHandler: ((NSEvent) -> Void)?
    var mouseExitedHandler: (() -> Void)?
    var contextExpansionHandler: DiffContextExpansionHandler = { _, _, _ in }
    var allowsReviewLineSelection = true
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    var lspContext: DiffPaneLSPContext?
    var allowedLSPSide: DiffLineSide = .new
    var hasLSPContextForTesting: Bool { lspContext != nil }
    var allowedLSPSideForTesting: DiffLineSide { allowedLSPSide }
    private var scrollBoundsObservers: [NSObjectProtocol] = []
    private var observedScrollViewIDs: [ObjectIdentifier] = []
    private var scheduledRebindWorkItem: DispatchWorkItem?

    var theme: Theme? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        if textStorage == nil, let textContainer {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            layoutManager.addTextContainer(textContainer)
            storage.addLayoutManager(layoutManager)
            ownedTextStorage = storage
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    deinit {
        let lspController = lspController
        let observers = scrollBoundsObservers
        let workItem = scheduledRebindWorkItem
        Task { @MainActor in
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            workItem?.cancel()
            lspController?.tearDown()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleDeferredRebind()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleDeferredRebind()
    }

    private func scheduleDeferredRebind() {
        scheduledRebindWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.installScrollBoundsObserver()
        }
        scheduledRebindWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLineBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if !suppressesFrameWidthGeometryInvalidation, abs(oldSize.width - newSize.width) > 0.5 {
            invalidateDiffRowGeometry()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateDiffRowGeometry()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverHandler?(point)
        hoverExpansionTarget = expansionTarget(at: point)
        // `super.mouseMoved` re-asserts the text view's I-beam on every move and
        // wins the ordering against `cursorUpdate`, so re-apply the pointer here
        // (unconditionally, no cached-state guard) after super has run.
        applyPointerCursorIfNeeded(at: point)
    }

    private func applyPointerCursorIfNeeded(at point: NSPoint) {
        if shouldUsePointingHandCursor(at: point) {
            NSCursor.pointingHand.set()
            didSetPointerCursor = true
        } else {
            didSetPointerCursor = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let target = expansionTarget(at: point) {
            armedExpansionTarget = target
            armedExpansionOptionKey = event.modifierFlags.contains(.option)
            pressedExpansionTarget = target
            return
        }
        if event.modifierFlags.contains(.command), let commandClickHandler {
            commandClickHandler(point)
            return
        }
        if allowsReviewLineSelection,
           event.clickCount == 1,
           let anchor = reviewLineAnchor(at: point)
        {
            onReviewLineSelected(anchor)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let armed = armedExpansionTarget else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        pressedExpansionTarget = expansionTarget(at: point) == armed ? armed : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let armed = armedExpansionTarget else {
            super.mouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let releasedInside = expansionTarget(at: point) == armed
        let optionKey = armedExpansionOptionKey
        pressedExpansionTarget = nil
        armedExpansionTarget = nil
        if releasedInside {
            invokeExpansion(action: armed.action, optionKey: optionKey)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        flagsChangedHandler?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverExpansionTarget = nil
        // Restore the default cursor when leaving the view, otherwise a pointing
        // hand set over an expandable/source row can linger over the surrounding
        // non-interactive chrome until the next cursor update.
        if didSetPointerCursor {
            NSCursor.arrow.set()
            didSetPointerCursor = false
        }
        mouseExitedHandler?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let customTrackingArea {
            if trackingAreas.contains(where: { $0 === customTrackingArea }) {
                removeTrackingArea(customTrackingArea)
            }
            self.customTrackingArea = nil
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        customTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    func diffRowRects() -> [NSRect] {
        rowGeometry().rowRects
    }

    func diffFirstLineFragmentRects() -> [NSRect] {
        rowGeometry().firstLineFragmentRects
    }

    func invalidateDiffRowGeometry() {
        cachedRowGeometry = nil
    }

    private func rowGeometry() -> RowGeometry {
        if let cachedRowGeometry {
            return cachedRowGeometry
        }

        let computed = computeRowGeometry()
        cachedRowGeometry = computed
        rowGeometryComputationCount += 1
        return computed
    }

    private func computeRowGeometry() -> RowGeometry {
        guard let layoutManager, let textContainer else {
            return RowGeometry(rowRects: [], firstLineFragmentRects: [])
        }
        layoutManager.ensureLayout(for: textContainer)
        let paragraphRanges = paragraphRanges(lineCount: lineTones.count)
        let origin = textContainerOrigin
        var fallbackY = textContainerOrigin.y

        var rowRects: [NSRect] = []
        var firstLineFragmentRects: [NSRect] = []
        rowRects.reserveCapacity(paragraphRanges.count)
        firstLineFragmentRects.reserveCapacity(paragraphRanges.count)

        for range in paragraphRanges {
            let rowRect = measuredRowRect(
                for: range,
                layoutManager: layoutManager,
                origin: origin,
                fallbackY: fallbackY
            )
            let firstRect = firstLineFragmentRect(
                for: range,
                layoutManager: layoutManager,
                origin: origin
            )
            rowRects.append(rowRect)
            firstLineFragmentRects.append(firstRect)
            fallbackY = rowRect.maxY
        }

        return RowGeometry(rowRects: rowRects, firstLineFragmentRects: firstLineFragmentRects)
    }

    func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let nsString = storage.string as NSString
        guard nsString.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(
            x: point.x - origin.x,
            y: point.y - origin.y
        )
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return nil }
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < glyphCount else { return nil }

        let lineFragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let lineUsedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let tolerance: CGFloat = 0.5
        guard containerPoint.y >= lineFragmentRect.minY - tolerance,
              containerPoint.y <= lineFragmentRect.maxY + tolerance,
              containerPoint.x >= lineUsedRect.minX - tolerance,
              containerPoint.x <= lineUsedRect.maxX + tolerance
        else {
            return nil
        }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return charIndex < nsString.length ? charIndex : nil
    }

    func symbolRange(at point: NSPoint) -> NSRange? {
        guard let index = characterIndex(at: point) else { return nil }
        let range = (string as NSString).rangeOfWord(at: index)
        return range.length == 0 ? nil : range
    }

    func symbolAnchorRect(for range: NSRange) -> NSRect? {
        guard range.length > 0,
              range.location != NSNotFound,
              let layoutManager,
              let textContainer,
              let storage = textStorage
        else {
            return nil
        }
        let textLength = (storage.string as NSString).length
        guard range.location >= 0,
              range.location < textLength,
              range.length <= textLength - range.location
        else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound,
              glyphRange.length > 0,
              glyphRange.location < layoutManager.numberOfGlyphs
        else {
            return nil
        }
        let glyph = glyphRange.location
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    func updateLSPController() {
        guard let lspContext else {
            lspController?.tearDown()
            lspController = nil
            removeScrollBoundsObserver()
            scheduledRebindWorkItem?.cancel()
            return
        }
        if lspController == nil {
            lspController = DiffPaneLSPController(textView: self)
        }
        // Rebind the scroll observer on every update. SwiftUI may attach the
        // text view to the outer vertical `ScrollView` after the first mount,
        // so the outermost ancestor scroll view can change over time.
        installScrollBoundsObserver()
        scheduleDeferredRebind()
        lspController?.update(context: lspContext, allowedSide: allowedLSPSide)
    }

    private func installScrollBoundsObserver() {
        // The diff pane has two scrolling layers: each `DiffPaneTextScrollView`
        // handles horizontal scrolling of a code pane, and in internal-scroll
        // mode a SwiftUI `ScrollView(.vertical)` wraps the hunk cards as an
        // ancestor `NSScrollView`. Observing only one of them can miss the
        // scroll direction that actually moves the symbol away. Rebind on every
        // update so we always observe every ancestor scroll view.
        let scrollViews = ancestorScrollViews()
        let scrollViewIDs = scrollViews.map(ObjectIdentifier.init)
        guard scrollViewIDs != observedScrollViewIDs else { return }
        removeScrollBoundsObserver()
        for scrollView in scrollViews {
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lspController?.notifyScrolled()
                }
            }
            scrollBoundsObservers.append(token)
        }
        observedScrollViewIDs = scrollViewIDs
    }

    private func ancestorScrollViews() -> [NSScrollView] {
        var scrollViews: [NSScrollView] = []
        var current: NSView? = self
        while let view = current {
            if let scrollView = view as? NSScrollView {
                scrollViews.append(scrollView)
            }
            current = view.superview
        }
        return scrollViews
    }

    private func removeScrollBoundsObserver() {
        for token in scrollBoundsObservers {
            NotificationCenter.default.removeObserver(token)
        }
        scrollBoundsObservers.removeAll()
        observedScrollViewIDs.removeAll()
    }

    func reviewLineAnchor(atRow row: Int) -> DiffReviewLineAnchor? {
        guard lineMetadata.indices.contains(row) else { return nil }
        return lineMetadata[row].reviewLineAnchor(rowIndex: row)
    }

    func reviewLineAnchor(fromRow startRow: Int, toRow endRow: Int) -> DiffReviewLineAnchor? {
        let lowerRow = min(startRow, endRow)
        let upperRow = max(startRow, endRow)
        guard lineMetadata.indices.contains(lowerRow),
              lineMetadata.indices.contains(upperRow)
        else { return nil }

        var resolvedAnchors: [DiffReviewLineAnchor] = []
        for rowIndex in lowerRow...upperRow {
            let metadata = lineMetadata[rowIndex]
            if let anchor = metadata.reviewLineAnchor(rowIndex: rowIndex) {
                resolvedAnchors.append(anchor)
            } else if metadata.tone != .placeholder {
                return nil
            }
        }
        guard !resolvedAnchors.isEmpty,
              let first = resolvedAnchors.first,
              resolvedAnchors.allSatisfy({ $0.path == first.path })
        else { return nil }
        guard resolvedAnchors.count > 1 else { return first }

        let side = resolvedAnchors.allSatisfy({ $0.side == first.side }) ? first.side : .unknown
        let lineNumbers = resolvedAnchors.flatMap { anchor -> [Int] in
            if let endLine = anchor.endLine {
                return [anchor.line, endLine]
            }
            return [anchor.line]
        }
        guard let startLine = lineNumbers.min(),
              let endLine = lineNumbers.max()
        else { return nil }

        return DiffReviewLineAnchor(
            path: first.path,
            side: side,
            line: startLine,
            endLine: endLine,
            rowIndex: first.rowIndex,
            endRowIndex: resolvedAnchors.last?.rowIndex ?? first.rowIndex,
            selectedLines: resolvedAnchors.flatMap(\.selectedLines),
            selectedText: resolvedAnchors.map(\.selectedText).joined(separator: "\n")
        )
    }

    func reviewLineAnchor(at point: NSPoint) -> DiffReviewLineAnchor? {
        guard let row = reviewLineRow(at: point) else { return nil }
        return reviewLineAnchor(atRow: row)
    }

    func reviewLineRow(at point: NSPoint) -> Int? {
        let rowRects = diffRowRects()
        return rowRects.binarySearchRow(containing: point)
    }

    override func cursorUpdate(with event: NSEvent) {
        // A selectable NSTextView asserts its I-beam through `cursorUpdate(with:)`
        // on its own cursor-update tracking areas, which overrides the legacy
        // `addCursorRect`/`resetCursorRects` mechanism. Override it here so
        // expandable-context and reviewable source rows show the pointer instead.
        let point = convert(event.locationInWindow, from: nil)
        if shouldUsePointingHandCursor(at: point) {
            NSCursor.pointingHand.set()
            didSetPointerCursor = true
        } else {
            didSetPointerCursor = false
            super.cursorUpdate(with: event)
        }
    }

    private func shouldUsePointingHandCursor(at point: NSPoint) -> Bool {
        if expansionTarget(at: point) != nil {
            return true
        }
        guard let row = reviewLineRow(at: point) else { return false }
        return rowShouldUsePointingHandCursor(row)
    }

    private func rowShouldUsePointingHandCursor(_ row: Int) -> Bool {
        guard lineMetadata.indices.contains(row) else { return false }
        let metadata = lineMetadata[row]
        return metadata.sourceLine != nil
    }

    func invokeExpansionForTesting(row: Int, optionKey: Bool) {
        guard let action = expansionActions(atRow: row).first else { return }
        invokeExpansion(action: action, optionKey: optionKey)
    }

    private func expansionTarget(at point: NSPoint) -> ExpansionTarget? {
        let rowRects = diffRowRects()
        guard let row = rowRects.binarySearchRow(containing: point) else { return nil }
        let rowRect = rowRects[row]
        for action in expansionActions(atRow: row) {
            guard let pillRect = expansionPillRect(action: action, rowRect: rowRect) else { continue }
            if pillRect.contains(point) {
                return ExpansionTarget(row: row, action: action)
            }
        }
        return nil
    }

    private func expansionActions(atRow row: Int) -> [DiffPaneTextDocumentBuilder.ContextExpansionAction] {
        guard lineMetadata.indices.contains(row) else { return [] }
        let metadata = lineMetadata[row]
        if !metadata.expansionActions.isEmpty {
            return metadata.expansionActions
        }
        guard let key = metadata.expansionKey else { return [] }
        let mode: DiffPaneTextDocumentBuilder.ContextExpansionActionMode = key.isShared && metadata.expansionEdge == nil ? .all : .chunk
        return [
            DiffPaneTextDocumentBuilder.ContextExpansionAction(
                key: key,
                boundary: metadata.expansionBoundary ?? key.boundary,
                edge: metadata.expansionEdge,
                mode: mode,
                range: metadata.range
            ),
        ]
    }

    private func invokeExpansion(
        action: DiffPaneTextDocumentBuilder.ContextExpansionAction,
        optionKey: Bool
    ) {
        let actionMode: DiffPaneTextDocumentBuilder.ContextExpansionActionMode = optionKey ? .all : action.mode
        let mode: DiffContextExpansionMode = actionMode == .all ? .all : .chunk(size: diffContextExpansionChunkSize)
        contextExpansionHandler(action.key, mode, action.edge)
    }

    private func drawLineBackgrounds(in dirtyRect: NSRect) {
        guard let theme else { return }
        let rowRects = diffRowRects()
        for index in rowRects.indicesIntersecting(dirtyRect) {
            guard lineTones.indices.contains(index) else { continue }
            let rowRect = rowRects[index]
            let tone = lineTones[index]
            guard tone != .context else { continue }

            rowFill(for: tone, theme: theme).setFill()
            rowRect.fill()
            if tone == .placeholder {
                drawPlaceholderHatch(in: rowRect, theme: theme)
            } else if lineMetadata.indices.contains(index), lineMetadata[index].kind == .expandableContext {
                drawExpandableContextPill(row: index, in: rowRect, theme: theme)
            }
        }
        drawActiveCommentHighlight(in: dirtyRect, rowRects: rowRects, theme: theme)
    }

    private func drawActiveCommentHighlight(in dirtyRect: NSRect, rowRects: [NSRect], theme: Theme) {
        guard let rowRange = activeCommentHighlight?.highlightedRowRange(in: lineMetadata) else { return }
        let rect = Self.commentHighlightRect(
            rowRects: rowRects,
            rowRange: rowRange,
            visibleMinY: bounds.minY,
            contentWidth: bounds.width
        )
        guard rect != .zero, rect.intersects(dirtyRect) else { return }

        let accent = NSColor(theme.color("accent"))
        accent.withAlphaComponent(0.12).setFill()
        let fillPath = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        fillPath.fill()

        accent.withAlphaComponent(0.82).setStroke()
        let strokePath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        strokePath.lineWidth = 1
        strokePath.stroke()
    }

    private func paragraphRanges(lineCount: Int) -> [NSRange] {
        let ns = string as NSString
        var ranges: [NSRange] = []
        var location = 0
        for _ in 0..<lineCount {
            if location >= ns.length {
                ranges.append(NSRange(location: ns.length, length: 0))
                continue
            }
            let searchRange = NSRange(location: location, length: ns.length - location)
            let newline = ns.range(of: "\n", options: [], range: searchRange)
            if newline.location == NSNotFound {
                ranges.append(NSRange(location: location, length: ns.length - location))
                location = ns.length
            } else {
                ranges.append(NSRange(location: location, length: NSMaxRange(newline) - location))
                location = NSMaxRange(newline)
            }
        }
        return ranges
    }

    private func measuredRowRect(
        for range: NSRange,
        layoutManager: NSLayoutManager,
        origin: NSPoint,
        fallbackY: CGFloat
    ) -> NSRect {
        let defaultHeight = layoutManager.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))
        let fallback = NSRect(
            x: 0,
            y: fallbackY,
            width: max(bounds.width, visibleRect.width),
            height: defaultHeight
        )
        guard range.length > 0 else { return fallback }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return fallback }

        var rowRect = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineFragmentRect, _, _, _, _ in
            rowRect = rowRect.union(lineFragmentRect)
        }
        guard !rowRect.isNull else { return fallback }

        return NSRect(
            x: 0,
            y: rowRect.minY + origin.y,
            width: max(bounds.width, visibleRect.width),
            height: max(rowRect.height, defaultHeight)
        )
    }

    private func firstLineFragmentRect(
        for range: NSRange,
        layoutManager: NSLayoutManager,
        origin: NSPoint
    ) -> NSRect {
        let defaultHeight = layoutManager.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))
        guard range.length > 0 else {
            return NSRect(x: 0, y: origin.y, width: bounds.width, height: defaultHeight)
        }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            return NSRect(x: 0, y: origin.y, width: bounds.width, height: defaultHeight)
        }

        var firstRect: NSRect?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineFragmentRect, _, _, _, stop in
            firstRect = lineFragmentRect
            stop.pointee = true
        }

        guard var rect = firstRect else {
            return NSRect(x: 0, y: origin.y, width: bounds.width, height: defaultHeight)
        }
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        rect.size.width = max(bounds.width, visibleRect.width)
        rect.size.height = max(ceil(rect.height), defaultHeight)
        return rect
    }

    private func rowFill(for tone: DiffPaneLineTone, theme: Theme) -> NSColor {
        switch tone {
        case .add:
            return NSColor(theme.color("add")).withAlphaComponent(0.18)
        case .delete:
            return NSColor(theme.color("del")).withAlphaComponent(0.18)
        case .placeholder:
            return NSColor(theme.color("bg-2")).withAlphaComponent(0.55)
        case .collapsed:
            return NSColor(theme.color("bg-3")).withAlphaComponent(0.72)
        case .context:
            return .clear
        }
    }

    private func drawPlaceholderHatch(in rect: NSRect, theme: Theme) {
        let hatchRect = Self.placeholderHatchRect(in: rect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: hatchRect).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let path = NSBezierPath()
        let spacing: CGFloat = 8
        var x = hatchRect.minX - hatchRect.height
        while x < hatchRect.maxX {
            path.move(to: NSPoint(x: x, y: hatchRect.maxY))
            path.line(to: NSPoint(x: x + hatchRect.height, y: hatchRect.minY))
            x += spacing
        }
        path.lineWidth = 1
        NSColor(theme.color("line")).withAlphaComponent(0.35).setStroke()
        path.stroke()
    }

    private func drawExpandableContextPill(row: Int, in rowRect: NSRect, theme: Theme) {
        let actions = expansionActions(atRow: row)
        guard !actions.isEmpty else { return }

        // Split panes can synchronize a row to be taller than its first text
        // fragment. Keep the pill attached to the fragment where the label is
        // drawn instead of centering it in the full synchronized row.
        // The chevron is drawn here (not baked into the text) so the backing
        // string stays a plain label for selection/copy.
        let tint = NSColor(theme.color("seg-pill-active-fg"))
        for action in actions {
            guard let pillRect = expansionPillRect(action: action, rowRect: rowRect) else { continue }
            let target = ExpansionTarget(row: row, action: action)
            let alpha = Self.expandPillFillAlpha(
                hovered: hoverExpansionTarget == target,
                pressed: pressedExpansionTarget == target
            )
            let path = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
            NSColor(theme.color("accent")).withAlphaComponent(alpha).setFill()
            path.fill()

            guard
                let chevronImage = Self.expandChevronImage(
                    boundary: action.boundary,
                    mode: action.mode,
                    font: font,
                    color: tint
                ),
                let chevronRect = expansionChevronRect(action: action, rowRect: rowRect)
            else {
                continue
            }
            chevronImage.draw(in: chevronRect)
        }
    }

    private func expansionPillRect(
        action: DiffPaneTextDocumentBuilder.ContextExpansionAction,
        rowRect: NSRect
    ) -> NSRect? {
        guard let textRect = expansionActionTextRect(action) else { return nil }
        let chevronGap: CGFloat = 5
        let chevronSize = Self.expandChevronImage(
            boundary: action.boundary,
            mode: action.mode,
            font: font,
            color: .textColor
        )?.size ?? .zero
        let firstLineRect = expansionActionFirstLineRect(action)
        return Self.expandPillRect(
            textRect: textRect,
            firstLineRect: firstLineRect,
            rowRect: rowRect,
            chevronSize: chevronSize,
            chevronGap: chevronGap
        )
    }

    private func expansionChevronRect(
        action: DiffPaneTextDocumentBuilder.ContextExpansionAction,
        rowRect: NSRect
    ) -> NSRect? {
        guard let textRect = expansionActionTextRect(action) else { return nil }
        let chevronGap: CGFloat = 5
        let chevronImage = Self.expandChevronImage(
            boundary: action.boundary,
            mode: action.mode,
            font: font,
            color: .textColor
        )
        guard let chevronImage else { return nil }
        let chevronSize = chevronImage.size
        let firstLineRect = expansionActionFirstLineRect(action)
        let pillRect = Self.expandPillRect(
            textRect: textRect,
            firstLineRect: firstLineRect,
            rowRect: rowRect,
            chevronSize: chevronSize,
            chevronGap: chevronGap
        )
        return Self.expandChevronRect(
            chevronLeftX: textRect.minX - chevronGap - chevronSize.width,
            chevronSize: chevronSize,
            pillRect: pillRect
        )
    }

    private func expansionActionTextRect(
        _ action: DiffPaneTextDocumentBuilder.ContextExpansionAction
    ) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let textLength = (string as NSString).length
        guard action.range.location >= 0,
              action.range.length > 0,
              action.range.location < textLength,
              action.range.length <= textLength - action.range.location
        else {
            return nil
        }

        let label = (string as NSString).substring(with: action.range)
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: action.range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }

        let textRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return textRect.isEmpty ? nil : textRect
    }

    private func expansionActionFirstLineRect(
        _ action: DiffPaneTextDocumentBuilder.ContextExpansionAction
    ) -> NSRect {
        guard let layoutManager else { return .zero }
        return firstLineFragmentRect(
            for: action.range,
            layoutManager: layoutManager,
            origin: textContainerOrigin
        )
    }

    private static func expandChevronImage(
        boundary: DiffContextBoundary?,
        mode: DiffPaneTextDocumentBuilder.ContextExpansionActionMode,
        font: NSFont?,
        color: NSColor
    ) -> NSImage? {
        let symbol = DiffPaneTextDocumentBuilder.expandableContextSymbolName(
            boundary: boundary,
            mode: mode
        )
        let pointSize = (font?.pointSize ?? 13) - 1
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}

final class DiffPaneLineNumberRulerView: NSRulerView {
    private struct RulerGeometry {
        let rowRects: [NSRect]
        let labelRects: [NSRect]
        let key: RulerGeometryKey
    }

    private struct RulerGeometryKey: Equatable {
        let labelCount: Int
        let documentViewSize: NSSize
        let ruleThickness: CGFloat
        let rowHeight: CGFloat
        let contentTopInset: CGFloat
    }

    private var labels: [String] = []
    private var lineTones: [DiffPaneLineTone] = []
    private var expansionRequests: [(key: DiffContextExpansionKey, edge: DiffContextExpansionEdge?)?] = []
    private var theme: Theme?
    private var hoverRowIndex: Int? {
        didSet {
            if hoverRowIndex != oldValue {
                needsDisplay = true
            }
        }
    }
    private var trackingArea: NSTrackingArea?
    var rowHeight: CGFloat = 16
    var allowsReviewLineSelection: Bool = true
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    var onContextExpansion: DiffContextExpansionHandler = { _, _, _ in }
    var activeCommentHighlight: DiffReviewCommentHighlight? {
        didSet { needsDisplay = true }
    }
    private var contentTopInset: CGFloat = 6
    private var boundsObserver: NSObjectProtocol?
    private var selectionStartRow: Int?
    private var selectionCurrentRow: Int?
    private var cachedGeometry: RulerGeometry?
    private var rowGeometryComputationCount = 0

    var rowGeometryComputationCountForTesting: Int {
        rowGeometryComputationCount
    }

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = DiffPaneLineNumberGutterGeometry.minimumThickness
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        observe(scrollView: scrollView)
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    func update(
        labels: [String],
        lineTones: [DiffPaneLineTone],
        rowHeight: CGFloat,
        contentTopInset: CGFloat,
        theme: Theme,
        expansionRequests: [(key: DiffContextExpansionKey, edge: DiffContextExpansionEdge?)?],
        activeCommentHighlight: DiffReviewCommentHighlight?,
        onContextExpansion: @escaping DiffContextExpansionHandler
    ) {
        self.labels = labels
        self.lineTones = lineTones
        self.rowHeight = rowHeight
        self.contentTopInset = contentTopInset
        self.theme = theme
        self.expansionRequests = expansionRequests
        self.activeCommentHighlight = activeCommentHighlight
        self.onContextExpansion = onContextExpansion
        updateThickness()
        invalidateGeometry()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if abs(oldSize.width - newSize.width) > 0.5 || abs(oldSize.height - newSize.height) > 0.5 {
            invalidateGeometry()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let scrollView,
              let textView = scrollView.documentView as? DiffPaneCodeTextView
        else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let sourcePoint = NSPoint(
            x: point.x,
            y: point.y + scrollView.contentView.bounds.origin.y
        )
        if let row = rowIndex(at: sourcePoint), invokeExpansion(row: row, optionKey: event.modifierFlags.contains(.option)) {
            return
        }
        guard allowsReviewLineSelection, let row = textView.reviewLineRow(at: sourcePoint) else {
            super.mouseDown(with: event)
            return
        }

        selectionStartRow = row
        selectionCurrentRow = row
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrollView,
              let textView = scrollView.documentView as? DiffPaneCodeTextView,
              selectionStartRow != nil
        else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let sourcePoint = NSPoint(
            x: point.x,
            y: point.y + scrollView.contentView.bounds.origin.y
        )
        if let row = textView.reviewLineRow(at: sourcePoint), row != selectionCurrentRow {
            selectionCurrentRow = row
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            selectionStartRow = nil
            selectionCurrentRow = nil
            needsDisplay = true
        }
        guard let scrollView,
              let textView = scrollView.documentView as? DiffPaneCodeTextView,
              let startRow = selectionStartRow,
              let currentRow = selectionCurrentRow,
              let anchor = textView.reviewLineAnchor(fromRow: startRow, toRow: currentRow)
        else {
            super.mouseUp(with: event)
            return
        }

        onReviewLineSelected(anchor)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoverRow(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverRowIndex = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let theme else { return }
        NSColor(theme.color("bg-0")).setFill()
        bounds.fill()

        guard let scrollView, !labels.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let geometry = rowGeometry()
        let rowRects = geometry.rowRects
        guard !rowRects.isEmpty else { return }
        let visibleRows = visibleRowIndices(in: visible, rowRects: rowRects)

        for index in visibleRows {
            let sourceRowRect = rowRects[index]
            let y = sourceRowRect.minY - visible.minY
            let rowRect = NSRect(x: 0, y: y, width: ruleThickness, height: sourceRowRect.height)
            drawRowBackground(index: index, rowRect: rowRect, theme: theme)
        }

        drawActiveCommentHighlight(visibleRect: visible, rowRects: rowRects, theme: theme)

        let textHeight = ("8" as NSString).size(withAttributes: labelAttributes(for: "", row: nil)).height
        let labelRects = geometry.labelRects
        for index in visibleRows {
            let label = labels[index]
            let sourceRowRect = rowRects[index]
            let y = sourceRowRect.minY - visible.minY
            let rowRect = NSRect(x: 0, y: y, width: ruleThickness, height: sourceRowRect.height)
            guard !label.isEmpty else { continue }
            let sourceLabelRect = labelRects.indices.contains(index)
                ? labelRects[index]
                : NSRect(
                    x: 0,
                    y: sourceRowRect.minY,
                    width: ruleThickness - DiffPaneLineNumberGutterGeometry.horizontalPadding,
                    height: textHeight
                )
            let drawRect = NSRect(
                x: sourceLabelRect.minX,
                y: sourceLabelRect.minY - visible.minY,
                width: ruleThickness - DiffPaneLineNumberGutterGeometry.horizontalPadding,
                height: textHeight
            )
            NSString(string: label).draw(in: drawRect, withAttributes: labelAttributes(for: label, row: index))
            if index == hoverRowIndex, isReviewCommentableRow(index) {
                drawReviewAffordance(in: rowRect, theme: theme)
            }
        }
        drawSelectionOutline(visibleRect: visible, rowRects: rowRects, theme: theme)
    }

    func visibleRowIndices(in visibleRect: NSRect) -> [Int] {
        visibleRowIndices(in: visibleRect, rowRects: rowGeometry().rowRects)
    }

    func labelDrawRects() -> [NSRect] {
        rowGeometry().labelRects
    }

    func diffRowRects() -> [NSRect] {
        rowGeometry().rowRects
    }

    private func visibleRowIndices(in visibleRect: NSRect, rowRects: [NSRect]) -> [Int] {
        let start = lowerBound(rowRects) { rowRect in
            rowRect.maxY >= visibleRect.minY
        }
        let end = lowerBound(rowRects) { rowRect in
            rowRect.minY > visibleRect.maxY
        }
        guard start < end else { return [] }
        return Array(start..<end)
    }

    private func lowerBound(_ rowRects: [NSRect], predicate: (NSRect) -> Bool) -> Int {
        var low = 0
        var high = rowRects.count
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(rowRects[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    private func rowGeometry() -> RulerGeometry {
        let key = RulerGeometryKey(
            labelCount: labels.count,
            documentViewSize: scrollView?.documentView?.bounds.size ?? .zero,
            ruleThickness: ruleThickness,
            rowHeight: rowHeight,
            contentTopInset: contentTopInset
        )
        if let cachedGeometry, cachedGeometry.key == key {
            return cachedGeometry
        }

        let computed = computeRowGeometry(key: key)
        cachedGeometry = computed
        rowGeometryComputationCount += 1
        return computed
    }

    private func computeRowGeometry(key: RulerGeometryKey) -> RulerGeometry {
        let rowRects = computeDiffRowRects()
        let textHeight = ("8" as NSString).size(withAttributes: labelAttributes(for: "", row: nil)).height
        let textLineRects: [NSRect]
        if let textView = scrollView?.documentView as? DiffPaneCodeTextView {
            textLineRects = textView.diffFirstLineFragmentRects()
        } else {
            textLineRects = rowRects.map {
                NSRect(x: 0, y: $0.minY, width: $0.width, height: min($0.height, rowHeight))
            }
        }

        let labelRects = labels.indices.map { index in
            let lineRect = textLineRects.indices.contains(index)
                ? textLineRects[index]
                : NSRect(x: 0, y: contentTopInset + CGFloat(index) * rowHeight, width: ruleThickness, height: rowHeight)
            return NSRect(
                x: 0,
                y: lineRect.midY - textHeight / 2,
                width: ruleThickness - DiffPaneLineNumberGutterGeometry.horizontalPadding,
                height: textHeight
            )
        }
        return RulerGeometry(rowRects: rowRects, labelRects: labelRects, key: key)
    }

    private func computeDiffRowRects() -> [NSRect] {
        if let textView = scrollView?.documentView as? DiffPaneCodeTextView {
            return textView.diffRowRects().prefix(labels.count).map { rect in
                NSRect(x: 0, y: rect.minY, width: ruleThickness, height: rect.height)
            }
        }
        return labels.indices.map { index in
            NSRect(
                x: 0,
                y: contentTopInset + CGFloat(index) * rowHeight,
                width: ruleThickness,
                height: rowHeight
            )
        }
    }

    private func invalidateGeometry() {
        cachedGeometry = nil
    }

    func labelAttributesForTesting(row: Int) -> [NSAttributedString.Key: Any] {
        labelAttributes(for: labels.indices.contains(row) ? labels[row] : "", row: row)
    }

    func invokeExpansionForTesting(row: Int, optionKey: Bool) {
        _ = invokeExpansion(row: row, optionKey: optionKey)
    }

    func invokeReviewLineSelectionForTesting(row: Int) {
        guard let textView = scrollView?.documentView as? DiffPaneCodeTextView,
              let anchor = textView.reviewLineAnchor(atRow: row)
        else {
            return
        }
        onReviewLineSelected(anchor)
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        diffRowRects().binarySearchRow(containing: point)
    }

    private func invokeExpansion(row: Int, optionKey: Bool) -> Bool {
        guard expansionRequests.indices.contains(row),
              let request = expansionRequests[row]
        else {
            return false
        }

        let mode = expansionMode(for: request, optionKey: optionKey)
        onContextExpansion(request.key, mode, request.edge)
        return true
    }

    private func expansionMode(
        for request: (key: DiffContextExpansionKey, edge: DiffContextExpansionEdge?),
        optionKey: Bool
    ) -> DiffContextExpansionMode {
        if optionKey || (request.key.isShared && request.edge == nil) {
            return .all
        }
        return .chunk(size: diffContextExpansionChunkSize)
    }

    static func selectionOutlineRect(
        rowRects: [NSRect],
        rowRange: ClosedRange<Int>,
        visibleMinY: CGFloat,
        ruleThickness: CGFloat
    ) -> NSRect {
        let rows = rowRange.compactMap { index in
            rowRects.indices.contains(index) ? rowRects[index] : nil
        }
        guard let first = rows.first else { return .zero }
        let union = rows.dropFirst().reduce(first) { $0.union($1) }
        return NSRect(
            x: 4,
            y: max(0, union.minY - visibleMinY),
            width: max(ruleThickness - 8, 1),
            height: union.height
        )
    }

    static func activeCommentHighlightRect(
        rowRects: [NSRect],
        rowRange: ClosedRange<Int>,
        visibleMinY: CGFloat,
        ruleThickness: CGFloat
    ) -> NSRect {
        let rows = rowRange.compactMap { index in
            rowRects.indices.contains(index) ? rowRects[index] : nil
        }
        guard let first = rows.first else { return .zero }
        let union = rows.dropFirst().reduce(first) { $0.union($1) }
        let clippedMinY = max(visibleMinY, union.minY)
        return NSRect(
            x: 0,
            y: max(0, clippedMinY - visibleMinY),
            width: ruleThickness,
            height: max(0, union.maxY - clippedMinY)
        )
    }

    private func observe(scrollView: NSScrollView) {
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    private func updateHoverRow(with event: NSEvent) {
        guard let scrollView else {
            hoverRowIndex = nil
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let sourcePoint = NSPoint(
            x: point.x,
            y: point.y + scrollView.contentView.bounds.origin.y
        )
        guard let row = rowIndex(at: sourcePoint),
              isReviewCommentableRow(row)
        else {
            hoverRowIndex = nil
            return
        }
        hoverRowIndex = row
    }

    private func isReviewCommentableRow(_ row: Int) -> Bool {
        guard allowsReviewLineSelection else { return false }
        guard let textView = scrollView?.documentView as? DiffPaneCodeTextView else { return false }
        return textView.reviewLineAnchor(atRow: row) != nil
    }

    private func updateThickness() {
        ruleThickness = DiffPaneLineNumberGutterGeometry.thickness(labels: labels)
    }

    private func labelAttributes(for label: String, row: Int?) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let color: NSColor
        if let theme {
            let tone = row.flatMap(labelTone(at:))
            if tone == .add || (tone == nil && label.hasPrefix("+")) {
                color = NSColor(theme.color("add"))
            } else if tone == .delete || (tone == nil && label.hasPrefix("-")) {
                color = NSColor(theme.color("del"))
            } else {
                color = NSColor(theme.color("fg-faint"))
            }
        } else {
            color = .secondaryLabelColor
        }
        return [
            .font: DiffPaneLineNumberGutterGeometry.labelFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    private func labelTone(at row: Int) -> DiffPaneLineTone? {
        lineTones.indices.contains(row) ? lineTones[row] : nil
    }

    private func drawRowBackground(index: Int, rowRect: NSRect, theme: Theme) {
        guard lineTones.indices.contains(index) else { return }
        let tone = lineTones[index]
        let fill: NSColor
        switch tone {
        case .add:
            fill = NSColor(theme.color("add")).withAlphaComponent(0.16)
        case .delete:
            fill = NSColor(theme.color("del")).withAlphaComponent(0.16)
        case .placeholder:
            fill = NSColor(theme.color("bg-2")).withAlphaComponent(0.55)
        case .collapsed:
            fill = NSColor(theme.color("bg-3")).withAlphaComponent(0.72)
        case .context:
            fill = .clear
        }
        fill.setFill()
        rowRect.fill()

        let railColor: NSColor?
        switch tone {
        case .add:
            railColor = NSColor(theme.color("add"))
        case .delete:
            railColor = NSColor(theme.color("del"))
        default:
            railColor = nil
        }
        if let railColor, let railRect = Self.changeRailRect(in: rowRect, tone: tone) {
            railColor.setFill()
            railRect.fill()
        }
    }

    private func drawReviewAffordance(in rowRect: NSRect, theme: Theme) {
        let rect = Self.reviewAffordanceRect(in: rowRect, ruleThickness: ruleThickness)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor(theme.color("accent")).setFill()
        path.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor(theme.color("bg-1")),
        ]
        let string = "+" as NSString
        let size = string.size(withAttributes: attributes)
        let point = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2 - 0.5
        )
        string.draw(at: point, withAttributes: attributes)
    }

    static func reviewAffordanceRect(in rowRect: NSRect, ruleThickness: CGFloat) -> NSRect {
        let size: CGFloat = 16
        return NSRect(
            x: min(rowRect.maxX, ruleThickness) - size - 4,
            y: rowRect.midY - size / 2,
            width: size,
            height: size
        )
    }

    private func drawSelectionOutline(visibleRect: NSRect, rowRects: [NSRect], theme: Theme) {
        guard let start = selectionStartRow,
              let current = selectionCurrentRow
        else { return }

        let rowRange = min(start, current)...max(start, current)
        let outlineRect = Self.selectionOutlineRect(
            rowRects: rowRects,
            rowRange: rowRange,
            visibleMinY: visibleRect.minY,
            ruleThickness: ruleThickness
        )
        guard outlineRect != .zero else { return }

        NSColor(theme.color("accent")).setStroke()
        let path = NSBezierPath(roundedRect: outlineRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawActiveCommentHighlight(visibleRect: NSRect, rowRects: [NSRect], theme: Theme) {
        guard let textView = scrollView?.documentView as? DiffPaneCodeTextView,
              let rowRange = activeCommentHighlight?.highlightedRowRange(in: textView.lineMetadata)
        else { return }
        let highlightRect = Self.activeCommentHighlightRect(
            rowRects: rowRects,
            rowRange: rowRange,
            visibleMinY: visibleRect.minY,
            ruleThickness: ruleThickness
        )
        guard highlightRect != .zero else { return }

        let accent = NSColor(theme.color("accent"))
        accent.withAlphaComponent(0.18).setFill()
        highlightRect.fill()
    }

    static func changeRailRect(in rowRect: NSRect, tone: DiffPaneLineTone) -> NSRect? {
        switch tone {
        case .add, .delete:
            return NSRect(x: rowRect.minX, y: rowRect.minY, width: 3, height: rowRect.height)
        default:
            return nil
        }
    }

    deinit {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }
}

final class DiffPaneLeadingClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        var origin = newOrigin
        if enclosingScrollView?.hasHorizontalScroller == false {
            origin.x = 0
        }
        super.scroll(to: origin)
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        var origin = newOrigin
        if enclosingScrollView?.hasHorizontalScroller == false {
            origin.x = 0
        }
        super.setBoundsOrigin(origin)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard enclosingScrollView?.hasHorizontalScroller != false else {
            bounds.origin.x = 0
            return bounds
        }
        guard let documentView else {
            bounds.origin.x = 0
            return bounds
        }

        let maxX = max(documentView.frame.width - bounds.width, 0)
        bounds.origin.x = min(max(bounds.origin.x, 0), maxX)
        return bounds
    }
}

private extension DiffPaneTextDocumentBuilder.LineMetadata {
    func reviewLineAnchor(rowIndex: Int) -> DiffReviewLineAnchor? {
        guard let sourceLine,
              let lineNumber = sourceLine.lineNumber
        else {
            return nil
        }

        let side: DiffReviewInlineFeedbackSide
        switch sourceLine.anchor.side {
        case .old:
            side = .old
        case .new:
            side = .new
        case .paired:
            side = .unknown
        }

        return DiffReviewLineAnchor(
            path: sourceLine.anchor.filePath,
            side: side,
            line: lineNumber,
            endLine: nil,
            rowIndex: rowIndex,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(
                    side: side,
                    line: lineNumber,
                    isChange: sourceLine.kind != .context
                ),
            ],
            selectedText: sourceLine.text
        )
    }
}

extension Array where Element == NSRect {
    func indicesIntersecting(_ rect: NSRect) -> Range<Int> {
        guard !isEmpty, rect.height > 0 else { return 0..<0 }

        let start = lowerBound { $0.maxY > rect.minY }
        let end = lowerBound { $0.minY >= rect.maxY }
        guard start < end else { return 0..<0 }
        return start..<end
    }

    func binarySearchRow(containing point: NSPoint) -> Int? {
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let rect = self[mid]
            if rect.contains(point) {
                return mid
            }
            if point.y < rect.minY {
                high = mid - 1
            } else if point.y > rect.maxY {
                low = mid + 1
            } else {
                return nil
            }
        }
        return nil
    }

    private func lowerBound(where predicate: (NSRect) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
