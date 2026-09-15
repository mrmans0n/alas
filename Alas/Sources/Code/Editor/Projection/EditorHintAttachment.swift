import AppKit

final class EditorHintAttachment: NSTextAttachment {
    let hint: EditorDisplayHint
    @MainActor
    init(hint: EditorDisplayHint) {
        self.hint = hint
        super.init(data: nil, ofType: nil)
        attachmentCell = EditorHintAttachmentCell(hint: hint)
    }
    // Display projections are rebuilt from source and are never decoded.
    required init?(coder: NSCoder) { return nil }
}

private final class EditorHintAttachmentCell: NSTextAttachmentCell {
    private let hintSize: CGSize
    private var parts: [EditorDisplayHint.Part] = []

    init(hint: EditorDisplayHint) {
        hintSize = hint.size
        parts = hint.parts
        super.init(textCell: hint.label)
        font = .monospacedSystemFont(ofSize: hint.fontSize, weight: .regular)
        attributedStringValue = NSAttributedString(string: hint.label, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: hint.fontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        lineBreakMode = .byTruncatingTail
    }

    required init(coder: NSCoder) {
        // The owning attachment refuses decoding; satisfy NSCell's nonfailable
        // initializer without trapping if a cell is decoded independently.
        hintSize = .zero
        super.init(coder: coder)
    }

    override func cellSize() -> NSSize { hintSize }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard !parts.isEmpty else { super.draw(withFrame: cellFrame, in: controlView)
        return }
        for part in parts {
            (part.label as NSString).draw(in: part.rect.offsetBy(dx: cellFrame.minX, dy: cellFrame.minY), withAttributes: [
                .font: font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
    }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -3) }
}
