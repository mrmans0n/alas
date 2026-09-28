import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    /// When true, the system titlebar drag is blocked for gestures that start
    /// in the titlebar band, so the main workspace window's top tab strip is
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

/// Configures the hosting window and, when `disablesTitlebarDrag` is set,
/// blocks the system titlebar drag tracker from claiming clicks that land in
/// the titlebar band (where the main workspace window's top tab strip sits).
///
/// `window.isMovable` is the only lever AppKit exposes for this, and it's a
/// window-wide flag, not one scoped to a screen region. The window stays
/// movable at all times — which is what lets macOS relocate and restore it
/// through display and sleep/wake changes — except for the exact span of a
/// mouse-down-to-mouse-up gesture that starts in the titlebar band. The
/// system's own drag-on-background behavior only ever triggers from a
/// mouse-down, so a local event monitor re-derives the answer fresh from the
/// real event at that moment, rather than from cached pointer-hover state
/// that a fast drag crossing into the band without a `mouseMoved` could leave
/// stale, and rather than a reapply step that could race a live display
/// change landing between "force movable" and "restore the guard".
final class WindowConfigurationView: NSView {
    var disablesTitlebarDrag: Bool {
        didSet {
            guard !disablesTitlebarDrag else { return }
            window?.isMovable = true
        }
    }

    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var screensDidSleepObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    init(disablesTitlebarDrag: Bool) {
        self.disablesTitlebarDrag = disablesTitlebarDrag
        super.init(frame: .zero)
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.refreshMovability(for: event)
            return event
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.restoreMovability(for: event)
            return event
        }
        // Displays that sleep (lock, idle) or a live disconnect/reconnect/
        // resolution change could otherwise catch the window non-movable if
        // its last mouse-down landed in the titlebar band and the matching
        // mouse-up was somehow missed. Force movable back on as a safety net;
        // there's nothing to "reapply" afterward, since the mouse-down
        // monitor re-derives the correct value from scratch on the very next
        // click.
        screensDidSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.isMovable = true
            }
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
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
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        if let screensDidSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensDidSleepObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        TitlelessWindow.configure(window)
    }

    private func refreshMovability(for event: NSEvent) {
        guard disablesTitlebarDrag, let window, event.window === window else { return }
        window.isMovable = TitlelessWindow.allowsSystemMove(
            pointerInWindow: event.locationInWindow,
            windowSize: window.frame.size,
            contentLayoutRect: window.contentLayoutRect
        )
    }

    private func restoreMovability(for event: NSEvent) {
        guard let window, event.window === window else { return }
        window.isMovable = true
    }
}
