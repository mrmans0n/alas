import AppKit
import SwiftUI

extension View {
    /// Mark this view as a window-drag handle. Clicks on interactive children
    /// (buttons, etc.) still work because they're in front in the view tree;
    /// clicks on empty regions trigger `NSWindow.performDrag(with:)`. Use this
    /// alongside `window.isMovable = false` (set by `TitlelessWindow.configure`)
    /// to control exactly which areas can move the window.
    func windowDragHandle() -> some View {
        background(WindowDragHandle())
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Match the system default for double-clicking the titlebar.
            window?.performZoom(nil)
            return
        }
        window?.performDrag(with: event)
    }
}
