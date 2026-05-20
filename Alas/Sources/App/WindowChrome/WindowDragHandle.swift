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
            performTitlebarDoubleClickAction()
            return
        }
        window?.performDrag(with: event)
    }

    // Mirror the system titlebar's response to a double-click, which the user
    // configures via System Settings > Desktop & Dock > "Double-click a
    // window's title bar to". Stored in `NSGlobalDomain` as
    // `AppleActionOnDoubleClick` with values "Maximize" / "Minimize" / "None".
    private func performTitlebarDoubleClickAction() {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch action {
        case "Minimize":
            window?.performMiniaturize(nil)
        case "None":
            break
        default:
            // "Maximize" or unset — default to zoom, matching macOS's default.
            window?.performZoom(nil)
        }
    }
}
