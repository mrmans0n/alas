import AppKit

@MainActor
protocol MermaidTextAttachmentCellDelegate: AnyObject {
    func mermaidTextAttachmentCellDidToggleSource(_ cell: MermaidTextAttachmentCell)
    func mermaidTextAttachmentCellDidRequestCopy(_ cell: MermaidTextAttachmentCell)
    func mermaidTextAttachmentCellDidRequestExpansion(_ cell: MermaidTextAttachmentCell)
}

@MainActor
final class MermaidTextAttachment: NSTextAttachment {
    let id: String
    let source: String
    let profile: MermaidPresentationProfile
    let mermaidCell: MermaidTextAttachmentCell

    init(id: String, source: String, profile: MermaidPresentationProfile) {
        self.id = id
        self.source = source
        self.profile = profile
        self.mermaidCell = MermaidTextAttachmentCell(
            id: id,
            source: source,
            profile: profile
        )
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
        attachmentCell = mermaidCell
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MermaidTextAttachmentCell: NSTextAttachmentCell {
    struct LayoutFrames {
        let header: NSRect?
        let body: NSRect
        let sourceButton: NSRect
        let copyButton: NSRect
        let expandButton: NSRect
    }

    struct FailureTextFrames {
        let title: NSRect
        let diagnostic: NSRect
    }

    let id: String
    let source: String
    nonisolated let profile: MermaidPresentationProfile
    weak var delegate: MermaidTextAttachmentCellDelegate?

    private(set) var outcome: MermaidRenderOutcome?
    private(set) var showsSource = false
    private var theme: MermaidDiagramTheme?
    nonisolated(unsafe) private var measuredWidth: CGFloat = 600
    nonisolated(unsafe) private var sizingState: SizingState = .loading

    nonisolated private static let horizontalPadding: CGFloat = 12
    nonisolated private static let headerHeight: CGFloat = 31
    nonisolated private static let fallbackWidth: CGFloat = 600

    private enum SizingState: Sendable {
        case loading
        case rendered(CGSize)
        case failed
    }

    init(id: String, source: String, profile: MermaidPresentationProfile) {
        self.id = id
        self.source = source
        self.profile = profile
        super.init(textCell: "")
        if profile == .compact {
            configureCompactMenu()
        }
        setAccessibilityLabel("Mermaid diagram")
        setAccessibilityValue(source)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(theme: MermaidDiagramTheme) {
        self.theme = theme
    }

    func beginLoading() {
        outcome = nil
        sizingState = .loading
    }

    func apply(_ outcome: MermaidRenderOutcome) {
        self.outcome = outcome
        switch outcome {
        case .rendered(let diagram):
            sizingState = .rendered(diagram.image.size)
        case .failed:
            sizingState = .failed
        }
    }

    func setSourceVisible(_ visible: Bool) {
        showsSource = visible
        updateCompactMenu()
    }

    private func configureCompactMenu() {
        let menu = NSMenu()
        let toggleSource = NSMenuItem(
            title: "Show Mermaid source",
            action: #selector(toggleSourceFromMenu(_:)),
            keyEquivalent: ""
        )
        toggleSource.target = self
        menu.addItem(toggleSource)

        let copySource = NSMenuItem(
            title: "Copy Mermaid source",
            action: #selector(copySourceFromMenu(_:)),
            keyEquivalent: ""
        )
        copySource.target = self
        menu.addItem(copySource)
        self.menu = menu
    }

    private func updateCompactMenu() {
        guard profile == .compact, let toggleSource = menu?.items.first else {
            return
        }
        toggleSource.title = showsSource
            ? "Show Mermaid diagram"
            : "Show Mermaid source"
    }

    @objc private func toggleSourceFromMenu(_ sender: NSMenuItem) {
        delegate?.mermaidTextAttachmentCellDidToggleSource(self)
    }

    @objc private func copySourceFromMenu(_ sender: NSMenuItem) {
        delegate?.mermaidTextAttachmentCellDidRequestCopy(self)
    }

    override var cellSize: NSSize {
        size(for: measuredWidth)
    }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFragment: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let proposedWidth = lineFragment.width
        let usableWidth: CGFloat
        if proposedWidth.isFinite, proposedWidth > 0 {
            usableWidth = proposedWidth
        } else {
            usableWidth = Self.fallbackWidth
        }
        measuredWidth = usableWidth
        return NSRect(origin: .zero, size: size(for: usableWidth))
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let colors = DrawingColors(theme: theme)
        let layout = layoutFrames(in: frame)
        let cardPath = NSBezierPath(
            roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 6,
            yRadius: 6
        )
        colors.background.setFill()
        cardPath.fill()
        colors.border.setStroke()
        cardPath.lineWidth = 0.75
        cardPath.stroke()

        if let header = layout.header {
            colors.surface.setFill()
            header.fill()
            colors.border.setFill()
            NSRect(
                x: header.minX,
                y: header.maxY - 0.5,
                width: header.width,
                height: 0.5
            ).fill()
            drawHeader(
                in: header,
                sourceButton: layout.sourceButton,
                copyButton: layout.copyButton,
                expandButton: layout.expandButton,
                colors: colors
            )
        }
        drawBody(in: layout.body, colors: colors)
    }

    override func highlight(
        _ flag: Bool,
        withFrame frame: NSRect,
        in controlView: NSView?
    ) {
        draw(withFrame: frame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool {
        true
    }

    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard event.type == .leftMouseDown, let controlView else { return false }
        let point = controlView.convert(event.locationInWindow, from: nil)
        if profile == .compact {
            delegate?.mermaidTextAttachmentCellDidRequestExpansion(self)
            return true
        }

        let layout = layoutFrames(in: cellFrame)
        if layout.sourceButton.contains(point) {
            delegate?.mermaidTextAttachmentCellDidToggleSource(self)
        } else if layout.copyButton.contains(point) {
            delegate?.mermaidTextAttachmentCellDidRequestCopy(self)
        } else if layout.expandButton.contains(point) {
            delegate?.mermaidTextAttachmentCellDidRequestExpansion(self)
        } else {
            return false
        }
        return true
    }

    private nonisolated func size(for width: CGFloat) -> NSSize {
        let bodyWidth = max(1, width - Self.horizontalPadding * 2)
        let bodyHeight: CGFloat
        switch sizingState {
        case .rendered(let imageSize):
            if profile == .compact {
                bodyHeight = profile.maxEmbeddedHeight
            } else {
                let fitted = MermaidDiagramLayout.fittedSize(
                    intrinsic: imageSize,
                    availableWidth: bodyWidth,
                    maxHeight: profile.maxEmbeddedHeight
                )
                bodyHeight = max(44, fitted.height + Self.horizontalPadding * 2)
            }
        case .failed:
            bodyHeight = profile == .compact ? profile.maxEmbeddedHeight : 76
        case .loading:
            bodyHeight = profile == .compact ? profile.maxEmbeddedHeight : 120
        }
        let headerHeight = profile == .compact ? 0 : Self.headerHeight
        return NSSize(width: width, height: headerHeight + bodyHeight + 2)
    }

    func layoutFrames(in frame: NSRect) -> LayoutFrames {
        guard profile != .compact else {
            return LayoutFrames(
                header: nil,
                body: frame.insetBy(dx: 1, dy: 1),
                sourceButton: .zero,
                copyButton: .zero,
                expandButton: .zero
            )
        }

        let header = NSRect(
            x: frame.minX + 1,
            y: frame.minY + 1,
            width: max(0, frame.width - 2),
            height: min(Self.headerHeight, max(0, frame.height - 2))
        )
        let body = NSRect(
            x: frame.minX + 1,
            y: header.maxY,
            width: max(0, frame.width - 2),
            height: max(0, frame.maxY - header.maxY - 1)
        )
        let buttons = buttonFrames(in: frame)
        return LayoutFrames(
            header: header,
            body: body,
            sourceButton: buttons.source,
            copyButton: buttons.copy,
            expandButton: buttons.expand
        )
    }

    private func drawHeader(
        in frame: NSRect,
        sourceButton: NSRect,
        copyButton: NSRect,
        expandButton: NSRect,
        colors: DrawingColors
    ) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: colors.muted
        ]
        let label = "MERMAID" as NSString
        let labelSize = label.size(withAttributes: labelAttributes)
        label.draw(
            at: NSPoint(
                x: frame.minX + 10,
                y: frame.midY - labelSize.height / 2
            ),
            withAttributes: labelAttributes
        )

        drawButton(
            showsSource ? "Hide source" : "Show source",
            in: sourceButton,
            color: colors.muted
        )
        drawButton("Copy", in: copyButton, color: colors.muted)
        drawButton("Expand", in: expandButton, color: colors.muted)
    }

    private func drawButton(_ title: String, in frame: NSRect, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func drawBody(in frame: NSRect, colors: DrawingColors) {
        switch outcome {
        case .rendered(let diagram):
            let available = frame.insetBy(
                dx: Self.horizontalPadding,
                dy: Self.horizontalPadding
            )
            let fitted = MermaidDiagramLayout.fittedSize(
                intrinsic: diagram.image.size,
                availableWidth: available.width,
                maxHeight: min(available.height, profile.maxEmbeddedHeight)
            )
            let imageFrame = NSRect(
                x: available.midX - fitted.width / 2,
                y: available.midY - fitted.height / 2,
                width: fitted.width,
                height: fitted.height
            )
            diagram.image.draw(
                in: imageFrame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        case .failed(let failure):
            drawFailure(failure, in: frame, colors: colors)
        case nil:
            drawLoading(in: frame, colors: colors)
        }
    }

    private func drawLoading(in frame: NSRect, colors: DrawingColors) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: colors.muted
        ]
        let text = "Rendering Mermaid diagram…" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func drawFailure(
        _ failure: MermaidRenderFailure,
        in frame: NSRect,
        colors: DrawingColors
    ) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: colors.foreground
        ]
        let diagnosticAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: colors.muted
        ]
        let title = "Couldn't render Mermaid diagram" as NSString
        let diagnostic = failure.mermaidDisplayDiagnostic as NSString
        let frames = failureTextFrames(for: failure, in: frame)
        title.draw(
            at: frames.title.origin,
            withAttributes: titleAttributes
        )
        diagnostic.draw(
            in: frames.diagnostic,
            withAttributes: diagnosticAttributes
        )
    }

    func failureTextFrames(
        for failure: MermaidRenderFailure,
        in frame: NSRect
    ) -> FailureTextFrames {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]
        let diagnosticAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10)
        ]
        let title = "Couldn't render Mermaid diagram" as NSString
        let diagnostic = failure.mermaidDisplayDiagnostic as NSString
        let titleSize = title.size(withAttributes: titleAttributes)
        let diagnosticSize = diagnostic.size(withAttributes: diagnosticAttributes)
        let contentHeight = titleSize.height + 4 + diagnosticSize.height
        let startY = frame.midY - contentHeight / 2
        let width = max(0, frame.width - Self.horizontalPadding * 2)
        let titleFrame = NSRect(
            x: frame.minX + Self.horizontalPadding,
            y: startY,
            width: width,
            height: titleSize.height
        )
        let diagnosticFrame = NSRect(
            x: frame.minX + Self.horizontalPadding,
            y: titleFrame.maxY + 4,
            width: width,
            height: diagnosticSize.height
        )
        return FailureTextFrames(
            title: titleFrame,
            diagnostic: diagnosticFrame
        )
    }

    private func buttonFrames(
        in frame: NSRect
    ) -> (source: NSRect, copy: NSRect, expand: NSRect) {
        let y = frame.minY + 1
        let height = Self.headerHeight
        let expandWidth = buttonWidth(for: "Expand")
        let copyWidth = buttonWidth(for: "Copy")
        let sourceWidth = buttonWidth(for: showsSource ? "Hide source" : "Show source")
        let right = frame.maxX - 6
        let expand = NSRect(
            x: right - expandWidth,
            y: y,
            width: expandWidth,
            height: height
        )
        let copy = NSRect(
            x: expand.minX - copyWidth,
            y: y,
            width: copyWidth,
            height: height
        )
        let source = NSRect(
            x: copy.minX - sourceWidth,
            y: y,
            width: sourceWidth,
            height: height
        )
        return (source, copy, expand)
    }

    private func buttonWidth(for title: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium)
        ]
        return ceil((title as NSString).size(withAttributes: attributes).width) + 16
    }
}

private struct DrawingColors {
    let background: NSColor
    let surface: NSColor
    let foreground: NSColor
    let muted: NSColor
    let border: NSColor

    init(theme: MermaidDiagramTheme?) {
        background = Self.color(theme?.background, fallback: .textBackgroundColor)
        surface = Self.color(theme?.surface, fallback: .controlBackgroundColor)
        foreground = Self.color(theme?.foreground, fallback: .labelColor)
        muted = Self.color(theme?.muted, fallback: .secondaryLabelColor)
        border = Self.color(theme?.border, fallback: .separatorColor)
    }

    private static func color(_ hex: String?, fallback: NSColor) -> NSColor {
        guard let hex, hex.count == 7, hex.first == "#",
              let value = UInt32(hex.dropFirst(), radix: 16)
        else { return fallback }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: 1
        )
    }
}
