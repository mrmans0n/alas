import AppKit
import Testing
@testable import Alas

/// Regression: `ACPMarkdownInlineNSTextView.fittingSize` must report the real
/// multi-line height on the FIRST probe of a freshly-populated view. TextKit's
/// glyph generation is lazy, so `ensureLayout` + `usedRect` alone returned 0 on
/// the first call; the measurement cache (from #889) then froze that 0, so
/// SwiftUI laid the transcript row out with no height and the next row drew on
/// top of it. `forceLayout` (glyphRange) fixes the measurement.
@MainActor
struct ACPMarkdownInlineTextViewHeightTests {
    private func makeConfiguredTextView() -> ACPMarkdownInlineNSTextView {
        // Mirror ACPMarkdownInlineTextView.makeNSView exactly.
        let textView = ACPMarkdownInlineNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .clear
        return textView
    }

    private let wrappingParagraph =
        "Había una vez una niña llamada Lía que vivía en un pueblo donde todos " +
        "los relojes se habían cansado de dar la hora, y cada mañana el reloj de " +
        "la plaza bostezaba, cerraba sus agujas y se negaba a marcar el tiempo."

    @Test func firstProbeReportsMultiLineHeightForWrappingText() {
        let textView = makeConfiguredTextView()
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: wrappingParagraph, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        )

        // First-ever measurement of this freshly-populated view. Before the
        // fix this returned 0 (lazy glyphs), which the cache then froze.
        let firstProbe = textView.fittingSize(for: 200).height

        // At width 200 / 13pt this paragraph wraps to well over four lines.
        #expect(firstProbe >= 60)
    }

    @Test func firstProbeMatchesIndependentMeasurement() {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let attr = NSAttributedString(string: wrappingParagraph, attributes: attributes)
        let reference = ceil(
            attr.boundingRect(
                with: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        )

        let textView = makeConfiguredTextView()
        textView.textStorage?.setAttributedString(attr)
        let measured = textView.fittingSize(for: 200).height

        // The text view's own layout must agree with an independent bounding
        // measurement (within a line's rounding), not collapse to zero.
        #expect(abs(measured - reference) <= 20)
    }

    @Test func naturalFittingSizeReportsNonZeroHeight() {
        let textView = makeConfiguredTextView()
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: "Some wrapping text for the row.", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        )
        #expect(textView.naturalFittingSize().height > 0)
    }
}
