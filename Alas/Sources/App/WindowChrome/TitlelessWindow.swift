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
        // Disable mouse-driven window-moves entirely (titlebar drag included)
        // so the center pane's top tab bar doesn't get hijacked. Areas that
        // should still drag the window opt in via `.windowDragHandle()`.
        window.isMovable = false
        window.backgroundColor = .clear
        window.isOpaque = false
        // Hide the native titlebar separator
        window.titlebarSeparatorStyle = .none
        // Hide the native traffic-light buttons; custom TrafficLights views replace them.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
