import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorOverlayPanelTests {
    private func makeTextView(in window: NSWindow) -> CodeTextView {
        let storage = NSTextStorage(string: "hello world")
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        window.contentView = textView
        return textView
    }

    @Test func frameReturnsZeroSizedWhenViewHasNoWindow() {
        let storage = NSTextStorage(string: "x")
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: 100))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: .zero, textContainer: container)
        #expect(textView.window == nil)
        let panel = EditorOverlayPanel()
        let size = NSSize(width: 200, height: 120)

        let frame = EditorOverlayPanelTesting.frame(
            for: panel,
            size: size,
            anchor: NSRect(x: 50, y: 80, width: 20, height: 20),
            in: textView
        )

        #expect(frame.size == size)
        #expect(frame.origin == .zero)
    }

    @Test func framePlacesPanelBelowAnchorWhenSpaceAllows() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let textView = makeTextView(in: window)
        let panel = EditorOverlayPanel()
        let size = NSSize(width: 300, height: 100)
        let anchor = NSRect(x: 50, y: 300, width: 40, height: 16)

        let frame = EditorOverlayPanelTesting.frame(
            for: panel,
            size: size,
            anchor: anchor,
            in: textView
        )

        let anchorScreen = window.convertToScreen(textView.convert(anchor, to: nil))
        #expect(frame.maxY < anchorScreen.minY)
        #expect(frame.size == size)
    }
}
