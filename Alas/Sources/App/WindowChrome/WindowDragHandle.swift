import AppKit
import SwiftUI

/// A concrete hit-tested region that moves the main nonmovable window.
///
/// This must participate in layout rather than sit in a SwiftUI background:
/// `NSHostingView` owns background hit testing, so a representable installed
/// there never receives the mouse sequence.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class WindowDragHandleView: NSView {
    private var dragStart: (pointer: NSPoint, windowOrigin: NSPoint)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            performTitlebarDoubleClickAction()
            return
        }
        guard let window else { return }
        dragStart = (
            pointer: window.convertPoint(toScreen: event.locationInWindow),
            windowOrigin: window.frame.origin
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(
            x: dragStart.windowOrigin.x + pointer.x - dragStart.pointer.x,
            y: dragStart.windowOrigin.y + pointer.y - dragStart.pointer.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
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
