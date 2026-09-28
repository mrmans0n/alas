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
    private var screensDidWakeObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    /// Window-space pointer position from the last mouse-tracking event.
    /// Used to reapply the movability policy on wake without depending on
    /// `NSWindow.mouseLocationOutsideOfEventStream`, which reflects the
    /// actual hardware pointer and cannot be driven from a synthetic event.
    private var lastPointerInWindow: NSPoint?

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
        // A live display disconnect/reconnect or resolution change fires this
        // instead of (or in addition to) a sleep/wake pair, with no guarantee
        // of a mouse move first if the pointer was left over the titlebar
        // band. Force movable immediately so macOS can relocate/restore the
        // window through the transition.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.isMovable = true
            }
        }
        // On wake, reapply the pointer-based policy immediately: a stationary
        // pointer left over the tab strip produces no mouse-move/enter event,
        // so without this the first click after wake could still be claimed
        // as a system window drag.
        screensDidWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureWindowIfNeeded()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let screensDidSleepObserver {
            notificationCenter.removeObserver(screensDidSleepObserver)
        }
        if let screensDidWakeObserver {
            notificationCenter.removeObserver(screensDidWakeObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastPointerInWindow = window?.mouseLocationOutsideOfEventStream
        configureWindowIfNeeded()
    }

    override func mouseMoved(with event: NSEvent) {
        lastPointerInWindow = event.locationInWindow
        updateMovability(pointerInWindow: lastPointerInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        lastPointerInWindow = event.locationInWindow
        updateMovability(pointerInWindow: lastPointerInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        lastPointerInWindow = nil
        updateMovability(pointerInWindow: nil)
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        TitlelessWindow.configure(window)
        updateMovability(pointerInWindow: lastPointerInWindow)
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
