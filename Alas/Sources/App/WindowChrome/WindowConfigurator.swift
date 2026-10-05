import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    var blocksSystemTitlebarDrag = false

    func makeNSView(context: Context) -> NSView {
        WindowConfigurationView(blocksSystemTitlebarDrag: blocksSystemTitlebarDrag)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowConfigurationView else { return }
        view.blocksSystemTitlebarDrag = blocksSystemTitlebarDrag
        view.configureWindowIfNeeded()
    }
}

/// Keeps the main workspace window non-movable so AppKit's native titlebar
/// tracker cannot steal tab drags. Explicit `WindowDragHandle` regions move
/// the window directly and continue to work while `isMovable` is false.
///
/// AppKit needs the window movable while displays sleep or reconfigure so it
/// can relocate and later restore the frame. A process-lifetime Core Graphics
/// callback announces reconfiguration before it begins; the AppKit notification
/// closes that window after the new screen geometry has settled.
final class WindowConfigurationView: NSView {
    var blocksSystemTitlebarDrag: Bool {
        didSet {
            guard oldValue != blocksSystemTitlebarDrag else { return }
            applyDragPolicy()
        }
    }

    private struct SystemWindowMoveReasons: OptionSet {
        let rawValue: Int

        static let displayReconfiguration = Self(rawValue: 1 << 0)
        static let screenSleep = Self(rawValue: 1 << 1)
    }

    private var systemWindowMoveReasons: SystemWindowMoveReasons = []
    private var displayWillReconfigureObserver: NSObjectProtocol?
    private var screensDidSleepObserver: NSObjectProtocol?
    private var screensDidWakeObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    init(blocksSystemTitlebarDrag: Bool = false) {
        self.blocksSystemTitlebarDrag = blocksSystemTitlebarDrag
        super.init(frame: .zero)

        displayWillReconfigureObserver = NotificationCenter.default.addObserver(
            forName: .windowDisplayWillReconfigure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginSystemWindowMove(.displayReconfiguration)
            }
        }
        _ = installWindowDisplayReconfigurationCallback

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        screensDidSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginSystemWindowMove(.screenSleep)
            }
        }
        screensDidWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endSystemWindowMove(.screenSleep)
            }
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginSystemWindowMove(.displayReconfiguration)
                RunLoop.main.perform { [weak self] in
                    MainActor.assumeIsolated {
                        self?.endSystemWindowMove(.displayReconfiguration)
                    }
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let displayWillReconfigureObserver {
            NotificationCenter.default.removeObserver(displayWillReconfigureObserver)
        }
        if let screensDidSleepObserver {
            workspaceCenter.removeObserver(screensDidSleepObserver)
        }
        if let screensDidWakeObserver {
            workspaceCenter.removeObserver(screensDidWakeObserver)
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
        applyDragPolicy()
    }

    func prepareForSystemWindowMove() {
        beginSystemWindowMove(.displayReconfiguration)
    }

    func restoreDragPolicy() {
        systemWindowMoveReasons = []
        applyDragPolicy()
    }

    private func beginSystemWindowMove(_ reason: SystemWindowMoveReasons) {
        systemWindowMoveReasons.insert(reason)
        applyDragPolicy()
    }

    private func endSystemWindowMove(_ reason: SystemWindowMoveReasons) {
        systemWindowMoveReasons.remove(reason)
        applyDragPolicy()
    }

    private func applyDragPolicy() {
        window?.isMovable = !blocksSystemTitlebarDrag || !systemWindowMoveReasons.isEmpty
    }
}

private extension Notification.Name {
    static let windowDisplayWillReconfigure =
        Notification.Name("Alas.windowDisplayWillReconfigure")
}

private let installWindowDisplayReconfigurationCallback: Void = {
    CGDisplayRegisterReconfigurationCallback(
        windowDisplayReconfigurationCallback,
        nil
    )
}()

private func windowDisplayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard flags.contains(.beginConfigurationFlag) else { return }
    let notify = {
        NotificationCenter.default.post(
            name: .windowDisplayWillReconfigure,
            object: nil
        )
    }
    if Thread.isMainThread {
        notify()
    } else {
        DispatchQueue.main.sync(execute: notify)
    }
}
