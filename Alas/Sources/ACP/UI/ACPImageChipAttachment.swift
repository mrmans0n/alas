import AppKit

/// NSTextAttachment that renders a small image thumbnail inline in the
/// composer's NSTextView. Holds the staged file URL + MIME so submit and
/// draft serialization can recover it (tagged on its attribute range via
/// `.imageAttachmentURI` / `.imageAttachmentMime`).
final class ACPImageChipAttachment: NSTextAttachment {
    let fileURL: URL
    let mimeType: String

    init(fileURL: URL, mimeType: String) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        super.init(data: nil, ofType: nil)
        self.attachmentCell = ACPImageChipCell(thumbnail: NSImage(contentsOf: fileURL))
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class ACPImageChipCell: NSTextAttachmentCell {
    private let thumbnail: NSImage?
    private static let side: CGFloat = 20
    private static let fallbackFont = NSFont.systemFont(ofSize: 13)

    init(thumbnail: NSImage?) {
        self.thumbnail = thumbnail
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    override var cellSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: Self.baselineOffset(for: Self.fallbackFont, attachmentHeight: cellSize.height))
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let rect = frame.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        path.addClip()
        if let thumbnail {
            thumbnail.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor.darkGray.setFill()
            rect.fill()
        }
        path.lineWidth = 0.75
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }

    override func highlight(_ flag: Bool, withFrame frame: NSRect, in controlView: NSView?) {
        draw(withFrame: frame, in: controlView)
    }

    override func cellFrame(for textContainer: NSTextContainer,
                            proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        let size = cellSize
        let font = textContainer.layoutManager?.textStorage?.attribute(
            .font,
            at: charIndex,
            effectiveRange: nil
        ) as? NSFont ?? Self.fallbackFont
        return NSRect(
            x: 0,
            y: Self.baselineOffset(for: font, attachmentHeight: size.height),
            width: size.width,
            height: size.height
        )
    }

    private static func baselineOffset(for font: NSFont, attachmentHeight: CGFloat) -> CGFloat {
        let letterCenterFromBaseline = (font.ascender + font.descender) / 2
        return letterCenterFromBaseline - attachmentHeight / 2
    }
}
