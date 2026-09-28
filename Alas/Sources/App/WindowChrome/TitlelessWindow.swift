import AppKit

/// NSWindow that hides the native titlebar and its standard traffic-light
/// buttons. Custom `TrafficLights` views replace them in SwiftUI.
final class TitlelessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // isMovableByWindowBackground swallows SwiftUI gestures on transparent
        // areas (like split dividers). Keep it off.
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        // Hide the native titlebar separator
        window.titlebarSeparatorStyle = .none
        // Hide the native traffic-light buttons; custom TrafficLights views replace them.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// Whether a mouse-down at `pointerInWindow` (window coordinates) should
    /// be allowed to start a system window drag.
    ///
    /// The system titlebar drag tracker claims mouse-downs anywhere in the
    /// titlebar band, which breaks tab reordering there, so a mouse-down
    /// landing inside that band must not be allowed to move the window.
    /// Everywhere else it must: when a display is removed, macOS only nudges
    /// a non-movable window partly on screen, and never puts it back when
    /// that display returns, so the window must default to movable and only
    /// become non-movable for the span of a titlebar-band gesture.
    static func allowsSystemMove(
        pointerInWindow: NSPoint,
        windowSize: NSSize,
        contentLayoutRect: NSRect
    ) -> Bool {
        let titlebarBand = NSRect(
            x: 0,
            y: contentLayoutRect.maxY,
            width: windowSize.width,
            height: windowSize.height - contentLayoutRect.maxY
        )
        return !titlebarBand.contains(pointerInWindow)
    }
}
