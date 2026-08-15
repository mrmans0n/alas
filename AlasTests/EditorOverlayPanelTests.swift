import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorOverlayPanelTests {
    private func makeHostView(in window: NSWindow) -> NSView {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = hostView
        return hostView
    }

    @Test func frameReturnsZeroSizedWhenViewHasNoWindow() {
        let hostView = NSView(frame: .zero)
        #expect(hostView.window == nil)
        let panel = EditorOverlayPanel()
        let size = NSSize(width: 200, height: 120)

        let frame = EditorOverlayPanelTesting.frame(
            for: panel,
            size: size,
            anchor: NSRect(x: 50, y: 80, width: 20, height: 20),
            in: hostView
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
        let hostView = makeHostView(in: window)
        let panel = EditorOverlayPanel()
        let size = NSSize(width: 300, height: 100)
        let anchor = NSRect(x: 50, y: 300, width: 40, height: 16)

        let frame = EditorOverlayPanelTesting.frame(
            for: panel,
            size: size,
            anchor: anchor,
            in: hostView
        )

        let anchorScreen = window.convertToScreen(hostView.convert(anchor, to: nil))
        #expect(frame.maxY < anchorScreen.minY)
        #expect(frame.size == size)
    }
}
