import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("ACP composer dictation region editing")
struct ACPDictationRegionTests {
    @Test("first volatile update inserts at the caret")
    func firstVolatileUpdateInsertsAtCaret() {
        let textView = ACPNSTextView()
        textView.string = "before  after"
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        textView.replaceDictationRegion("hello", isFinal: false)

        #expect(textView.string == "before hello after")
    }

    @Test("second volatile update replaces the first instead of appending")
    func secondVolatileUpdateReplacesFirst() {
        let textView = ACPNSTextView()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.replaceDictationRegion("Hell", isFinal: false)
        textView.replaceDictationRegion("Hello world", isFinal: false)

        #expect(textView.string == "Hello world")
    }

    @Test("final update commits the span so the next volatile update starts fresh")
    func finalUpdateCommitsSpan() {
        let textView = ACPNSTextView()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.replaceDictationRegion("Hello world", isFinal: true)
        textView.replaceDictationRegion("Next", isFinal: false)

        #expect(textView.string == "Hello worldNext")
    }

    @Test("volatile update after a final commit corrects only the new span")
    func volatileAfterFinalCorrectsOnlyNewSpan() {
        let textView = ACPNSTextView()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.replaceDictationRegion("Hello world. ", isFinal: true)
        textView.replaceDictationRegion("Nex", isFinal: false)
        textView.replaceDictationRegion("Next sentence", isFinal: false)

        #expect(textView.string == "Hello world. Next sentence")
    }

    @Test("canceling the region leaves committed text but stops tracking it")
    func cancelingRegionLeavesTextInPlace() {
        let textView = ACPNSTextView()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.replaceDictationRegion("partial thought", isFinal: false)
        textView.cancelDictationRegion()

        #expect(textView.string == "partial thought")

        // A later dictation session inserts fresh text after the leftover
        // instead of overwriting it, because canceling stopped tracking.
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.replaceDictationRegion(" new", isFinal: false)

        #expect(textView.string == "partial thought new")
    }

    @Test("a manual edit while a span is tracked stops dictation outright")
    func manualEditDuringTrackingStopsDictation() {
        let textView = ACPNSTextView()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        var stopCount = 0
        // `coordinator` is a weak property on the text view — this local
        // keeps it alive for the test, exactly as the real composer's
        // owning view does.
        let coordinator = makeCoordinator(onStopDictation: { stopCount += 1 })
        textView.coordinator = coordinator

        textView.replaceDictationRegion("Hell", isFinal: false)
        #expect(stopCount == 0)

        // A keystroke elsewhere in the buffer — not through
        // replaceDictationRegion — while "Hell" is still an open span.
        // Untracking the span alone isn't enough: the speech session is
        // still analyzing that utterance and would otherwise emit more
        // corrections nobody asked for once the user has taken over.
        textView.insertText(" note", replacementRange: NSRange(location: 0, length: 0))

        #expect(stopCount == 1)
        // Repeated edits don't fire it again — dictation only needed to be
        // told once, and there's no longer a tracked span to invalidate.
        textView.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        #expect(stopCount == 1)
    }

    @Test("a manual edit while a span is tracked stops tracking it, instead of a late result replacing the wrong text")
    func manualEditDuringTrackingStopsTracking() {
        let textView = ACPNSTextView()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.replaceDictationRegion("Hell", isFinal: false)
        // A keystroke elsewhere in the buffer while "Hell" is still an
        // open span at offset (0, 4). It shifts "Hell" to offset 5 without
        // updating the tracked range.
        textView.insertText(" note", replacementRange: NSRange(location: 0, length: 0))
        // The manual edit above stops dictation (see the sibling test), so
        // in practice no more results arrive. This exercises the residual
        // safety net for whatever the engine may have already queued
        // before the stop took effect: without range invalidation, this
        // would replace the now-stale (0, 4) span — " not", the buffer's
        // first four characters after the manual edit — corrupting text
        // the edit shifted into place and losing track of "Hell" entirely.
        textView.replaceDictationRegion("Hello world", isFinal: false)

        #expect(textView.string.contains("Hell"))
        #expect(!textView.string.contains("Hello worldeHell"))
    }

    private func makeCoordinator(onStopDictation: @escaping () -> Void) -> ACPInputField.Coordinator {
        ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            initialDraft: .empty,
            focusRequest: 0,
            sendOnEnter: true,
            onDraftChange: { _ in },
            onDraftClear: {},
            onStopDictation: onStopDictation,
            onSubmit: { _, _, _, _, _ in true }
        )
    }

    @Test("dictation region preserves surrounding text")
    func dictationRegionPreservesSurroundingText() {
        let textView = ACPNSTextView()
        textView.string = "keep-before  keep-after"
        textView.setSelectedRange(NSRange(location: 12, length: 0))

        textView.replaceDictationRegion("middle", isFinal: false)
        textView.replaceDictationRegion("middle text", isFinal: true)

        #expect(textView.string == "keep-before middle text keep-after")
    }
}
