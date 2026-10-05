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

    /// The chip under `point` (view coordinates) in `textView`. Uses each
    /// chip's `firstRect`, which works under TextKit 1 and 2, like
    /// `ACPPathChip.hit`.
    @MainActor
    static func hit(at point: NSPoint, in textView: NSTextView) -> (range: NSRange, attachment: ACPPastedTextChipAttachment)? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        var found: (range: NSRange, attachment: ACPPastedTextChipAttachment)?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let attachment = value as? ACPPastedTextChipAttachment else { return }
            let chipRange = NSRange(location: range.location, length: 1)
            guard let rect = textView.upstreamReferenceAnchorRect(for: chipRange),
                  rect.insetBy(dx: -1, dy: -1).contains(point)
            else { return }
            found = (chipRange, attachment)
            stop.pointee = true
        }
        return found
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

private struct ACPPastedTextContentsKey: EnvironmentKey {
    static let defaultValue: ACPPastedTextContents? = nil
}

extension EnvironmentValues {
    /// The content behind pasted-text markers in a rendered user message.
    /// Set by `ACPUserMessageText` and the queue row; nil everywhere else.
    var acpPastedTextContents: ACPPastedTextContents? {
        get { self[ACPPastedTextContentsKey.self] }
        set { self[ACPPastedTextContentsKey.self] = newValue }
    }
}

extension ACPPastedTextChip {
    /// Stands in for a pasted span in user-message markdown. Private-use
    /// delimiters can't be typed, and inside a code block, where nothing is
    /// chipped, the label still reads correctly.
    static func marker(label: String) -> String {
        "\u{E000}\(label)\u{E001}"
    }

    /// The `N` in a label built by `ACPPastedTextPolicy.label`.
    static func ordinal(inLabel label: String) -> Int? {
        guard let hash = label.firstIndex(of: "#") else { return nil }
        return Int(label[label.index(after: hash)...].prefix(while: \.isNumber))
    }

    /// Replaces each marker in rendered text with a chip whose content comes
    /// from `contents`, last to first. Markers in an excluded range (inline
    /// code, links) or with an unknown ordinal stay as text. Run before path
    /// and reference chipping, so the `#N` in a label is never read as an
    /// issue reference. Returns how many markers became chips.
    @MainActor
    @discardableResult
    static func chipify(
        _ storage: NSMutableAttributedString,
        contents: ACPPastedTextContents,
        excluding: (NSRange) -> Bool = { _ in false }
    ) -> Int {
        let source = storage.string as NSString
        var matches: [(range: NSRange, ordinal: Int, label: String)] = []
        var searchStart = 0
        while searchStart < source.length {
            let open = source.range(of: "\u{E000}", options: .literal,
                                    range: NSRange(location: searchStart, length: source.length - searchStart))
            guard open.location != NSNotFound else { break }
            let labelStart = NSMaxRange(open)
            let close = source.range(of: "\u{E001}", options: .literal,
                                     range: NSRange(location: labelStart, length: source.length - labelStart))
            guard close.location != NSNotFound else { break }
            let range = NSRange(location: open.location, length: NSMaxRange(close) - open.location)
            let label = source.substring(with: NSRange(location: labelStart, length: close.location - labelStart))
            if let ordinal = ordinal(inLabel: label), !excluding(range) {
                matches.append((range, ordinal, label))
            }
            searchStart = NSMaxRange(close)
        }
        var replaced = 0
        for match in matches.reversed() {
            guard let content = contents.content(ordinal: match.ordinal) else { continue }
            let attributes = storage.attributes(at: match.range.location, effectiveRange: nil)
            storage.replaceCharacters(in: match.range, with: attributedChip(
                ordinal: match.ordinal, content: content, label: match.label, attributes: attributes
            ))
            replaced += 1
        }
        return replaced
    }
}
