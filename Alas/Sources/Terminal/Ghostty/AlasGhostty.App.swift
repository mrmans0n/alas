// AlasGhostty.App.swift
// Wraps ghostty_app_t + registers C runtime callbacks.
//
// Threading:
//   - All methods must be called on the main thread (@MainActor).
//   - C callbacks may arrive on any thread; they dispatch back to main when needed.
//   - `userdata` in ghostty_runtime_config_s = Unmanaged<App>.passUnretained(self).toOpaque()
//   - Surface-level callbacks use the SurfaceView's userdata pointer (set in SurfaceView.init).

import AppKit
import GhosttyKit

// A heap-allocated reference-type box used as `userdata` for the wakeup callback.
// The box survives the `App.init` scope and is kept alive by `App` via `wakeupBox`.
// This avoids the "self before fully initialised" problem while keeping the pointer valid.
private final class AppWakeupBox: @unchecked Sendable {
    // Weak so we don't create a retain cycle (App owns the box, box weakly refs App).
    weak var app: AlasGhostty.App?
}

extension AlasGhostty {

    /// Manages the single Ghostty application instance.
    ///
    /// Owns one `ghostty_app_t`. Create once at startup and keep alive for the app lifetime.
    @MainActor
    final class App {

        // MARK: Stored properties

        /// Raw C app pointer. Valid for this object's lifetime.
        let cValue: ghostty_app_t

        /// Config kept alive so Ghostty can reference it through the app's lifetime.
        private let config: Config

        /// Box holding a weak-ref back to self; used as runtime-config userdata for wakeup_cb.
        /// Kept alive here so the pointer Ghostty holds remains valid.
        private let wakeupBox: AppWakeupBox

        // MARK: Init

        /// - Parameter configPath: Path to a Ghostty config file, or nil for defaults.
        /// - Throws: `ConfigError` if config has diagnostics; `AppError` if app alloc fails.
        init(configPath: String? = nil) throws {
            let cfg = try Config(filePath: configPath)
            self.config = cfg

            // Create the box before self is fully initialised so we can pass its
            // pointer as `userdata`. The box will be filled with the weak `app` ref
            // immediately after all stored properties are set.
            let box = AppWakeupBox()
            self.wakeupBox = box

            // The userdata for wakeup_cb is an unretained pointer to `box`.
            // `box` is a heap object whose lifetime is tied to this App instance.
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()

            var rtCfg = ghostty_runtime_config_s(
                userdata: boxPtr,
                supports_selection_clipboard: false,
                wakeup_cb: { ud in
                    guard let ud else { return }
                    // Recover the AppWakeupBox and from it the App.
                    let box = Unmanaged<AppWakeupBox>.fromOpaque(ud).takeUnretainedValue()
                    guard let app = box.app else { return }
                    DispatchQueue.main.async { app.tick() }
                },
                action_cb: { cApp, target, action in
                    alasGhosttyAction(cApp, target: target, action: action)
                },
                read_clipboard_cb: { ud, clipboard, state in
                    alasGhosttyReadClipboard(ud, clipboard: clipboard, state: state)
                },
                confirm_read_clipboard_cb: { ud, str, state, request in
                    alasGhosttyConfirmReadClipboard(ud, string: str, state: state, request: request)
                },
                write_clipboard_cb: { ud, clipboard, content, len, confirm in
                    alasGhosttyWriteClipboard(ud, clipboard: clipboard, content: content, len: len, confirm: confirm)
                },
                close_surface_cb: { ud, processAlive in
                    alasGhosttyCloseSurface(ud, processAlive: processAlive)
                }
            )

            guard let rawApp = ghostty_app_new(&rtCfg, cfg.cValue) else {
                throw AppError.allocationFailed
            }
            self.cValue = rawApp

            // Now that all stored properties are set, wire up the back-reference.
            box.app = self

            // Initial focus state.
            ghostty_app_set_focus(cValue, NSApp.isActive)

            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(appDidBecomeActive),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(appDidResignActive),
                           name: NSApplication.didResignActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(keyboardSelectionDidChange),
                           name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        }

        deinit {
            // Nil out the box so any in-flight wakeup_cb sees app == nil and returns.
            wakeupBox.app = nil
            NotificationCenter.default.removeObserver(self)
            ghostty_app_free(cValue)
        }

        // MARK: Operations

        /// Drives Ghostty's internal event loop. Call from NSApplication's wakeup handler.
        func tick() {
            ghostty_app_tick(cValue)
        }

        /// Tell Ghostty whether the application is focused.
        func setFocus(_ focused: Bool) {
            ghostty_app_set_focus(cValue, focused)
        }

        /// Hot-swap the config for all surfaces. Triggers `GHOSTTY_ACTION_CONFIG_CHANGE`.
        func updateConfig(_ newConfig: Config) {
            ghostty_app_update_config(cValue, newConfig.cValue)
        }

        // MARK: Notification targets

        @objc private func appDidBecomeActive() { ghostty_app_set_focus(cValue, true) }
        @objc private func appDidResignActive()  { ghostty_app_set_focus(cValue, false) }
        @objc private func keyboardSelectionDidChange() { ghostty_app_keyboard_changed(cValue) }

        // MARK: Errors

