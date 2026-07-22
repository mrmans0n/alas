import AppKit
import Testing
@testable import Alas

/// The transcript scroll beachball came from `ACPMarkdownInlineNSTextView`
/// re-running full TextKit layout on every `sizeThatFits` probe (SwiftUI's
/// StackLayout probes each row at several widths per placement pass and
/// re-probes on every scroll frame). These tests pin the memoization that
/// fixed it: repeated probes at a known width must hit the cache, and any
/// content change must invalidate it so heights never go stale.
@MainActor
struct ACPMarkdownInlineTextViewMeasurementCacheTests {
    private func makeTextView(_ text: String) -> ACPMarkdownInlineNSTextView {
        let textView = ACPMarkdownInlineNSTextView()
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        )
        return textView
    }

    @Test func repeatedSameWidthProbesHitTheCache() {
        let textView = makeTextView("The quick brown fox jumps over the lazy dog, several times, wrapping.")

        let first = textView.fittingSize(for: 200)
        let second = textView.fittingSize(for: 200)
        let third = textView.fittingSize(for: 200)

        #expect(first == second)
        #expect(second == third)
        #expect(textView.fittingComputationCountForTests == 1)
    }

    @Test func distinctWidthsEachComputeOnce() {
        let textView = makeTextView("The quick brown fox jumps over the lazy dog, several times, wrapping.")

        _ = textView.fittingSize(for: 200)
        _ = textView.fittingSize(for: 350)
        _ = textView.fittingSize(for: 200) // repeat → cache hit
        _ = textView.fittingSize(for: 350) // repeat → cache hit

        #expect(textView.fittingComputationCountForTests == 2)
    }

    @Test func invalidateForcesRecomputation() {
        let textView = makeTextView("Some wrapping text for the row.")

        _ = textView.fittingSize(for: 200)
        #expect(textView.fittingComputationCountForTests == 1)

        textView.invalidateFittingCache()
        _ = textView.fittingSize(for: 200)
        #expect(textView.fittingComputationCountForTests == 2)
    }

    @Test func naturalFittingSizeIsCached() {
        let textView = makeTextView("Some wrapping text for the row.")

        let first = textView.naturalFittingSize()
        let second = textView.naturalFittingSize()

        #expect(first == second)
        #expect(textView.fittingComputationCountForTests == 1)

        textView.invalidateFittingCache()
        _ = textView.naturalFittingSize()
        #expect(textView.fittingComputationCountForTests == 2)
    }

    @Test func cacheIsBoundedAndEvictsUnderWidthChurn() {
        let textView = makeTextView("Some wrapping text for the row.")

        // Fill the cache to its 16-entry limit with distinct widths.
        for offset in 0..<16 {
            _ = textView.fittingSize(for: 100 + CGFloat(offset))
        }
        #expect(textView.fittingComputationCountForTests == 16)

        // An earlier width is still cached — no recomputation.
        _ = textView.fittingSize(for: 100)
        #expect(textView.fittingComputationCountForTests == 16)

        // A 17th distinct width overflows the cap and clears the cache.
        _ = textView.fittingSize(for: 200)
        #expect(textView.fittingComputationCountForTests == 17)

        // The earlier width was evicted, so it now recomputes.
        _ = textView.fittingSize(for: 100)
        #expect(textView.fittingComputationCountForTests == 18)
    }

    /// `widthTracksTextView` only re-syncs the container off a real frame
    /// change, so a cache hit must restore `textContainer.containerSize`
    /// itself. Otherwise probing width A (a miss) and then width B (a stale
    /// cache hit) would leave the container wrapped at A while the cached,
    /// correct height for B is what SwiftUI actually allocates.
    @Test func cacheHitRestoresContainerWidth() {
        let textView = makeTextView("Some wrapping text for the row.")

        _ = textView.fittingSize(for: 200) // miss — container left at 200
        _ = textView.fittingSize(for: 350) // miss — container left at 350
        #expect(textView.textContainer?.containerSize.width == 350)

        _ = textView.fittingSize(for: 200) // hit — must restore container to 200
        #expect(textView.textContainer?.containerSize.width == 200)
    }

    @Test func naturalFittingSizeCacheHitRestoresContainerWidth() {
        let textView = makeTextView("Some wrapping text for the row.")

        _ = textView.naturalFittingSize()
        _ = textView.fittingSize(for: 200) // interleaved miss at a fixed width

        _ = textView.naturalFittingSize() // hit — must restore the natural-width container
        #expect(textView.textContainer?.containerSize.width == 10_000)
    }
}
