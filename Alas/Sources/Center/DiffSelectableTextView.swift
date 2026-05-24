import AppKit
import SwiftUI

struct DiffSelectableTextView: NSViewRepresentable {
    let hunk: ParsedDiff.Hunk
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme

    func makeNSView(context: Context) -> DiffSelectableTextContainerView {
        DiffSelectableTextContainerView()
    }

    func updateNSView(_ nsView: DiffSelectableTextContainerView, context: Context) {
        nsView.update(
            hunk: hunk,
            fileExtension: fileExtension,
            font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
            theme: theme
        )
    }
}

final class DiffSelectableTextContainerView: NSView {
    private static let unwrappedTextContainerWidth: CGFloat = 1_000_000

    private let textView: NSTextView
    private var lineMetadata: [DiffSelectableTextBuilder.LineMetadata] = []
    private var rowRects: [NSRect] = []
    private var measuredTextHeight: CGFloat = 0
    private var theme: Theme?
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    private let gutterWidth: CGFloat = 58
    private let horizontalPadding: CGFloat = 14
    private let verticalInset = CenterTypography.rowVerticalPadding

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        wantsLayer = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(
            width: Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: totalHeight)
    }

    func update(
        hunk: ParsedDiff.Hunk,
        fileExtension: String,
        font: NSFont,
        theme: Theme
    ) {
        self.font = font
        self.theme = theme
        let result = DiffSelectableTextBuilder.build(
            hunk: hunk,
            fileExtension: fileExtension,
            font: font,
            theme: theme
        )
        lineMetadata = result.lines
        textView.textStorage?.setAttributedString(result.attributedString)
        updateMeasuredRowGeometry()
        needsDisplay = true
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let textX = horizontalPadding + gutterWidth + 16
        textView.frame = NSRect(
            x: textX,
            y: verticalInset,
            width: max(0, bounds.width - textX - horizontalPadding),
            height: measuredTextHeight
        )
        textView.textContainer?.containerSize = NSSize(
            width: Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let theme else { return }
        for (index, line) in lineMetadata.enumerated() {
            guard rowRects.indices.contains(index) else { continue }
            let measuredRect = rowRects[index]
            let rect = NSRect(
                x: 0,
                y: verticalInset + measuredRect.minY,
                width: bounds.width,
                height: measuredRect.height
            )
            rowBackgroundColor(for: line.kind, theme: theme).setFill()
            rect.fill()
            drawMarker(line.marker, in: rect, kind: line.kind, theme: theme)
        }
    }

    private var totalHeight: CGFloat {
        guard !lineMetadata.isEmpty else { return 0 }
        return measuredTextHeight + verticalInset * 2
    }

    private func updateMeasuredRowGeometry() {
        guard
            !lineMetadata.isEmpty,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            rowRects = []
            measuredTextHeight = 0
            return
        }

        textContainer.containerSize = NSSize(
            width: Self.unwrappedTextContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var measuredRows: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineFragmentRect, _, _, _, _ in
            measuredRows.append(lineFragmentRect)
        }

        while measuredRows.count < lineMetadata.count {
            measuredRows.append(measuredTrailingRowRect(after: measuredRows, layoutManager: layoutManager))
        }

        rowRects = Array(measuredRows.prefix(lineMetadata.count))
        measuredTextHeight = rowRects.last?.maxY ?? 0
    }

    private func measuredTrailingRowRect(after measuredRows: [NSRect], layoutManager: NSLayoutManager) -> NSRect {
        let extraLineRect = layoutManager.extraLineFragmentRect
        let rowHeight: CGFloat
        let width: CGFloat

        if extraLineRect.height > 0 {
            rowHeight = extraLineRect.height
            width = extraLineRect.width
        } else if let previousRow = measuredRows.last {
            rowHeight = previousRow.height
            width = previousRow.width
        } else {
            rowHeight = layoutManager.defaultLineHeight(for: font)
            width = Self.unwrappedTextContainerWidth
        }

        return NSRect(
            x: 0,
            y: measuredRows.last?.maxY ?? 0,
            width: width,
            height: rowHeight
        )
    }

    private func drawMarker(
        _ marker: String,
        in rowRect: NSRect,
        kind: ParsedDiff.Hunk.Line.Kind,
        theme: Theme
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: markerColor(for: kind, theme: theme),
            .paragraphStyle: paragraph,
        ]
        let markerRect = NSRect(
            x: horizontalPadding,
            y: rowRect.minY,
            width: gutterWidth,
            height: rowRect.height
        )
        (marker as NSString).draw(in: markerRect, withAttributes: attributes)
    }

    private func rowBackgroundColor(for kind: ParsedDiff.Hunk.Line.Kind, theme: Theme) -> NSColor {
        switch kind {
        case .add:
            return NSColor(theme.color("add").opacity(0.10))
        case .delete:
            return NSColor(theme.color("del").opacity(0.10))
        case .context:
            return .clear
        }
    }

    private func markerColor(for kind: ParsedDiff.Hunk.Line.Kind, theme: Theme) -> NSColor {
        switch kind {
        case .add:
            return NSColor(theme.color("add"))
        case .delete:
            return NSColor(theme.color("del"))
        case .context:
            return NSColor(theme.color("fg-faint"))
        }
    }
}
