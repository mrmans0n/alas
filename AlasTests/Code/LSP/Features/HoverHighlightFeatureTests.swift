import Testing
import Foundation
import AppKit
@testable import Alas

@MainActor
@Suite(.serialized)
struct HoverHighlightFeatureTests {

    /// Build a text view backed by a real layout chain so the feature can
    /// resolve word ranges and write temp attributes.
    private func makeTextView(_ text: String) -> CodeTextView {
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        view.string = text
        let storage = NSTextStorage(string: text)
        storage.addLayoutManager(layoutManager)
        return view
    }

    @Test func clearsUnderlineWhenCommandReleased() async {
        let view = makeTextView("let resolve = 1\n")
        let feature = HoverHighlightFeature(
            textView: view,
            getClient: { nil },
            getURI: { "file:///cur.swift" }
        )
        // Simulate ⌘ pressed + mouse over "resolve". The nil-client path
        // means no LSP query runs; the feature should still cleanly track
        // command state and never set an underline.
        feature.simulateCommandPressed()
        feature.simulateMouseMoved(at: NSPoint(x: 30, y: 10))
        try? await Task.sleep(nanoseconds: 200_000_000)
        feature.simulateCommandReleased()
        #expect(feature.lastUnderlinedRange == nil)
    }

    @Test func clearsUnderlineWhenLSPReturnsEmpty() async {
        let view = makeTextView("let x = 1\n")
        let feature = HoverHighlightFeature(
            textView: view,
            getClient: { nil },
            getURI: { "file:///cur.swift" }
        )
        feature.simulateCommandPressed()
        feature.simulateMouseMoved(at: NSPoint(x: 30, y: 10))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(feature.lastUnderlinedRange == nil)
    }
}
