import Testing
import AppKit
@testable import Alas

@MainActor
struct TitlelessWindowTests {
    @Test func hidesStandardWindowButtons() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        TitlelessWindow.configure(window)

        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == true)
    }

    @Test func fullSizeContentViewIsSet() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        TitlelessWindow.configure(window)

        #expect(window.styleMask.contains(.fullSizeContentView))
    }

    @Test func configurationViewConfiguresWindowWhenAttached() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let configurationView = WindowConfigurationView(disablesSystemDrag: false)

        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)

        window.contentView = configurationView

        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == true)
        #expect(window.styleMask.contains(.fullSizeContentView))
    }

    @Test func dragHandleMovesNonmovableWindow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isMovable = false

        let handle = WindowDragHandleView(frame: window.contentLayoutRect)
        window.contentView = handle
        let initialOrigin = window.frame.origin

        handle.mouseDown(with: try #require(Self.mouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            windowNumber: window.windowNumber
        )))
        handle.mouseDragged(with: try #require(Self.mouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: 55, y: 65),
            windowNumber: window.windowNumber
        )))

        #expect(window.frame.origin == NSPoint(
            x: initialOrigin.x + 35,
            y: initialOrigin.y + 45
        ))
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }
}
