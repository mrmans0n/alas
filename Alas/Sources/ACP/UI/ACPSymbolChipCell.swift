import AppKit

extension SymbolKind {
    var badgeForeground: NSColor {
        switch self {
        case .class, .interface, .module, .type: NSColor(srgbRed: 0.77, green: 0.65, blue: 1.0, alpha: 1)
        case .struct, .enum: NSColor(srgbRed: 0.61, green: 0.88, blue: 0.54, alpha: 1)
        case .function, .method, .macro: NSColor(srgbRed: 0.36, green: 0.85, blue: 1.0, alpha: 1)
        case .property, .constant: NSColor(srgbRed: 1.0, green: 0.77, blue: 0.42, alpha: 1)
        }
    }

    var badgeBackground: NSColor { badgeForeground.withAlphaComponent(0.2) }

    /// Text color for a name of this kind on the badge: the kind color,
    /// darkened on the light theme so it keeps its contrast.
    var badgeLabelColor: NSColor {
        .appearanceAware(
            dark: badgeForeground,
            light: badgeForeground.blended(withFraction: 0.45, of: .black) ?? badgeForeground
        )
    }
}

/// Code-token symbol badge: kind icon, container in the type color, and name
/// in its kind's color on a dark code-style pill. With code included, an
/// accent edge on the left and a trailing `N lines` segment.
final class ACPSymbolChipCell: NSTextAttachmentCell {
    /// Not `target`: that name is taken by `NSCell.target`.
    let symbol: ACPSymbolReference.Target
    private static let iconSize: CGFloat = 13
    private static let iconFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    private static let countFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    private static let pillFill = NSColor.appearanceAware(
        dark: NSColor.black.withAlphaComponent(0.28), light: NSColor.black.withAlphaComponent(0.05)
    )
    private static let countFill = NSColor.appearanceAware(
        dark: NSColor.white.withAlphaComponent(0.04), light: NSColor.black.withAlphaComponent(0.04)
    )

    init(target: ACPSymbolReference.Target) {
        self.symbol = target
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    private var containerText: String { symbol.container.map { $0 + "." } ?? "" }
    private var nameText: String { symbol.kind.isCallable ? symbol.name + "()" : symbol.name }
    private var countText: String? {
        guard symbol.includeCode else { return nil }
        let count = symbol.lineRange.count
        return count > ACPSymbolReference.maxExcerptLines
            ? "\(ACPSymbolReference.maxExcerptLines)+ lines"
            : "\(count) line\(count == 1 ? "" : "s")"
    }
    /// Width of the accent edge drawn when code is included.
    private var edgeWidth: CGFloat { symbol.includeCode ? 2 : 0 }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func countSegmentWidth(_ text: String) -> CGFloat { 10 + width(text, Self.countFont) }

    /// Everything but the label: accent edge, icon, padding, count segment.
    private var fixedWidth: CGFloat {
        edgeWidth + 4 + Self.iconSize + 5 + 6 + (countText.map(countSegmentWidth) ?? 0)
    }

    override var cellSize: NSSize {
        NSSize(width: fixedWidth + width(containerText + nameText, ACPMentionChipMetrics.labelFont),
               height: ACPMentionChipMetrics.height)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: ACPMentionChipMetrics.baselineOffset) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        // Text layout runs on the main thread; the SDK leaves this override nonisolated.
        let line = floor(lineFrag.width - 2 * textContainer.lineFragmentPadding)
        return MainActor.assumeIsolated {
            // No wider than the line, so a long name can't run past the
            // composer; the label truncates instead (see `draw`). The icon,
            // count segment, and an ellipsis always fit.
            let natural = cellSize
            let minimum = fixedWidth + width("…", ACPMentionChipMetrics.labelFont)
            let capped = line > 0 ? max(minimum, min(natural.width, line)) : natural.width
            return NSRect(origin: NSPoint(x: 0, y: ACPMentionChipMetrics.baselineOffset),
                          size: NSSize(width: capped, height: natural.height))
        }
    }

    override func highlight(_ flag: Bool, withFrame frame: NSRect, in controlView: NSView?) {
        draw(withFrame: frame, in: controlView)
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let accent = NSColor.controlAccentColor
        let pill = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Self.pillFill.setFill()
        pill.fill()

        // Edge and count segment are clipped to the pill's rounded corners.
        NSGraphicsContext.saveGraphicsState()
        pill.addClip()
        if symbol.includeCode {
            accent.setFill()
            NSRect(x: frame.minX, y: frame.minY, width: edgeWidth, height: frame.height).fill()
        }
        if let countText {
            let segment = NSRect(x: frame.maxX - countSegmentWidth(countText), y: frame.minY,
                                 width: countSegmentWidth(countText), height: frame.height)
            Self.countFill.setFill()
            segment.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: segment.minX, y: frame.minY, width: 0.5, height: frame.height).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.countFont, .foregroundColor: NSColor.secondaryLabelColor]
            let size = (countText as NSString).size(withAttributes: attrs)
            (countText as NSString).draw(at: NSPoint(x: segment.minX + 5, y: frame.midY - size.height / 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        (symbol.includeCode ? accent.withAlphaComponent(0.6) : NSColor.separatorColor).setStroke()
        pill.lineWidth = 0.75
        pill.stroke()

        let iconRect = NSRect(x: frame.minX + edgeWidth + 4, y: frame.midY - Self.iconSize / 2,
                              width: Self.iconSize, height: Self.iconSize)
        symbol.kind.badgeBackground.setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: 3, yRadius: 3).fill()
        let letter = symbol.kind.badgeLetter as NSString
        let letterAttrs: [NSAttributedString.Key: Any] = [.font: Self.iconFont, .foregroundColor: symbol.kind.badgeLabelColor]
        let letterSize = letter.size(withAttributes: letterAttrs)
        letter.draw(at: NSPoint(x: iconRect.midX - letterSize.width / 2, y: iconRect.midY - letterSize.height / 2),
                    withAttributes: letterAttrs)

        let labelY = ACPMentionChipMetrics.labelOriginY(in: frame)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let label = NSMutableAttributedString(string: containerText, attributes: [
            .font: ACPMentionChipMetrics.labelFont, .foregroundColor: SymbolKind.class.badgeLabelColor,
            .paragraphStyle: truncating,
        ])
        label.append(NSAttributedString(string: nameText, attributes: [
            .font: ACPMentionChipMetrics.labelFont, .foregroundColor: symbol.kind.badgeLabelColor,
            .paragraphStyle: truncating,
        ]))
        // The label gets what `cellFrame` left after the fixed parts. The
        // truncating line break mode keeps it on one line.
        let labelRect = NSRect(x: iconRect.maxX + 5, y: labelY,
                               width: max(0, frame.width - fixedWidth), height: frame.maxY - labelY)
        label.draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
