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
/// can relocate and later restore the frame. A Core Graphics callback opens
/// that window before display reconfiguration begins; the AppKit notification
/// closes it after the new screen geometry has settled.
final class WindowConfigurationView: NSView {
    var blocksSystemTitlebarDrag: Bool {
        didSet {
            guard oldValue != blocksSystemTitlebarDrag else { return }
            restoreDragPolicy()
        }
    }

    private var screensDidSleepObserver: NSObjectProtocol?
    private var screensDidWakeObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    init(blocksSystemTitlebarDrag: Bool = false) {
        self.blocksSystemTitlebarDrag = blocksSystemTitlebarDrag
        super.init(frame: .zero)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        screensDidSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prepareForSystemWindowMove()
            }
        }
        screensDidWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreDragPolicy()
            }
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prepareForSystemWindowMove()
                RunLoop.main.perform { [weak self] in
                    MainActor.assumeIsolated {
                        self?.restoreDragPolicy()
                    }
                }
            }
        }
        CGDisplayRegisterReconfigurationCallback(
            windowDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        CGDisplayRemoveReconfigurationCallback(
            windowDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
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
        restoreDragPolicy()
    }

    func prepareForSystemWindowMove() {
        guard blocksSystemTitlebarDrag else { return }
        window?.isMovable = true
    }

    func restoreDragPolicy() {
        window?.isMovable = !blocksSystemTitlebarDrag
    }
}

private func windowDisplayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard flags.contains(.beginConfigurationFlag), let userInfo else { return }
    let address = UInt(bitPattern: userInfo)
    let prepare = {
        MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            Unmanaged<WindowConfigurationView>
                .fromOpaque(pointer)
                .takeUnretainedValue()
                .prepareForSystemWindowMove()
        }
    }
    if Thread.isMainThread {
        prepare()
    } else {
        DispatchQueue.main.sync(execute: prepare)
    }
}
