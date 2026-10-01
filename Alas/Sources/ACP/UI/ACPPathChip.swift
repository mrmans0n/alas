import AppKit
import SwiftUI

private struct ACPAbsolutePathChippingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Turns existing absolute paths in rendered inline markdown into chips.
    /// Set only on user messages of local sessions.
    var acpAbsolutePathChipping: Bool {
        get { self[ACPAbsolutePathChippingKey.self] }
        set { self[ACPAbsolutePathChippingKey.self] = newValue }
    }
}

extension NSAttributedString.Key {
    /// Absolute path carried by a path chip. The chip's visible label is only
    /// the last path component; the path itself is what gets sent and copied.
    static let pathReference = NSAttributedString.Key("alas.acp.pathReference")
}

enum ACPPathChipStyle {
    static let maxLabelWidth: CGFloat = 260

    static func tint(isDirectory: Bool) -> NSColor {
        isDirectory ? .systemBlue : .systemTeal
    }

    static func label(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func size(for label: String) -> NSSize {
        let width = (label as NSString).size(withAttributes: [.font: ACPMentionChipMetrics.labelFont]).width
        return NSSize(
            width: ACPCommandPillStyle.capWidth + min(ceil(width), maxLabelWidth)
                + 2 * ACPCommandPillStyle.nameHorizontalPadding,
            height: ACPMentionChipMetrics.height
        )
    }

    /// Draws into a flipped (y-down) context.
    @MainActor
    static func draw(label: String, isDirectory: Bool, in frame: NSRect) {
        let tint = tint(isDirectory: isDirectory)
        let rect = frame.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let cap = NSRect(x: rect.minX, y: rect.minY, width: ACPCommandPillStyle.capWidth, height: rect.height)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        tint.withAlphaComponent(0.16).setFill()
        rect.fill()
        tint.withAlphaComponent(0.55).setFill()
        cap.fill()
        NSGraphicsContext.restoreGraphicsState()

        tint.withAlphaComponent(0.6).setStroke()
        outline.lineWidth = 0.75
        outline.stroke()

        let symbol = isDirectory ? "folder.fill" : "doc.fill"
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            let side = glyph.size
            glyph.draw(
                in: NSRect(x: cap.midX - side.width / 2, y: cap.midY - side.height / 2,
                           width: side.width, height: side.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
        }

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ACPMentionChipMetrics.labelFont,
            .foregroundColor: tint.chipLabelColor,
            .paragraphStyle: style,
        ]
        let textHeight = (label as NSString).size(withAttributes: attributes).height
        (label as NSString).draw(in: NSRect(
            x: cap.maxX + ACPCommandPillStyle.nameHorizontalPadding,
            y: ACPMentionChipMetrics.labelOriginY(in: frame),
            width: frame.width - cap.width - 2 * ACPCommandPillStyle.nameHorizontalPadding,
            height: textHeight
        ), withAttributes: attributes)
    }
}

final class ACPPathChipAttachment: NSTextAttachment {
    let path: String
    let isDirectory: Bool

    @MainActor
    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        super.init(data: nil, ofType: nil)
        let label = ACPPathChipStyle.label(for: path)
        let size = ACPPathChipStyle.size(for: label)
        let image = NSImage(size: size, flipped: true) { rect in
            MainActor.assumeIsolated {
                ACPPathChipStyle.draw(label: label, isDirectory: isDirectory, in: rect)
            }
            return true
        }
        image.cacheMode = .never
        self.image = image
        bounds = NSRect(
            x: 0,
            y: ACPMentionChipMetrics.baselineOffset,
            width: size.width,
            height: size.height
        )
    }

    required init?(coder: NSCoder) { fatalError() }
}

enum ACPPathChip {
    @MainActor
    static func chip(for match: ACPAbsolutePathDetector.Match, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let chip = NSMutableAttributedString(
            attachment: ACPPathChipAttachment(path: match.path, isDirectory: match.isDirectory)
        )
        var chipAttributes = attributes
        chipAttributes[.attachment] = nil
        chipAttributes[.link] = nil
        chipAttributes[.pathReference] = match.path
        chipAttributes[.toolTip] = match.path
        chip.addAttributes(chipAttributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    /// Replaces each detected path in `storage` with a chip, last to first.
    /// `excluding` lets callers skip code spans and links. Returns how many
    /// were replaced.
    @MainActor
    @discardableResult
    static func chipify(
        _ storage: NSMutableAttributedString,
        precededBy: unichar? = nil,
        followedBy: unichar? = nil,
        probe: ACPAbsolutePathDetector.Probe = ACPAbsolutePathDetector.fileSystemProbe,
        excluding: (NSRange) -> Bool = { _ in false }
    ) -> Int {
        let matches = ACPAbsolutePathDetector
            .matches(in: storage.string, precededBy: precededBy, followedBy: followedBy, probe: probe)
            .filter { !excluding($0.range) }
        for match in matches.reversed() {
            let attributes = storage.attributes(at: match.range.location, effectiveRange: nil)
            storage.replaceCharacters(in: match.range, with: chip(for: match, attributes: attributes))
        }
        return matches.count
    }

    /// The chip under `point` in `textView`, for click handling. Uses
    /// `firstRect` per chip so it works under TextKit 1 and 2.
    @MainActor
    static func hit(at point: NSPoint, in textView: NSTextView) -> ACPPathChipAttachment? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        var found: ACPPathChipAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let attachment = value as? ACPPathChipAttachment,
                  let rect = textView.upstreamReferenceAnchorRect(for: NSRange(location: range.location, length: 1)),
                  rect.insetBy(dx: -1, dy: -1).contains(point)
            else { return }
            found = attachment
            stop.pointee = true
        }
        return found
    }
}
