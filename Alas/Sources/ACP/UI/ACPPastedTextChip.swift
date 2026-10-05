import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Ordinal of a pasted-text chip. The content lives on the
    /// `ACPPastedTextChipAttachment` in the same run.
    static let pastedTextOrdinal = NSAttributedString.Key("alas.acp.pastedTextOrdinal")
}

/// A large paste shown as one `Pasted text #N · 412 lines` chip. Image-backed
/// rather than cell-backed, like `ACPPathChipAttachment`, so it draws in the
/// TextKit 1 composer and in TextKit 2 transcript paragraphs.
final class ACPPastedTextChipAttachment: NSTextAttachment {
    let ordinal: Int
    let content: String
    let label: String

    @MainActor
    init(ordinal: Int, content: String, label precomputedLabel: String? = nil) {
        let label = precomputedLabel ?? ACPPastedTextPolicy.label(ordinal: ordinal, content: content)
        self.ordinal = ordinal
        self.content = content
        self.label = label
        super.init(data: nil, ofType: nil)
        let size = ACPMentionChipMetrics.cellSize(for: label)
        let image = NSImage(size: size, flipped: true) { rect in
            MainActor.assumeIsolated { ACPPastedTextChip.draw(label: label, in: rect) }
            return true
        }
        image.cacheMode = .never
        self.image = image
        bounds = NSRect(x: 0, y: ACPMentionChipMetrics.baselineOffset, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { fatalError() }
}

enum ACPPastedTextChip {
    /// One chip character carrying `attributes` (minus any attachment or
    /// link) plus `.pastedTextOrdinal`. `label` is passed when the caller
    /// already has it, to skip recounting a large paste's lines.
    @MainActor
    static func attributedChip(
        ordinal: Int,
        content: String,
        label: String?,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let chip = NSMutableAttributedString(
            attachment: ACPPastedTextChipAttachment(ordinal: ordinal, content: content, label: label)
        )
        var chipAttributes = attributes
        chipAttributes[.attachment] = nil
        chipAttributes[.link] = nil
        chipAttributes[.pastedTextOrdinal] = ordinal
        chip.addAttributes(chipAttributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    /// Draws into a flipped (y-down) context, matching the @-mention pill.
    @MainActor
    static func draw(label: String, in frame: NSRect) {
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(0.22).setFill()
        path.fill()
        accent.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 0.75
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ACPMentionChipMetrics.labelFont,
            .foregroundColor: accent.chipLabelColor,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: frame.minX + (frame.width - size.width) / 2, y: ACPMentionChipMetrics.labelOriginY(in: frame)),
            withAttributes: attributes
        )
    }
}
