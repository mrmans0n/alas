import AppKit

/// NSTextAttachment that renders an `@filename` chip as a rounded pill
/// inside the composer's NSTextView. Tagged with the file URI on its
/// attribute range so submit can pull it back out as an
/// `ACPMessage.Attachment`.
final class ACPMentionChipAttachment: NSTextAttachment {
    let displayName: String
    let uri: String

    init(displayName: String, uri: String) {
        self.displayName = displayName
        self.uri = uri
        super.init(data: nil, ofType: nil)
        let cell = ACPMentionChipCell(displayName: displayName)
        self.attachmentCell = cell
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// NSTextAttachmentCell subclass that draws the @-mention pill.
private final class ACPMentionChipCell: NSTextAttachmentCell {
    let displayName: String
    private let label: String

    init(displayName: String) {
        self.displayName = displayName
        self.label = "@" + displayName
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    override var cellSize: NSSize {
        ACPMentionChipMetrics.cellSize(for: label)
    }

    override func cellBaselineOffset() -> NSPoint {
        let size = ACPMentionChipMetrics.cellSize(for: label)
        return NSPoint(
            x: 0,
            y: ACPMentionChipMetrics.baselineOffset(
                for: NSFont.systemFont(ofSize: 13),
                attachmentHeight: size.height
            )
        )
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 5, yRadius: 5)
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(0.22).setFill()
        path.fill()
        accent.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let textColor = accent.blended(withFraction: 0.55, of: .white) ?? .white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: ACPMentionChipMetrics.labelFont,
            .foregroundColor: textColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let origin = NSPoint(
            x: frame.minX + (frame.width - textSize.width) / 2,
            y: frame.minY + (frame.height - textSize.height) / 2
        )
        (label as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func highlight(_ flag: Bool, withFrame frame: NSRect, in controlView: NSView?) {
        draw(withFrame: frame, in: controlView)
    }

    override func cellFrame(for textContainer: NSTextContainer,
                            proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        let size = ACPMentionChipMetrics.cellSize(for: label)
        let font = textContainer.layoutManager?.textStorage?.attribute(
            .font,
            at: charIndex,
            effectiveRange: nil
        ) as? NSFont ?? NSFont.systemFont(ofSize: 13)
        return NSRect(
            x: 0,
            y: ACPMentionChipMetrics.baselineOffset(for: font, attachmentHeight: size.height),
            width: size.width,
            height: size.height
        )
    }
}

private enum ACPMentionChipMetrics {
    static var labelFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
    }

    static func cellSize(for label: String) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        let textSize = (label as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(textSize.width) + 14, height: 18)
    }

    static func baselineOffset(for font: NSFont, attachmentHeight: CGFloat) -> CGFloat {
        let letterCenterFromBaseline = (font.ascender + font.descender) / 2
        return letterCenterFromBaseline - attachmentHeight / 2
    }
}
