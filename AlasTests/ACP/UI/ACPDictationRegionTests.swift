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
