import AppKit
import SwiftUI

/// NSTextAttachment that renders an `@filename` chip as a rounded pill
/// inside the composer's NSTextView. Tagged with the file URI on its
/// attribute range so submit can pull it back out as an
/// `ACPMessage.Attachment`.
final class ACPMentionChipAttachment: NSTextAttachment {
    let displayName: String
    let uri: String

    @MainActor
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

enum ACPMentionChipMetrics {
    static let height: CGFloat = 18

    static var labelFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
    }

    static func cellSize(for label: String) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        let textSize = (label as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(textSize.width) + 14, height: height)
    }

    static func baselineOffset(for font: NSFont, attachmentHeight: CGFloat) -> CGFloat {
        let letterCenterFromBaseline = (font.ascender + font.descender) / 2
        return letterCenterFromBaseline - attachmentHeight / 2
    }
}

/// Shows the path behind a file mention without covering the composer with a tooltip.
@MainActor
final class ACPFileMentionHoverController {
    private struct Target: Equatable {
        let range: NSRange
        let uri: String
    }

    private var popover: NSPopover?
    private var showWork: DispatchWorkItem?
    private var target: Target?

    func scheduleShow(range: NSRange, attachment: ACPMentionChipAttachment, in textView: ACPNSTextView) {
        let next = Target(range: range, uri: attachment.uri)
        guard target != next else { return }
        hide()
        target = next
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView, self.target == next,
                  let anchor = textView.imageChipAnchorRect(for: range),
                  let url = URL(string: next.uri), url.isFileURL else { return }
            let hosting = NSHostingController(
                rootView: ACPFileMentionHoverCard(name: attachment.displayName, path: url.path)
            )
            hosting.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = hosting
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ACPImageChipHoverController.hoverDelay, execute: work)
    }

    func hide() {
        showWork?.cancel()
        showWork = nil
        target = nil
        popover?.performClose(nil)
        popover = nil
    }
}

private struct ACPFileMentionHoverCard: View {
    let name: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name, systemImage: "doc.text")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }
}
