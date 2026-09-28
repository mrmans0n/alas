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

    /// The system titlebar drag tracker only ever triggers from a
    /// mouse-down, so that's the only moment `isMovable` must be correct.
    /// This is verified fresh from the real event, not from cached hover
    /// state, so it also covers a fast drag that crosses into the band
    /// without a preceding `mouseMoved`.
    @Test(arguments: [(distanceBelowTop: 5.0, movable: false), (distanceBelowTop: 200.0, movable: true)])
    func mouseDownInTitlebarBandBlocksSystemDrag(distanceBelowTop: CGFloat, movable: Bool) throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let configurationView = WindowConfigurationView(disablesTitlebarDrag: true)
        window.contentView = configurationView

        NSApp.sendEvent(try #require(Self.mouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: 400, y: window.frame.height - distanceBelowTop),
            windowNumber: window.windowNumber
        )))

        #expect(window.isMovable == movable)
    }

    /// The window must default back to movable once the gesture ends, so
    /// background system events (sleep, display changes) between gestures
    /// always see a movable window.
    @Test func mouseUpRestoresMovabilityAfterTitlebarDrag() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let configurationView = WindowConfigurationView(disablesTitlebarDrag: true)
        window.contentView = configurationView

        NSApp.sendEvent(try #require(Self.mouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: 400, y: window.frame.height - 5),
            windowNumber: window.windowNumber
        )))
        #expect(window.isMovable == false)

        NSApp.sendEvent(try #require(Self.mouseEvent(
            type: .leftMouseUp,
            location: NSPoint(x: 400, y: window.frame.height - 5),
            windowNumber: window.windowNumber
        )))

        #expect(window.isMovable == true)
    }

    /// Turning the guard off (e.g. a secondary window) must not leave the
    /// window stuck non-movable from an earlier titlebar gesture.
    @Test func disablingTitlebarGuardRestoresMovability() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let configurationView = WindowConfigurationView(disablesTitlebarDrag: true)
        window.contentView = configurationView
        NSApp.sendEvent(try #require(Self.mouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: 400, y: window.frame.height - 5),
            windowNumber: window.windowNumber
        )))
        #expect(window.isMovable == false)

        configurationView.disablesTitlebarDrag = false

        #expect(window.isMovable == true)
    }

    /// A live display disconnect/reconnect or a sleeping display can leave
    /// the window non-movable if a titlebar-band mouse-down's matching
    /// mouse-up was somehow missed. Both must force the window back to
    /// movable as a safety net.
    @Test(arguments: [NSWorkspace.screensDidSleepNotification, NSApplication.didChangeScreenParametersNotification])
    func systemEventsForceWindowMovable(_ notificationName: Notification.Name) throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let configurationView = WindowConfigurationView(disablesTitlebarDrag: true)
        window.contentView = configurationView
        NSApp.sendEvent(try #require(Self.mouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: 400, y: window.frame.height - 5),
            windowNumber: window.windowNumber
        )))
        #expect(window.isMovable == false)

        let center = notificationName == NSWorkspace.screensDidSleepNotification
            ? NSWorkspace.shared.notificationCenter
            : NotificationCenter.default
        center.post(name: notificationName, object: nil)

        let deadline = Date().addingTimeInterval(1)
        while !window.isMovable, Date() < deadline {
            pumpMainRunLoop(seconds: 0.01)
        }

        #expect(window.isMovable == true)
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
