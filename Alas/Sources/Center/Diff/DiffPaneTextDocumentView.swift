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
    private let oldPane = DiffPaneTextScrollView()
    private let newPane = DiffPaneTextScrollView()
    private let stackedPane = DiffPaneTextScrollView()
    private let dividerView = NSView()

    private var layoutMode: DiffLayoutMode = .split
    private var measuredHeight: CGFloat = 0
    private var lastUpdateSignature: UpdateSignature?

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
        theme: Theme
    ) {
        let signature = UpdateSignature(
            group: group,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            fileExtension: fileExtension,
            fontName: font.fontName,
            fontSize: font.pointSize,
            theme: theme
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
                theme: theme
            )
            newPane.update(
                document: result.newCode,
                lineLabels: lineLabels(from: result.newGutter),
                wraps: wrapLines,
                font: font,
                theme: theme
            )
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
                theme: theme
            )
            measuredHeight = stackedPane.documentHeight
        }

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
    }
}

final class DiffPaneTextScrollView: NSScrollView {
    private static let unwrappedTextContainerWidth: CGFloat = 1_000_000

    private let textView: DiffPaneCodeTextView
    private var lineLabels: [String] = []
    private var rowKinds: [DiffDisplayRow.Kind] = []
    private var lineTones: [DiffPaneLineTone] = []
    private var baseDocument: DiffPaneTextDocumentBuilder.CodeDocument?
    private var synchronizedRowHeights: [CGFloat] = []
    private var wraps = false
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var theme: Theme?

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

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = textView
        hasVerticalRuler = true
        rulersVisible = true
        verticalRulerView = DiffPaneLineNumberRulerView(scrollView: self)

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
        theme: Theme
    ) {
        self.lineLabels = lineLabels
        self.rowKinds = document.lines.map(\.kind)
        self.lineTones = zip(lineLabels, rowKinds).map { label, kind in
            DiffPaneLineTone(label: label, rowKind: kind)
        }
        self.baseDocument = document
        self.synchronizedRowHeights = []
        self.wraps = wraps
        self.font = font
        self.theme = theme

        textView.textStorage?.setAttributedString(document.attributedString)
        textView.font = font
        textView.lineTones = lineTones
        textView.theme = theme
        textView.insertionPointColor = NSColor(theme.color("fg"))

        if let ruler = verticalRulerView as? DiffPaneLineNumberRulerView {
            ruler.update(
                labels: lineLabels,
                lineTones: lineTones,
                rowHeight: lineHeight(),
                contentTopInset: textView.textContainerInset.height,
                theme: theme
            )
        }

        needsLayout = true
        invalidateIntrinsicContentSize()
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
        configureTextContainer()
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: textViewWidth(),
            height: documentHeight
        )
        (verticalRulerView as? DiffPaneLineNumberRulerView)?.rowHeight = lineHeight()
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
        if rowKind == .collapsed {
            self = .collapsed
        } else if label.hasPrefix("+") {
            self = .add
        } else if label.hasPrefix("-") {
            self = .delete
        } else if label.isEmpty, rowKind != .context {
            self = .placeholder
        } else {
            self = .context
        }
    }
}

final class DiffPaneCodeTextView: NSTextView {
    static func placeholderHatchRect(in rowRect: NSRect) -> NSRect {
        rowRect.insetBy(dx: 0, dy: 1)
    }

    var lineTones: [DiffPaneLineTone] = [] {
        didSet { needsDisplay = true }
    }
    var theme: Theme? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawLineBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    func diffRowRects() -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let paragraphRanges = paragraphRanges(lineCount: lineTones.count)
        var nextY = textContainerOrigin.y
        return paragraphRanges.map { range in
            let height = measuredRowHeight(for: range, layoutManager: layoutManager)
            defer { nextY += height }
            return NSRect(
                x: 0,
                y: nextY,
                width: max(bounds.width, visibleRect.width),
                height: height
            )
        }
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
            drawRail(for: tone, rowRect: rowRect, theme: theme)
            if tone == .placeholder {
                drawPlaceholderHatch(in: rowRect, theme: theme)
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

    private func measuredRowHeight(for range: NSRange, layoutManager: NSLayoutManager) -> CGFloat {
        let defaultHeight = layoutManager.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))
        guard range.length > 0 else { return defaultHeight }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return defaultHeight }

        var rowRect = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineFragmentRect, _, _, _, _ in
            rowRect = rowRect.union(lineFragmentRect)
        }
        guard !rowRect.isNull else { return defaultHeight }
        return max(ceil(rowRect.height), defaultHeight)
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

    private func drawRail(for tone: DiffPaneLineTone, rowRect: NSRect, theme: Theme) {
        let color: NSColor?
        switch tone {
        case .add:
            color = NSColor(theme.color("add"))
        case .delete:
            color = NSColor(theme.color("del"))
        default:
            color = nil
        }
        guard let color else { return }
        color.setFill()
        NSRect(x: rowRect.minX, y: rowRect.minY, width: 3, height: rowRect.height).fill()
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
}

final class DiffPaneLineNumberRulerView: NSRulerView {
    private var labels: [String] = []
    private var lineTones: [DiffPaneLineTone] = []
    private var theme: Theme?
    var rowHeight: CGFloat = 16
    private var contentTopInset: CGFloat = 6
    private var boundsObserver: NSObjectProtocol?

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
        theme: Theme
    ) {
        self.labels = labels
        self.lineTones = lineTones
        self.rowHeight = rowHeight
        self.contentTopInset = contentTopInset
        self.theme = theme
        updateThickness()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let theme else { return }
        NSColor(theme.color("bg-0")).setFill()
        bounds.fill()

        guard let scrollView, !labels.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let rowRects = diffRowRects()
        guard !rowRects.isEmpty else { return }

        let textHeight = ("8" as NSString).size(withAttributes: labelAttributes(for: "")).height
        for index in rowRects.indices {
            let label = labels[index]
            let sourceRowRect = rowRects[index]
            guard sourceRowRect.intersects(visible) else { continue }
            let y = sourceRowRect.minY - visible.minY
            let rowRect = NSRect(x: 0, y: y, width: ruleThickness, height: sourceRowRect.height)
            drawRowBackground(index: index, rowRect: rowRect, theme: theme)
            guard !label.isEmpty else { continue }
            let firstVisualLineHeight = min(sourceRowRect.height, rowHeight)
            let drawRect = NSRect(
                x: 0,
                y: y + max((firstVisualLineHeight - textHeight) / 2, 0),
                width: ruleThickness - horizontalPadding,
                height: textHeight
            )
            NSString(string: label).draw(in: drawRect, withAttributes: labelAttributes(for: label))
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

    private func updateThickness() {
        let maxDigits = labels
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "+- ")) }
            .map(\.count)
            .max() ?? 1
        let sample = String(repeating: "8", count: max(maxDigits, 1)) as NSString
        let width = ceil(sample.size(withAttributes: labelAttributes(for: "")).width)
        ruleThickness = max(minimumThickness, width + horizontalPadding * 2)
    }

    private func labelAttributes(for label: String) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let color: NSColor
        if let theme {
            if label.hasPrefix("+") {
                color = NSColor(theme.color("add"))
            } else if label.hasPrefix("-") {
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
        if let railColor {
            railColor.setFill()
            NSRect(x: 0, y: rowRect.minY, width: 3, height: rowRect.height).fill()
        }
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }
}
