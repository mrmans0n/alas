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
    private let textView: NSTextView
    private var lineMetadata: [DiffSelectableTextBuilder.LineMetadata] = []
    private var theme: Theme?
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    private let gutterWidth: CGFloat = 58
    private let horizontalPadding: CGFloat = 14
    private let rowVerticalPadding = CenterTypography.rowVerticalPadding

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 10, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
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
        needsDisplay = true
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let textX = horizontalPadding + gutterWidth + 16
        textView.frame = NSRect(
            x: textX,
            y: rowVerticalPadding,
            width: max(0, bounds.width - textX - horizontalPadding),
            height: max(0, totalHeight - rowVerticalPadding * 2)
        )
        textView.textContainer?.containerSize = NSSize(
            width: textView.bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let theme else { return }
        for (index, line) in lineMetadata.enumerated() {
            let rect = NSRect(
                x: 0,
                y: CGFloat(index) * rowHeight,
                width: bounds.width,
                height: rowHeight
            )
            rowBackgroundColor(for: line.kind, theme: theme).setFill()
            rect.fill()
            drawMarker(line.marker, in: rect, kind: line.kind, theme: theme)
        }
    }

    private var lineHeight: CGFloat {
        (font.ascender - font.descender + font.leading) * CenterTypography.lineHeightMultiple
    }

    private var rowHeight: CGFloat {
        ceil(lineHeight + rowVerticalPadding * 2)
    }

    private var totalHeight: CGFloat {
        guard !lineMetadata.isEmpty else { return 0 }
        return CGFloat(lineMetadata.count) * rowHeight
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
            y: rowRect.minY + rowVerticalPadding,
            width: gutterWidth,
            height: lineHeight
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
