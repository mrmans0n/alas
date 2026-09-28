import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    /// When true, the system titlebar drag is turned off while the pointer is
    /// over the titlebar band, so the main workspace window's top tab strip is
    /// never hijacked. Explicit `WindowDragHandle` regions move the window
    /// there instead. Secondary titleless windows keep the system behavior.
    var disablesTitlebarDrag: Bool = false

    func makeNSView(context: Context) -> NSView {
        WindowConfigurationView(disablesTitlebarDrag: disablesTitlebarDrag)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowConfigurationView else { return }
        view.disablesTitlebarDrag = disablesTitlebarDrag
        view.configureWindowIfNeeded()
    }
}

final class WindowConfigurationView: NSView {
    var disablesTitlebarDrag: Bool {
        didSet {
            configureWindowIfNeeded()
        }
    }

    private var screensDidSleepObserver: NSObjectProtocol?

    init(disablesTitlebarDrag: Bool) {
        self.disablesTitlebarDrag = disablesTitlebarDrag
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        // Displays that sleep (lock, idle) are often disconnected. Make sure
        // the window is movable before that, even if the pointer was left
        // resting on the titlebar band.
        screensDidSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.isMovable = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        if let screensDidSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensDidSleepObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    override func mouseMoved(with event: NSEvent) {
        updateMovability(pointerInWindow: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        updateMovability(pointerInWindow: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        updateMovability(pointerInWindow: nil)
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        TitlelessWindow.configure(window)
        updateMovability(pointerInWindow: window.mouseLocationOutsideOfEventStream)
    }

    private func updateMovability(pointerInWindow: NSPoint?) {
        guard let window else { return }
        let movable = !disablesTitlebarDrag || pointerInWindow.map {
            TitlelessWindow.allowsSystemMove(
                pointerInWindow: $0,
                windowSize: window.frame.size,
                contentLayoutRect: window.contentLayoutRect
            )
        } ?? true
        if window.isMovable != movable {
            window.isMovable = movable
        }
    }
}
