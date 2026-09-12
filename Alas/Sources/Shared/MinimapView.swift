import AppKit
import CoreText

struct MinimapGeometry {
    let height: CGFloat
    let proportion: CGFloat
    let value: Double
    var width: CGFloat = MinimapView.width

    var thumb: CGRect {
        let h = max(0, height)
        let extent = min(h, max(16, h * min(1, max(0, proportion))))
        return CGRect(x: 0, y: CGFloat(min(1, max(0, value))) * (h - extent), width: width, height: extent)
    }
}

struct MinimapDrawing {
    struct Mark {
        var rect: CGRect
        let color: NSColor
    }

    var marks: [Mark] = []
    var height: CGFloat = 0
    var columns: CGFloat = 88

    static func editorText(_ text: NSAttributedString, columns: Int = 88) -> Self {
        let source = text.string as NSString
        var lines: [NSRange] = []
        var position = 0
        while position < source.length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            lines.append(NSRange(location: position, length: contentsEnd - position))
            position = end
        }
        if source.length == 0 || text.string.last?.isNewline == true {
            lines.append(NSRange(location: source.length, length: 0))
        }
        var result = Self(height: CGFloat(lines.count * 3), columns: CGFloat(columns))
        // Keep drawing memory bounded for generated files. CoreText lays out only
        // sampled line prefixes, using the editor's fonts, tab stops and colors.
        let stride = max(1, Int(ceil(Double(lines.count) / 4096)))
        for index in lines.indices where index % stride == 0 || index == lines.count - 1 {
            let range = lines[index]
            guard range.length > 0 else { continue }
            let prefix = source.rangeOfComposedCharacterSequences(for: NSRange(location: range.location, length: min(range.length, 512)))
            let attributed = text.attributedSubstring(from: prefix)
            let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            let cell = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
            let line = CTLineCreateWithAttributedString(attributed)
            var offset = 0
            for character in attributed.string {
                let length = String(character).utf16.count
                defer { offset += length }
                let x = CTLineGetOffsetForStringIndex(line, offset, nil) / cell
                guard x < CGFloat(columns) else { break }
                guard !character.isWhitespace else { continue }
                let end = CTLineGetOffsetForStringIndex(line, offset + length, nil) / cell
                let color = attributed.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor ?? .labelColor
                result.marks.append(Mark(rect: CGRect(x: x, y: CGFloat(index * 3), width: max(0.5, min(CGFloat(columns) - x, abs(end - x) * 0.85)), height: 2), color: color))
            }
        }
        return result
    }

    /// Character-sized blocks retain syntax runs and the negative space between tokens.
    static func text(_ text: NSAttributedString, columns: Int = 88, tabWidth: Int = 4, wraps: Bool = false) -> Self {
        var result = Self(columns: CGFloat(max(1, columns)))
        var row = 0
        var column = 0
        var offset = 0
        var colorRange = NSRange(location: 0, length: 0)
        var color = NSColor.labelColor
        for character in text.string {
            let string = String(character)
            let length = string.utf16.count
            defer { offset += length }
            if character.isNewline {
                row += 1
                column = 0
                continue
            }
            if character == "\t" {
                column += max(1, tabWidth) - column % max(1, tabWidth)
                continue
            }
            if wraps, column >= columns {
                row += 1
                column = 0
            }
            if !character.isWhitespace, column < columns {
                if !NSLocationInRange(offset, colorRange) {
                    color = text.attribute(.foregroundColor, at: offset, effectiveRange: &colorRange) as? NSColor ?? .labelColor
                }
                result.marks.append(Mark(
                    rect: CGRect(x: CGFloat(column), y: CGFloat(row * 3), width: 0.85, height: 2),
                    color: color
                ))
            }
            column += 1
        }
        result.height = CGFloat((row + 1) * 3)
        return result
    }

    mutating func append(_ other: Self, x: CGFloat = 0, y: CGFloat) {
        marks.append(contentsOf: other.marks.map {
            Mark(rect: $0.rect.offsetBy(dx: x, dy: y), color: $0.color)
        })
        height = max(height, y + other.height)
    }
}

