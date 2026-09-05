import AppKit

/// Visual treatment for a fenced code block in an editable surface. Values
/// mirror the transcript's rendered code block (`ACPMarkdownText.swift:574-576`)
/// so an in-progress box and the block it becomes once sent look the same.
struct MarkdownCodeBlockStyle: Equatable {
    var baseFont: NSFont
    var baseColor: NSColor
    var monoFont: NSFont
    var bodyColor: NSColor
    var fenceColor: NSColor
    var backgroundColor: NSColor
    var borderColor: NSColor
    var cornerRadius: CGFloat = 6
    var borderWidth: CGFloat = 0.5
}

/// Applies fenced-code-block attributes to an `NSTextStorage`. The markers stay
/// literal in the storage — only attributes change — so the surface's plain-text
/// binding keeps carrying valid markdown.
///
/// This resets its target range to the style's base attributes before applying
/// block attributes, so in the composer it must run BEFORE `ACPMarkdownLiveStyler`,
/// which is given the returned block ranges as an exclusion list.
enum MarkdownCodeBlockStyler {
    @discardableResult
    static func restyle(
        _ storage: NSTextStorage,
        in requestedRange: NSRange?,
        style: MarkdownCodeBlockStyle
    ) -> [FencedBlock] {
        let blocks = MarkdownFenceEditing.blocks(in: storage.string)
        guard storage.length > 0 else { return blocks }

        let full = NSRange(location: 0, length: storage.length)
        let target = requestedRange.map { NSIntersectionRange($0, full) } ?? full
        guard target.length > 0 else { return blocks }

        storage.beginEditing()
        defer { storage.endEditing() }

        // Preserve mention and image chips — their `.attachment` cell would be
        // stripped by a blanket `setAttributes`.
        storage.enumerateAttributes(in: target) { attrs, range, _ in
            if attrs[.attachmentURI] == nil, attrs[.imageAttachmentURI] == nil {
                storage.setAttributes([
                    .font: style.baseFont,
                    .foregroundColor: style.baseColor,
                ], range: range)
            }
        }

        let fenceAttributes: [NSAttributedString.Key: Any] = [
            .font: style.monoFont,
            .foregroundColor: style.fenceColor,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: style.monoFont,
            .foregroundColor: style.bodyColor,
        ]

        for block in blocks {
            apply(fenceAttributes, to: block.openFenceRange, clippedTo: target, in: storage)
            if let closeFenceRange = block.closeFenceRange {
                apply(fenceAttributes, to: closeFenceRange, clippedTo: target, in: storage)
            }
            apply(bodyAttributes, to: block.bodyRange, clippedTo: target, in: storage)
        }

        return blocks
    }

    private static func apply(
        _ attributes: [NSAttributedString.Key: Any],
        to range: NSRange,
        clippedTo target: NSRange,
        in storage: NSTextStorage
    ) {
        let clipped = NSIntersectionRange(range, target)
        guard clipped.length > 0 else { return }
        storage.enumerateAttributes(in: clipped) { attrs, subrange, _ in
            guard attrs[.attachmentURI] == nil, attrs[.imageAttachmentURI] == nil else { return }
            storage.addAttributes(attributes, range: subrange)
        }
    }
}
