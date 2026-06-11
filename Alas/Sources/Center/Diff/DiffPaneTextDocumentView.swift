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
        measuredHeight = max(oldPane.documentHeight, newPane.documentHeight)
        oldPane.frame.size.height = measuredHeight
        newPane.frame.size.height = measuredHeight
        dividerView.frame.size.height = measuredHeight
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
}

final class DiffPaneTextScrollView: NSScrollView {
    private static let unwrappedTextContainerWidth: CGFloat = 1_000_000

    private let textView: NSTextView
    private var lineLabels: [String] = []
    private var rowKinds: [DiffDisplayRow.Kind] = []
    private var wraps = false
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var theme: Theme?

    var documentHeight: CGFloat {
        max(measuredTextHeight() + textView.textContainerInset.height * 2, fallbackTextHeight())
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

        textView = NSTextView(frame: .zero, textContainer: container)
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
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
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
        self.wraps = wraps
        self.font = font
        self.theme = theme

        textView.textStorage?.setAttributedString(document.attributedString)
        textView.font = font
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        textView.insertionPointColor = NSColor(theme.color("fg"))

        if let ruler = verticalRulerView as? DiffPaneLineNumberRulerView {
            ruler.update(
                labels: lineLabels,
                rowKinds: rowKinds,
                rowHeight: lineHeight(),
                contentTopInset: textView.textContainerInset.height,
                theme: theme
            )
        }

        needsLayout = true
        invalidateIntrinsicContentSize()
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

final class DiffPaneLineNumberRulerView: NSRulerView {
    private var labels: [String] = []
    private var rowKinds: [DiffDisplayRow.Kind] = []
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
        rowKinds: [DiffDisplayRow.Kind],
        rowHeight: CGFloat,
        contentTopInset: CGFloat,
        theme: Theme
    ) {
        self.labels = labels
        self.rowKinds = rowKinds
        self.rowHeight = rowHeight
        self.contentTopInset = contentTopInset
        self.theme = theme
        updateThickness()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let theme else { return }
        NSColor(theme.color("bg-2")).setFill()
        bounds.fill()

        guard let scrollView, rowHeight > 0, !labels.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let firstRow = max(0, Int(floor((visible.minY - contentTopInset) / rowHeight)))
        let lastRow = min(labels.count - 1, Int(ceil((visible.maxY - contentTopInset) / rowHeight)))
        guard firstRow <= lastRow else { return }

        let textHeight = ("8" as NSString).size(withAttributes: labelAttributes(for: "")).height
        for index in firstRow...lastRow {
            let label = labels[index]
            guard !label.isEmpty else { continue }
            let y = contentTopInset + CGFloat(index) * rowHeight - visible.minY
            let drawRect = NSRect(
                x: 0,
                y: y + max((rowHeight - textHeight) / 2, 0),
                width: ruleThickness - horizontalPadding,
                height: textHeight
            )
            NSString(string: label).draw(in: drawRect, withAttributes: labelAttributes(for: label))
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

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }
}