        enum AppError: Error, LocalizedError {
            case allocationFailed
            var errorDescription: String? { "ghostty_app_new() returned nil" }
        }
    }
}

// MARK: - C Runtime Callbacks (module-level @convention(c)-compatible free functions)
//
// Callbacks for wakeup and close_surface use the runtime config's `userdata` (the App box).
// Callbacks for clipboard and action use the surface's userdata (the SurfaceView).

// ---------------------------------------------------------------------------
// action_cb
// ---------------------------------------------------------------------------
private func alasGhosttyAction(
    _ cApp: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    // Recover the surface view when the target is a surface.
    let surfaceView: AlasGhostty.SurfaceView? = {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        guard let cSurface = target.target.surface else { return nil }
        guard let ud = ghostty_surface_userdata(cSurface) else { return nil }
        return Unmanaged<AlasGhostty.SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }()

    switch action.tag {

    case GHOSTTY_ACTION_SET_TITLE:
        guard let sv = surfaceView else { return false }
        let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
        DispatchQueue.main.async { sv.titleHandler?(title) }
        return true

    case GHOSTTY_ACTION_PWD:
        return true // Alas doesn't display CWD badges — silently accept.

    case GHOSTTY_ACTION_MOUSE_SHAPE:
        guard let sv = surfaceView else { return false }
        let shape = action.action.mouse_shape
        DispatchQueue.main.async { sv.applyCursorShape(shape) }
        return true

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
        DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(!visible) }
        return true

    case GHOSTTY_ACTION_RENDER:
        // Ghostty requests a redraw.
        guard let sv = surfaceView else { return false }
        DispatchQueue.main.async { sv.setNeedsDisplay(sv.bounds) }
        return true

    case GHOSTTY_ACTION_CELL_SIZE:
        return true // No cell-snapping in v1.

    case GHOSTTY_ACTION_INITIAL_SIZE:
        return true // Alas controls window geometry.

    case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
        guard let sv = surfaceView else { return true }
        DispatchQueue.main.async { sv.processExitHandler?() }
        return true

    case GHOSTTY_ACTION_QUIT:
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true

    case GHOSTTY_ACTION_RELOAD_CONFIG, GHOSTTY_ACTION_CONFIG_CHANGE:
        return true // Alas drives config reloads explicitly.

    case GHOSTTY_ACTION_RENDERER_HEALTH:
        if action.action.renderer_health != GHOSTTY_RENDERER_HEALTH_HEALTHY {
            AlasGhostty.logger.warning("Ghostty renderer unhealthy")
        }
        return true

    case GHOSTTY_ACTION_RING_BELL:
        DispatchQueue.main.async { NSSound.beep() }
        return true

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        return true // Ignored in v1.

    case GHOSTTY_ACTION_OPEN_URL:
        let v = action.action.open_url
        guard let ptr = v.url, v.len > 0 else { return false }
        let data = Data(bytes: ptr, count: Int(v.len))
        let s = String(data: data, encoding: .utf8) ?? ""
        guard let url = URL(string: s) else { return false }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        guard let sv = surfaceView else { return false }
        DispatchQueue.main.async { sv.processExitHandler?() }
        return true

    default:
        AlasGhostty.logger.debug("Unhandled Ghostty action tag=\(action.tag.rawValue)")
        return false
    }
}

// ---------------------------------------------------------------------------
// read_clipboard_cb
// The `userdata` here is the SurfaceView's pointer (set in surface_config.userdata).
// ---------------------------------------------------------------------------
private func alasGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?
) -> Bool {
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return false }
    guard let text = NSPasteboard.general.string(forType: .string) else { return false }
    guard let ud = userdata else { return false }
    let sv = Unmanaged<AlasGhostty.SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    guard let surface = sv.cSurface else { return false }
    text.withCString { ptr in
        ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
    }
    return true
}

// ---------------------------------------------------------------------------
// confirm_read_clipboard_cb — skip dialog, proceed immediately.
// ---------------------------------------------------------------------------
private func alasGhosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    guard let ud = userdata else { return }
    let sv = Unmanaged<AlasGhostty.SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    guard let surface = sv.cSurface else { return }
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    text.withCString { ptr in
        ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
    }
}

// ---------------------------------------------------------------------------
// write_clipboard_cb
// ---------------------------------------------------------------------------
private func alasGhosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    len: Int,
    confirm: Bool
) {
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return }
    guard let content, len > 0 else { return }
    var text: String?
    for i in 0..<len {
        let item = content[i]
        guard let mimePtr = item.mime, let dataPtr = item.data else { continue }
        if String(cString: mimePtr) == "text/plain" {
            text = String(cString: dataPtr)
            break
        }
    }
    guard let finalText = text else { return }
    DispatchQueue.main.async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalText, forType: .string)
    }
}

// ---------------------------------------------------------------------------
// close_surface_cb
// The `userdata` here is the SurfaceView's userdata pointer.
// ---------------------------------------------------------------------------
private func alasGhosttyCloseSurface(
    _ userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    guard let ud = userdata else { return }
    let sv = Unmanaged<AlasGhostty.SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    AlasGhostty.logger.info("close_surface_cb processAlive=\(processAlive)")
    DispatchQueue.main.async { sv.processExitHandler?() }
}
