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
        let configurationView = WindowConfigurationView(disablesTitlebarDrag: false)

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

    /// Only the titlebar band may be non-movable: macOS will not move a
    /// non-movable window off a removed display or back when it returns.
    @Test(arguments: [(distanceBelowTop: 5.0, movable: false), (distanceBelowTop: 200.0, movable: true)])
    func mainWindowIsNonmovableOnlyUnderTitlebar(distanceBelowTop: CGFloat, movable: Bool) throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let configurationView = WindowConfigurationView(disablesTitlebarDrag: true)
        window.contentView = configurationView

        configurationView.mouseMoved(with: try #require(Self.mouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: 400, y: window.frame.height - distanceBelowTop),
            windowNumber: window.windowNumber
        )))

        #expect(window.isMovable == movable)
    }

    /// A live display disconnect/reconnect fires `didChangeScreenParameters`
    /// with no guaranteed mouse move first, and AppKit has already adjusted
    /// window frames for the change by the time it arrives. The window must
    /// become movable so macOS can relocate/restore it through this and any
    /// subsequent change, and the pointer-based policy must come back after,
    /// not leave the window draggable indefinitely.
    @Test func screenParametersChangeForcesThenReappliesPointerPolicy() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let configurationView = WindowConfigurationView(disablesTitlebarDrag: true)
        window.contentView = configurationView
        configurationView.mouseMoved(with: try #require(Self.mouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: 400, y: window.frame.height - 5),
            windowNumber: window.windowNumber
        )))
        #expect(window.isMovable == false)

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let deadline = Date().addingTimeInterval(1)
        while window.isMovable, Date() < deadline {
            pumpMainRunLoop(seconds: 0.01)
        }

        #expect(window.isMovable == false)
    }

    /// On wake, a stationary pointer left over the tab strip produces no
    /// mouse-move event. The pointer-based policy must be reapplied
    /// immediately, not on the next mouse movement.
    @Test func screensWakeReappliesPointerPolicy() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let configurationView = WindowConfigurationView(disablesTitlebarDrag: true)
        window.contentView = configurationView
        configurationView.mouseMoved(with: try #require(Self.mouseEvent(
            type: .mouseMoved,
            location: NSPoint(x: 400, y: window.frame.height - 5),
            windowNumber: window.windowNumber
        )))
        window.isMovable = true // simulate the sleep-time rescue left it movable

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        pumpMainRunLoop(seconds: 0.05)

        #expect(window.isMovable == false)
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

private func pumpMainRunLoop(seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}