@MainActor
final class MinimapView: NSView {
    nonisolated static let width: CGFloat = 96
    var onNavigate: ((Double) -> Void)?
    var onNavigationStart: (() -> Void)?
    var onNavigationEnd: (() -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?
    var value: Double = 0 { didSet { needsDisplay = true } }
    var proportion: CGFloat = 1 { didSet { needsDisplay = true } }
    var backgroundColor = NSColor.textBackgroundColor { didSet { needsDisplay = true } }
    var indicatorColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var preservesLineScale = false { didSet { raster = nil
    needsDisplay = true } }
    private var drawing = MinimapDrawing()
    private var raster: CGImage?
    private var rasterSize = CGSize.zero
    private var rasterOffset: CGFloat = -1
    private var dragStartY: CGFloat = 0
    private var dragStartValue: Double = 0
    private var dragTravel: CGFloat = 1
    private var lastDragY: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Minimap")
        toolTip = "Minimap"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(drawing: MinimapDrawing) {
        self.drawing = drawing
        raster = nil
        needsDisplay = true
    }

    private var geometry: MinimapGeometry {
        let height = min(bounds.height, max(16, drawing.height * verticalScale))
        return MinimapGeometry(height: height, proportion: drawing.height * verticalScale * proportion / max(1, height), value: value, width: bounds.width)
    }

    private var verticalScale: CGFloat {
        if preservesLineScale, drawing.height <= 4096 * 3 { return 1 }
        return min(1, bounds.height / max(1, drawing.height))
    }

    private var drawingOffset: CGFloat {
        CGFloat(min(1, max(0, value))) * max(0, drawing.height * verticalScale - bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let offset = drawingOffset
        if raster == nil || rasterSize != size || rasterOffset != offset {
            rasterSize = size
            rasterOffset = offset
            if let context = CGContext(data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: scale, y: -scale)
                let sx = max(0, bounds.width - 8) / max(1, drawing.columns)
                let sy = verticalScale
                let marks: ArraySlice<MinimapDrawing.Mark>
                if preservesLineScale, sy == 1 {
                    var low = 0
                    var high = drawing.marks.count
                    while low < high {
                        let mid = (low + high) / 2
                        if drawing.marks[mid].rect.maxY < offset { low = mid + 1 } else { high = mid }
                    }
                    marks = drawing.marks[low...].prefix { $0.rect.minY <= offset + bounds.height }
                } else {
                    marks = drawing.marks[...]
                }
                for mark in marks {
                    context.setFillColor(mark.color.cgColor)
                    context.fill(CGRect(x: 4 + mark.rect.minX * sx, y: mark.rect.minY * sy - offset,
                                        width: mark.rect.width * sx, height: max(0.5 / scale, mark.rect.height * sy)))
                }
                raster = context.makeImage()
            }
        }
        if let raster {
            NSImage(cgImage: raster, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        indicatorColor.withAlphaComponent(indicatorColor.alphaComponent * 0.1).setFill()
        geometry.thumb.fill()
        indicatorColor.withAlphaComponent(indicatorColor.alphaComponent * 0.5).setStroke()
        NSBezierPath(rect: geometry.thumb.insetBy(dx: 0.5, dy: 0.5)).stroke()
        indicatorColor.withAlphaComponent(indicatorColor.alphaComponent * 0.2).setFill()
        CGRect(x: 0, y: 0, width: 0.5, height: bounds.height).fill()
    }

    override func scrollWheel(with event: NSEvent) {
        if let onScrollWheel { onScrollWheel(event) } else { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        onNavigationStart?()
        let y = convert(event.locationInWindow, from: nil).y
        let thumb = geometry.thumb
        dragStartValue = value
        dragTravel = max(1, geometry.height - thumb.height)
        if !(thumb.minY...thumb.maxY ~= y) {
            let travel = drawing.height * verticalScale - thumb.height
            let target = travel > 0 ? Double((drawingOffset + y - thumb.height / 2) / travel) : 0
            dragStartValue = min(1, max(0, target))
            navigate(to: target)
        }
        dragStartY = y
        lastDragY = y
    }

    override func mouseDragged(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        guard y != lastDragY else { return }
        lastDragY = y
        let delta = y - dragStartY
        navigate(to: dragStartValue + Double(delta / dragTravel))
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        onNavigationEnd?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: navigate(to: value - max(0.01, Double(proportion) / 2))
        case 125: navigate(to: value + max(0.01, Double(proportion) / 2))
        case 115: navigate(to: 0)
        case 119: navigate(to: 1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityPerformIncrement() -> Bool {
        navigate(to: value + max(0.01, Double(proportion) / 2))
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        navigate(to: value - max(0.01, Double(proportion) / 2))
        return true
    }

    private func navigate(to value: Double) {
        self.value = min(1, max(0, value))
        onNavigate?(self.value)
    }
}

@MainActor
class MinimapScrollView: NSScrollView {
    let minimap = MinimapView(frame: .zero)
    var showsMinimap = false {
        didSet {
            guard showsMinimap != oldValue else { return }
            superview?.needsLayout = true
        }
    }

    func updateMinimapVisibility(availableWidth: CGFloat) {}
}

/// Keep the minimap outside AppKit's tiling area so repeated layout passes
/// never expand and shrink the clip view around hosted document content.
final class MinimapContainerView<ScrollView: MinimapScrollView>: NSView {
    let scrollView: ScrollView

    init(scrollView: ScrollView) {
        self.scrollView = scrollView
        super.init(frame: scrollView.frame)
        addSubview(scrollView)
        addSubview(scrollView.minimap)
        scrollView.minimap.onScrollWheel = { [weak scrollView] event in
            scrollView?.scrollWheel(with: event)
        }
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        scrollView.updateMinimapVisibility(availableWidth: bounds.width)
        let width = scrollView.showsMinimap ? min(MinimapView.width, max(0, bounds.width / 3)) : 0
        scrollView.minimap.isHidden = !scrollView.showsMinimap
        let scrollFrame = CGRect(x: bounds.minX, y: bounds.minY, width: max(0, bounds.width - width), height: bounds.height)
        if scrollView.frame != scrollFrame { scrollView.frame = scrollFrame }
        let minimapFrame = CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
        if scrollView.minimap.frame != minimapFrame { scrollView.minimap.frame = minimapFrame }
        super.layout()
    }
}
