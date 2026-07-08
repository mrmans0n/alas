import AppKit
import SwiftUI

private let diffContextExpansionChunkSize = 10

struct DiffReviewLineAnchor: Equatable, Hashable, Sendable {
    let path: String
    let side: DiffReviewInlineFeedbackSide
    let line: Int
    let endLine: Int?
    let rowIndex: Int
    let selectedText: String

    init(
        path: String,
        side: DiffReviewInlineFeedbackSide,
        line: Int,
        endLine: Int? = nil,
        rowIndex: Int,
        selectedText: String
    ) {
        self.path = path
        self.side = side
        self.line = line
        self.endLine = endLine
        self.rowIndex = rowIndex
        self.selectedText = selectedText
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
    var allowsReviewLineSelection: Bool = true
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    var onContextExpansion: (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }

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
        allowsReviewLineSelection: Bool = true,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
        onContextExpansion: @escaping (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
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
        self.allowsReviewLineSelection = allowsReviewLineSelection
        self.onReviewLineSelected = onReviewLineSelected
        self.onContextExpansion = onContextExpansion
    }

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
            theme: theme,
            lspContext: lspContext,
            allowsReviewLineSelection: allowsReviewLineSelection,
            onReviewLineSelected: onReviewLineSelected,
            onContextExpansion: onContextExpansion
        )
    }
}

struct DiffPaneSegmentView: NSViewRepresentable {
    let rows: [DiffDisplayRow]
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme
    let lspContext: DiffPaneLSPContext?
    var allowsReviewLineSelection: Bool = true
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    let onContextExpansion: (DiffContextExpansionKey, DiffContextExpansionMode) -> Void

    func makeNSView(context: Context) -> DiffPaneTextDocumentContainerView {
        DiffPaneTextDocumentContainerView()
    }

