import AppKit
import SwiftUI

final class CodeEditorLineNumberRulerView: NSRulerView {
    private weak var codeTextView: CodeTextView?
    private var theme: Theme
    private var textChangeObserver: NSObjectProtocol?
    private var boundsObserver: NSObjectProtocol?
    private var lineStarts: [Int] = [0]
    private weak var cachedTextStorage: NSTextStorage?

    private let minimumThickness: CGFloat = 44
    private let horizontalPadding: CGFloat = 10

    init(scrollView: NSScrollView, textView: CodeTextView, theme: Theme) {
        self.codeTextView = textView
        self.theme = theme
        super.init(scrollView: scrollView, orientation: .verticalRuler)

        clientView = textView
        ruleThickness = minimumThickness
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        observe(textView: textView, scrollView: scrollView)
        rebuildLineStartsAndUpdateThickness()
        needsDisplay = true
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    deinit {
        removeObservers()
    }

    func update(textView: CodeTextView, theme: Theme) {
        if codeTextView !== textView {
            codeTextView = textView
            clientView = textView
            if let scrollView {
                observe(textView: textView, scrollView: scrollView)
            }
            rebuildLineStartsAndUpdateThickness()
        } else if cachedTextStorage !== textView.textStorage {
            rebuildLineStartsAndUpdateThickness()
        } else {
            updateThickness()
        }

        self.theme = theme
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(theme.color("bg-1")).setFill()
        bounds.fill()

        guard
            let textView = codeTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let scrollView = scrollView
        else { return }

        updateThickness()

        let visibleRect = scrollView.contentView.bounds
        let inset = textView.textContainerInset
        let fullWidth = max(textContainer.size.width, textView.bounds.width, visibleRect.maxX, 1)
        let visibleTextContainerRect = NSRect(
            x: 0,
            y: visibleRect.minY - inset.height,
            width: fullWidth,
            height: visibleRect.height
        )
        layoutManager.ensureLayout(forBoundingRect: visibleTextContainerRect, in: textContainer)
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleTextContainerRect,
            in: textContainer
        )

        let attributes = labelAttributes(font: textView.font)
        let string = textView.string as NSString
        var lastDrawnLineIndex: Int?

        if visibleGlyphRange.location != NSNotFound {
            layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { lineRect, _, _, glyphRange, _ in
                let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                guard characterRange.location != NSNotFound else { return }

                let lineRange = string.lineRange(for: NSRange(location: characterRange.location, length: 0))
                guard characterRange.location == lineRange.location else { return }

                let lineIndex = self.lineIndex(containing: lineRange.location)
                guard lineIndex != lastDrawnLineIndex else { return }
                lastDrawnLineIndex = lineIndex

                self.drawLineNumber(
                    lineIndex + 1,
                    lineRect: lineRect,
                    textView: textView,
                    inset: inset,
                    attributes: attributes
                )
            }
        }

        if shouldDrawExtraLineFragment(for: string) {
            let extraLineRect = layoutManager.extraLineFragmentRect
            if extraLineRect.height > 0, extraLineRect.intersects(visibleTextContainerRect) {
                drawLineNumber(
                    lineStarts.count,
                    lineRect: extraLineRect,
                    textView: textView,
                    inset: inset,
                    attributes: attributes
                )
            }
        }
    }

    private func observe(textView: CodeTextView, scrollView: NSScrollView) {
        removeObservers()

        textChangeObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildLineStartsAndUpdateThickness()
            self?.needsDisplay = true
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    private func removeObservers() {
        if let textChangeObserver {
            NotificationCenter.default.removeObserver(textChangeObserver)
            self.textChangeObserver = nil
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
    }

    private func updateThickness() {
        guard let textView = codeTextView else {
            ruleThickness = minimumThickness
            return
        }

        let lineCount = max(1, lineStarts.count)
        let digits = String(lineCount).count
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: labelAttributes(font: textView.font)).width)
        ruleThickness = max(minimumThickness, width + horizontalPadding * 2)
    }

    private func labelAttributes(font: NSFont?) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        return [
            .font: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(theme.color("fg-faint")),
            .paragraphStyle: paragraph
        ]
    }

    private func rebuildLineStartsAndUpdateThickness() {
        guard let textView = codeTextView else {
            lineStarts = [0]
            cachedTextStorage = nil
            ruleThickness = minimumThickness
            return
        }

        cachedTextStorage = textView.textStorage
        let string = textView.string as NSString
        var starts = [0]
        var searchLocation = 0
        while searchLocation < string.length {
            let range = NSRange(location: searchLocation, length: string.length - searchLocation)
            let newlineRange = string.range(of: "\n", options: [], range: range)
            guard newlineRange.location != NSNotFound else { break }
            searchLocation = NSMaxRange(newlineRange)
            starts.append(searchLocation)
        }

        lineStarts = starts
        updateThickness()
    }

    private func lineIndex(containing location: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count

        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        return max(0, lower - 1)
    }

    private func shouldDrawExtraLineFragment(for string: NSString) -> Bool {
        if string.length == 0 {
            return true
        }
        return string.substring(with: NSRange(location: string.length - 1, length: 1)) == "\n"
    }

    private func drawLineNumber(
        _ lineNumber: Int,
        lineRect: NSRect,
        textView: CodeTextView,
        inset: NSSize,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let label = "\(lineNumber)" as NSString
        let labelSize = label.size(withAttributes: attributes)
        let textViewPoint = NSPoint(x: 0, y: inset.height + lineRect.minY)
        let rulerPoint = convert(textViewPoint, from: textView)
        let drawRect = NSRect(
            x: 0,
            y: rulerPoint.y + (lineRect.height - labelSize.height) / 2,
            width: ruleThickness - horizontalPadding,
            height: labelSize.height
        )
        label.draw(in: drawRect, withAttributes: attributes)
    }
}
