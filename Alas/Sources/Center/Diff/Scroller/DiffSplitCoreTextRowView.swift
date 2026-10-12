import AppKit
import CoreText

/// A split hunk drawn with CoreText in one view: no text views, scroll
/// views, or rulers. Spike for the 90fps review target; unwrapped only, and
/// no selection, hover, LSP, or expansion pills yet.
@MainActor
final class DiffSplitCoreTextRowView: NSView, AppKitDiffRowView {
    enum Side { case old, new }

    static let verticalInset: CGFloat = 8
    static let textInset: CGFloat = 10
    static let gutterWidth: CGFloat = 42

    var representedRowID: String?
    var onIntrinsicSizeInvalidated: ((String) -> Void)?
    private(set) var lastMeasuredWidth: CGFloat?
    private(set) var lineHeight: CGFloat = 16

    private struct SideLines {
        var code: [CTLine] = []
        var codeStrings: [String] = []
        var labels: [CTLine] = []
        var tones: [DiffPaneLineTone] = []
        var widest: CGFloat = 0
    }

    private var old = SideLines()
    private var new = SideLines()
    private var theme: Theme?
    private var descent: CGFloat = 4

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsFormat = .RGBA8Uint
    }

    func configure(result: DiffPaneTextDocumentBuilder.SplitResult, font: NSFont, theme: Theme) {
        self.theme = theme
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        descent = ceil(-font.descender)
        old = Self.lines(code: result.oldCode, gutter: result.oldGutter)
        new = Self.lines(code: result.newCode, gutter: result.newGutter)
        needsDisplay = true
    }

    func widestLineWidth(side: Side) -> CGFloat {
        side == .old ? old.widest : new.widest
    }

    func cachedLineStringForTesting(side: Side, line: Int) -> String? {
        let lines = side == .old ? old : new
        return lines.codeStrings.indices.contains(line) ? lines.codeStrings[line] : nil
    }

    private var lineCount: Int { max(old.code.count, new.code.count) }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        lastMeasuredWidth = width
        return CGFloat(lineCount) * lineHeight + 2 * Self.verticalInset
    }

    func attach(to documentView: NSView) {
        documentView.addSubview(self)
    }

    func suppressNextLayoutForStableScroll() {}

    func visibleLineRange(in rect: NSRect) -> Range<Int> {
        guard lineCount > 0, lineHeight > 0 else { return 0..<0 }
        let top = rect.minY - Self.verticalInset
        let bottom = rect.maxY - Self.verticalInset
        let first = max(0, Int(floor(top / lineHeight)))
        let last = min(lineCount, Int(ceil(bottom / lineHeight)))
        return first < last ? first..<last : first..<first
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let frames = DiffPaneSplitGeometry.frames(containerWidth: bounds.width)
        let range = visibleLineRange(in: dirtyRect)
        draw(old, in: frames.oldPane, range: range, theme: theme, context: context)
        draw(new, in: frames.newPane, range: range, theme: theme, context: context)
        theme.nsColor("line").setFill()
        NSRect(x: frames.divider.minX, y: dirtyRect.minY, width: frames.divider.width, height: dirtyRect.height).fill()
    }

    private func draw(_ side: SideLines, in pane: CGRect, range: Range<Int>, theme: Theme, context: CGContext) {
        context.saveGState()
        context.clip(to: CGRect(x: pane.minX, y: bounds.minY, width: pane.width, height: bounds.height))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for index in range {
            let y = Self.verticalInset + CGFloat(index) * lineHeight
            if side.tones.indices.contains(index), let fill = Self.fill(for: side.tones[index], theme: theme) {
                let rowRect = NSRect(x: pane.minX, y: y, width: pane.width, height: lineHeight)
                fill.setFill()
                rowRect.fill()
                if side.tones[index] == .placeholder {
                    Self.drawPlaceholderHatch(in: rowRect, theme: theme)
                }
            }
            let baseline = y + lineHeight - descent
            if side.labels.indices.contains(index) {
                let label = side.labels[index]
                let width = CTLineGetTypographicBounds(label, nil, nil, nil)
                context.textPosition = CGPoint(x: pane.minX + Self.gutterWidth - 6 - width, y: baseline)
                CTLineDraw(label, context)
            }
            if side.code.indices.contains(index) {
                context.textPosition = CGPoint(x: pane.minX + Self.gutterWidth + Self.textInset, y: baseline)
                CTLineDraw(side.code[index], context)
            }
        }
        context.restoreGState()
    }

    /// Same hatch as `DiffPaneCodeTextView.drawPlaceholderHatch`.
    private static func drawPlaceholderHatch(in rect: NSRect, theme: Theme) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let path = NSBezierPath()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += 8
        }
        path.lineWidth = 1
        theme.nsColor("line").withAlphaComponent(0.35).setStroke()
        path.stroke()
    }

    private static func fill(for tone: DiffPaneLineTone, theme: Theme) -> NSColor? {
        switch tone {
        case .add: theme.nsColor("add").withAlphaComponent(0.18)
        case .delete: theme.nsColor("del").withAlphaComponent(0.18)
        case .placeholder: theme.nsColor("bg-2").withAlphaComponent(0.55)
        case .collapsed: theme.nsColor("bg-3").withAlphaComponent(0.72)
        case .context: nil
        }
    }

    private static func lines(
        code document: DiffPaneTextDocumentBuilder.CodeDocument,
        gutter: NSAttributedString
    ) -> SideLines {
        var side = SideLines()
        let text = document.attributedString
        let length = text.length
        for metadata in document.lines {
            var range = metadata.range
            range.location = min(range.location, length)
            range.length = min(range.length, length - range.location)
            var line = text.attributedSubstring(from: range)
            if line.string.hasSuffix("\n") {
                line = line.attributedSubstring(from: NSRange(location: 0, length: line.length - 1))
            }
            let ctLine = CTLineCreateWithAttributedString(line)
            side.code.append(ctLine)
            side.codeStrings.append(line.string)
            side.widest = max(side.widest, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
        }
        let labels = gutter.string.components(separatedBy: "\n")
        var location = 0
        for (index, label) in labels.enumerated() {
            let length = (label as NSString).length
            let attributed = length > 0 && location + length <= gutter.length
                ? gutter.attributedSubstring(from: NSRange(location: location, length: length))
                : NSAttributedString(string: label)
            side.labels.append(CTLineCreateWithAttributedString(attributed))
            location += length + 1
            if index < document.lines.count {
                let metadata = document.lines[index]
                side.tones.append(metadata.tone ?? DiffPaneLineTone(label: label, rowKind: metadata.kind))
            }
        }
        while side.tones.count < document.lines.count {
            let metadata = document.lines[side.tones.count]
            side.tones.append(metadata.tone ?? DiffPaneLineTone(label: "", rowKind: metadata.kind))
        }
        return side
    }
}
