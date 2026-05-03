import AppKit

/// NSWindow that hides the native titlebar but keeps traffic lights so we can
/// inline them inside our SwiftUI sidebar header.
final class TitlelessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        // Hide the native titlebar separator
        window.titlebarSeparatorStyle = .none
    }
}
