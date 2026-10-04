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
        NSPoint(x: 0, y: ACPMentionChipMetrics.baselineOffset)
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

        let textColor = accent.chipLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: ACPMentionChipMetrics.labelFont,
            .foregroundColor: textColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let origin = NSPoint(
            x: frame.minX + (frame.width - textSize.width) / 2,
            y: ACPMentionChipMetrics.labelOriginY(in: frame)
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
        return NSRect(
            x: 0,
            y: ACPMentionChipMetrics.baselineOffset,
            width: size.width,
            height: size.height
        )
    }
}

enum ACPMentionChipMetrics {
    static let height: CGFloat = 18

    /// Kept for the process lifetime: string drawing with a fresh font per
    /// call can leave UIFoundation's cached attributes holding a nil font
    /// after an appearance change, which aborts in CoreText.
    nonisolated(unsafe) static let labelFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)

    static func cellSize(for label: String) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        let textSize = (label as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(textSize.width) + 14, height: height)
    }

    /// Distance from a chip's bottom edge up to its label's baseline, with
    /// the label vertically centered in the chip.
    static var labelBaselineInset: CGFloat {
        (height - labelFont.ascender - labelFont.descender) / 2
    }

    /// Where a chip's bottom edge sits relative to the text baseline. Every
    /// chip puts its label on the surrounding text's baseline, so chips line
    /// up with the text and with each other whatever font the line uses.
    static var baselineOffset: CGFloat { -labelBaselineInset }

    /// Top of the label drawn in `frame`, in a flipped (y-down) context.
    static func labelOriginY(in frame: NSRect) -> CGFloat {
        frame.maxY - labelBaselineInset - labelFont.ascender
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
                  let anchor = textView.imageChipAnchorRect(for: range) else { return }
            let url = URL(string: next.uri)
            let isFile = url?.isFileURL == true
            let sessionId = ACPSessionReference.sessionId(fromURI: next.uri)
            let hosting = NSHostingController(
                rootView: ACPFileMentionHoverCard(
                    name: attachment.displayName,
                    location: sessionId.map { "Agent session \($0)" }
                        ?? (isFile ? (url?.path ?? next.uri) : next.uri),
                    systemImage: sessionId != nil ? "bubble.left.and.bubble.right" : isFile ? "doc.text" : "link"
                )
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
    let location: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(location)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }
}
