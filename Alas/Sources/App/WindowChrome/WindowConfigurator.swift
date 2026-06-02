import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    /// When true, the window opts out of all mouse-driven window-moves
    /// (`isMovable = false`); regions that should still drag the window must
    /// be marked with `.windowDragHandle()`. The main workspace window needs
    /// this so the center pane's top tab bar isn't hijacked by the system
    /// titlebar drag tracker. Secondary titleless windows keep the default
    /// movable behavior so the system titlebar still drags them.
    var disablesSystemDrag: Bool = false

    func makeNSView(context: Context) -> NSView {
        WindowConfigurationView(disablesSystemDrag: disablesSystemDrag)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowConfigurationView else { return }
        view.disablesSystemDrag = disablesSystemDrag
        view.configureWindowIfNeeded()
    }
}

final class WindowConfigurationView: NSView {
    var disablesSystemDrag: Bool {
        didSet {
            configureWindowIfNeeded()
        }
    }

    init(disablesSystemDrag: Bool) {
        self.disablesSystemDrag = disablesSystemDrag
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        TitlelessWindow.configure(window, disablesSystemDrag: disablesSystemDrag)
    }
}
