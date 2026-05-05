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
        // areas (like split dividers). Keep it off; window drag still works
        // from the (invisible) titlebar zone at the top.
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        // Hide the native titlebar separator
        window.titlebarSeparatorStyle = .none
        // Hide the native traffic-light buttons; we inline our own in the sidebar.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
