import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    /// When true, the window opts out of all mouse-driven window-moves
    /// (`isMovable = false`); regions that should still drag the window must
    /// be marked with `.windowDragHandle()`. The main workspace window needs
    /// this so the center pane's top tab bar isn't hijacked by the system
    /// titlebar drag tracker. Secondary windows (e.g. Settings) keep the
    /// default movable behavior so the system titlebar still drags them.
    var disablesSystemDrag: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let disablesSystemDrag = self.disablesSystemDrag
        DispatchQueue.main.async {
            if let window = view.window {
                TitlelessWindow.configure(window, disablesSystemDrag: disablesSystemDrag)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
