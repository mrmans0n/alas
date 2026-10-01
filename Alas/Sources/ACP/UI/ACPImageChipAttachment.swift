import AppKit

/// NSTextAttachment that renders a small image thumbnail inline in the
/// composer's NSTextView. Holds the staged file URL + MIME so submit and
/// draft serialization can recover it (tagged on its attribute range via
/// `.imageAttachmentURI` / `.imageAttachmentMime`).
final class ACPImageChipAttachment: NSTextAttachment {
    let fileURL: URL
    let mimeType: String

    @MainActor
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

    init(thumbnail: NSImage?) {
        self.thumbnail = thumbnail
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    override var cellSize: NSSize {
        ACPImageChipMetrics.cellSize(for: nil)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: ACPImageChipMetrics.baselineOffset)
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
        let size = ACPImageChipMetrics.cellSize(for: nil)
        return NSRect(
            x: 0,
            y: ACPImageChipMetrics.baselineOffset,
            width: size.width,
            height: size.height
        )
    }
}

/// Pure geometry for the image chip cell, kept nonisolated so TextKit's
/// off-main layout pass can call it from the nonisolated
/// `NSTextAttachmentCellProtocol` witnesses (`cellBaselineOffset()`,
/// `cellFrame(for:proposedLineFragment:glyphPosition:characterIndex:)`)
/// without crossing back into the main-actor `NSCell` API.
private enum ACPImageChipMetrics {
    static let side: CGFloat = 20

    static func cellSize(for font: NSFont?) -> NSSize {
        NSSize(width: side, height: side)
    }

    /// Shares its vertical center with the label chips, so a thumbnail
    /// lines up with the mention and command chips beside it.
    static var baselineOffset: CGFloat {
        ACPMentionChipMetrics.baselineOffset - (side - ACPMentionChipMetrics.height) / 2
    }
}