    func updateNSView(_ nsView: DiffPaneTextDocumentContainerView, context: Context) {
        nsView.update(
            rows: rows,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            theme: theme,
            lspContext: lspContext,
            allowsReviewLineSelection: allowsReviewLineSelection,
            onReviewLineSelected: onReviewLineSelected,
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

    private let dividerWidth: CGFloat = 1

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

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
        allowsReviewLineSelection: Bool = true,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
        onContextExpansion: @escaping (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
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

        let signature = UpdateSignature(
            group: group,
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
        guard signature != lastUpdateSignature else {
            needsLayout = true
            return
        }
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
        let width = max(bounds.width, 1)
        let paneWidth = floor((width - dividerWidth) / 2)
        oldPane.frame = NSRect(x: 0, y: 0, width: paneWidth, height: max(bounds.height, measuredHeight))
        dividerView.frame = NSRect(x: paneWidth, y: 0, width: dividerWidth, height: max(bounds.height, measuredHeight))
        newPane.frame = NSRect(x: paneWidth + dividerWidth, y: 0, width: width - paneWidth - dividerWidth, height: max(bounds.height, measuredHeight))

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
        layoutMode: DiffLayoutMode,
        wrapLines: Bool,
        showWhitespace: Bool,
        fileExtension: String,
        font: NSFont,
        theme: Theme,
        lspContext: DiffPaneLSPContext?,
        allowsReviewLineSelection: Bool = true,
        onReviewLineSelected: @escaping (DiffReviewLineAnchor) -> Void = { _ in },
        onContextExpansion: @escaping (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
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

        let signature = RowsUpdateSignature(
            rows: rows,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            fontName: font.fontName,
            fontSize: font.pointSize,
            theme: theme,
            lspContext: lspContext.map(UpdateSignature.LSPContextSignature.init)
        )
        guard signature != lastRowsUpdateSignature else {
            needsLayout = true
            return
        }
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
        let group: DiffDisplayGroup
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
        let rows: [DiffDisplayRow]
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

    private let textView: DiffPaneCodeTextView
    private var lineLabels: [String] = []
    private var rowKinds: [DiffDisplayRow.Kind] = []
    private var lineTones: [DiffPaneLineTone] = []
    private var expansionKeys: [DiffContextExpansionKey?] = []
    private var baseDocument: DiffPaneTextDocumentBuilder.CodeDocument?
    private var synchronizedRowHeights: [CGFloat] = []
    private var shouldResetHorizontalOrigin = false
    private var wraps = false
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var theme: Theme?
    var allowsReviewLineSelection: Bool = true {
        didSet {
            (verticalRulerView as? DiffPaneLineNumberRulerView)?.allowsReviewLineSelection = allowsReviewLineSelection
        }
    }
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    var onContextExpansion: (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in } {
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
        hasHorizontalScroller = true
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

    func update(
        document: DiffPaneTextDocumentBuilder.CodeDocument,
        lineLabels: [String],
        wraps: Bool,
        font: NSFont,
        theme: Theme,
        lspContext: DiffPaneLSPContext?,
        allowedLSPSide: DiffLineSide,
        onContextExpansion: @escaping (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
    ) {
        self.lineLabels = lineLabels
        self.rowKinds = document.lines.map(\.kind)
        self.lineTones = document.lines.enumerated().map { index, line in
            line.tone ?? DiffPaneLineTone(
                label: index < lineLabels.count ? lineLabels[index] : "",
                rowKind: line.kind
            )
        }
        self.expansionKeys = document.lines.map(\.expansionKey)
        self.baseDocument = document
        self.synchronizedRowHeights = []
        self.shouldResetHorizontalOrigin = true
        self.wraps = wraps
        self.font = font
        self.theme = theme
        self.onContextExpansion = onContextExpansion
        hasHorizontalScroller = !wraps

        textView.textStorage?.setAttributedString(document.attributedString)
        textView.font = font
        textView.lineMetadata = document.lines
        textView.lineTones = lineTones
        textView.contextExpansionHandler = onContextExpansion
        textView.theme = theme
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
                expansionKeys: expansionKeys,
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
        guard rowHeights.count != synchronizedRowHeights.count
            || zip(rowHeights, synchronizedRowHeights).contains(where: { abs($0.0 - $0.1) > 0.5 })
        else {
            return
        }

        let currentRows = textView.diffRowRects()
        let synchronized = NSMutableAttributedString(attributedString: baseDocument.attributedString)
        for index in 0..<min(rowHeights.count, baseDocument.lines.count, currentRows.count) {
            let targetHeight = rowHeights[index]
            let currentHeight = currentRows[index].height
            guard targetHeight > currentHeight + 0.5 else { continue }

            let range = baseDocument.lines[index].range
            guard range.location < synchronized.length else { continue }
            let paragraphRange = (synchronized.string as NSString).paragraphRange(for: NSRange(
                location: range.location,
                length: max(range.length, 1)
            ))
            let lineCount = max(1, Int(round(currentHeight / max(lineHeight(), 1))))
            let targetLineHeight = targetHeight / CGFloat(lineCount)
            let paragraph = NSMutableParagraphStyle()
            if let existing = synchronized.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle {
                paragraph.setParagraphStyle(existing)
            } else {
                paragraph.setParagraphStyle(CenterTypography.paragraphStyle())
            }
            paragraph.minimumLineHeight = targetLineHeight
            paragraph.maximumLineHeight = targetLineHeight
            synchronized.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
        }

        synchronizedRowHeights = rowHeights
        textView.textStorage?.setAttributedString(synchronized)
        textView.lineTones = lineTones
        textView.theme = theme
        needsLayout = true
        invalidateIntrinsicContentSize()
        (verticalRulerView as? DiffPaneLineNumberRulerView)?.needsDisplay = true
    }

    override func layout() {
        super.layout()
        hasHorizontalScroller = !wraps
        tile()
        configureTextContainer()
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: textViewWidth(),
            height: documentHeight
        )
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
            configureTextContainer()
            textView.frame.size.width = max(clipFrame.width, 1)
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

    private func configureTextContainer() {
        let contentWidth = max(contentView.bounds.width - textView.textContainerInset.width * 2, 1)
        textView.isHorizontallyResizable = !wraps
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: wraps ? contentWidth : Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: wraps ? contentWidth : Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
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

    static func placeholderHatchRect(in rowRect: NSRect) -> NSRect {
        rowRect.insetBy(dx: 0, dy: 1)
    }

    static func changeRailRect(in rowRect: NSRect, tone: DiffPaneLineTone) -> NSRect? {
        nil
    }

    private var ownedTextStorage: NSTextStorage?
    private var customTrackingArea: NSTrackingArea?
    private var lspController: DiffPaneLSPController?
    private var cachedRowGeometry: RowGeometry?
    private var rowGeometryComputationCount = 0
    private var isPointingHandCursor = false

    var rowGeometryComputationCountForTesting: Int {
        rowGeometryComputationCount
    }

    var lineTones: [DiffPaneLineTone] = [] {
        didSet {
            invalidateDiffRowGeometry()
            needsDisplay = true
        }
    }
    var lineMetadata: [DiffPaneTextDocumentBuilder.LineMetadata] = [] {
        didSet { invalidateDiffRowGeometry() }
    }
    var hoverHandler: ((NSPoint) -> Void)?
    var commandClickHandler: ((NSPoint) -> Void)?
    var flagsChangedHandler: ((NSEvent) -> Void)?
    var mouseExitedHandler: (() -> Void)?
    var contextExpansionHandler: (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
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
        if abs(oldSize.width - newSize.width) > 0.5 {
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
        updateCursor(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if invokeExpansion(at: point, optionKey: event.modifierFlags.contains(.option)) {
            return
        }
        if event.modifierFlags.contains(.command), let commandClickHandler {
            commandClickHandler(point)
            return
        }
        super.mouseDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        flagsChangedHandler?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearPointingHandCursor()
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
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
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
            selectedText: resolvedAnchors.map(\.selectedText).joined(separator: "\n")
        )
    }

    func reviewLineAnchor(at point: NSPoint) -> DiffReviewLineAnchor? {
        guard let row = reviewLineRow(at: point) else { return nil }
        return reviewLineAnchor(atRow: row)
    }

    func reviewLineRow(at point: NSPoint) -> Int? {
        let rowRects = diffRowRects()
        return rowRects.firstIndex(where: { $0.contains(point) })
    }

    private func updateCursor(at point: NSPoint) {
        guard let row = reviewLineRow(at: point),
              rowShouldUsePointingHandCursor(row)
        else {
            clearPointingHandCursor()
            return
        }
        setPointingHandCursor()
    }

    private func rowShouldUsePointingHandCursor(_ row: Int) -> Bool {
        guard lineMetadata.indices.contains(row) else { return false }
        let metadata = lineMetadata[row]
        return metadata.expansionKey != nil || metadata.sourceLine != nil
    }

    private func setPointingHandCursor() {
        guard !isPointingHandCursor else { return }
        NSCursor.pointingHand.set()
        isPointingHandCursor = true
    }

    private func clearPointingHandCursor() {
        guard isPointingHandCursor else { return }
        NSCursor.arrow.set()
        isPointingHandCursor = false
    }

    func invokeExpansionForTesting(row: Int, optionKey: Bool) {
        guard let key = expansionKey(atRow: row) else { return }
        invokeExpansion(key: key, optionKey: optionKey)
    }

    private func invokeExpansion(at point: NSPoint, optionKey: Bool) -> Bool {
        let rowRects = diffRowRects()
        guard let row = rowRects.firstIndex(where: { $0.contains(point) }),
              let key = expansionKey(atRow: row)
        else {
            return false
        }
        invokeExpansion(key: key, optionKey: optionKey)
        return true
    }

    private func expansionKey(atRow row: Int) -> DiffContextExpansionKey? {
        guard lineMetadata.indices.contains(row) else { return nil }
        return lineMetadata[row].expansionKey
    }

    private func invokeExpansion(key: DiffContextExpansionKey, optionKey: Bool) {
        let mode: DiffContextExpansionMode = optionKey ? .all : .chunk(size: diffContextExpansionChunkSize)
        contextExpansionHandler(key, mode)
    }

    private func drawLineBackgrounds(in dirtyRect: NSRect) {
        guard let theme else { return }
        let rowRects = diffRowRects()
        for (index, rowRect) in rowRects.enumerated() {
            guard lineTones.indices.contains(index) else { continue }
            let tone = lineTones[index]
            guard tone != .context else { continue }
            guard rowRect.intersects(dirtyRect) else { continue }

            rowFill(for: tone, theme: theme).setFill()
            rowRect.fill()
            if tone == .placeholder {
                drawPlaceholderHatch(in: rowRect, theme: theme)
            } else if lineMetadata.indices.contains(index), lineMetadata[index].kind == .expandableContext {
                drawExpandableContextPill(row: index, in: rowRect, theme: theme)
            }
        }
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
        guard lineMetadata.indices.contains(row),
              let layoutManager,
              let textContainer
        else {
            return
        }

        let range = lineMetadata[row].range
        guard range.length > 0 else { return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }

        let textRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard !textRect.isEmpty else { return }

        let pillHeight = min(max(textRect.height + 6, 18), max(rowRect.height - 4, 1))
        let pillRect = NSRect(
            x: textRect.minX - 10,
            y: rowRect.midY - pillHeight / 2,
            width: textRect.width + 20,
            height: pillHeight
        )
        let path = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
        NSColor(theme.color("bg-1")).withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor(theme.color("line")).withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class DiffPaneLineNumberRulerView: NSRulerView {
    private var labels: [String] = []
    private var lineTones: [DiffPaneLineTone] = []
    private var expansionKeys: [DiffContextExpansionKey?] = []
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
    var onContextExpansion: (DiffContextExpansionKey, DiffContextExpansionMode) -> Void = { _, _ in }
    private var contentTopInset: CGFloat = 6
    private var boundsObserver: NSObjectProtocol?
    private var selectionStartRow: Int?
    private var selectionCurrentRow: Int?

    private let minimumThickness: CGFloat = 42
    private let horizontalPadding: CGFloat = 8

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = minimumThickness
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
        expansionKeys: [DiffContextExpansionKey?],
        onContextExpansion: @escaping (DiffContextExpansionKey, DiffContextExpansionMode) -> Void
    ) {
        self.labels = labels
        self.lineTones = lineTones
        self.rowHeight = rowHeight
        self.contentTopInset = contentTopInset
        self.theme = theme
        self.expansionKeys = expansionKeys
        self.onContextExpansion = onContextExpansion
        updateThickness()
        needsDisplay = true
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
        let rowRects = diffRowRects()
        guard !rowRects.isEmpty else { return }

        let textHeight = ("8" as NSString).size(withAttributes: labelAttributes(for: "", row: nil)).height
        let labelRects = labelDrawRects()
        for index in visibleRowIndices(in: visible) {
            let label = labels[index]
            let sourceRowRect = rowRects[index]
            let y = sourceRowRect.minY - visible.minY
            let rowRect = NSRect(x: 0, y: y, width: ruleThickness, height: sourceRowRect.height)
            drawRowBackground(index: index, rowRect: rowRect, theme: theme)
            guard !label.isEmpty else { continue }
            let sourceLabelRect = labelRects.indices.contains(index)
                ? labelRects[index]
                : NSRect(x: 0, y: sourceRowRect.minY, width: ruleThickness - horizontalPadding, height: textHeight)
            let drawRect = NSRect(
                x: sourceLabelRect.minX,
                y: sourceLabelRect.minY - visible.minY,
                width: ruleThickness - horizontalPadding,
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
        let rowRects = diffRowRects()
        return rowRects.indices.filter { index in
            let rowRect = rowRects[index]
            return rowRect.maxY >= visibleRect.minY && rowRect.minY <= visibleRect.maxY
        }
    }

    func labelDrawRects() -> [NSRect] {
        let textHeight = ("8" as NSString).size(withAttributes: labelAttributes(for: "", row: nil)).height
        let textLineRects: [NSRect]
        if let textView = scrollView?.documentView as? DiffPaneCodeTextView {
            textLineRects = textView.diffFirstLineFragmentRects()
        } else {
            textLineRects = diffRowRects().map {
                NSRect(x: 0, y: $0.minY, width: $0.width, height: min($0.height, rowHeight))
            }
        }

        return labels.indices.map { index in
            let lineRect = textLineRects.indices.contains(index)
                ? textLineRects[index]
                : NSRect(x: 0, y: contentTopInset + CGFloat(index) * rowHeight, width: ruleThickness, height: rowHeight)
            return NSRect(
                x: 0,
                y: lineRect.midY - textHeight / 2,
                width: ruleThickness - horizontalPadding,
                height: textHeight
            )
        }
    }

    func diffRowRects() -> [NSRect] {
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
        diffRowRects().firstIndex { $0.contains(point) }
    }

    private func invokeExpansion(row: Int, optionKey: Bool) -> Bool {
        guard expansionKeys.indices.contains(row),
              let key = expansionKeys[row]
        else {
            return false
        }

        let mode: DiffContextExpansionMode = optionKey ? .all : .chunk(size: diffContextExpansionChunkSize)
        onContextExpansion(key, mode)
        return true
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
        let rowRects = diffRowRects()
        guard let row = rowRects.firstIndex(where: { $0.contains(sourcePoint) }),
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
        let maxDigits = labels
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+- ")) }
            .map(\.count)
            .max() ?? 1
        let sample = String(repeating: "8", count: max(maxDigits, 1)) as NSString
        let width = ceil(sample.size(withAttributes: labelAttributes(for: "", row: nil)).width)
        ruleThickness = max(minimumThickness, width + horizontalPadding * 2)
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
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
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
            selectedText: sourceLine.text
        )
    }
}
