import AppKit
import SwiftUI

struct ReadonlyTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    let backgroundColor: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = backgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.backgroundColor = backgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 10)

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.backgroundColor = backgroundColor
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.backgroundColor = backgroundColor

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: CenterTypography.paragraphStyle()
        ]
        if textView.string != text {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        } else {
            textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.string.utf16.count))
        }
        textView.typingAttributes = attributes
    }
}
