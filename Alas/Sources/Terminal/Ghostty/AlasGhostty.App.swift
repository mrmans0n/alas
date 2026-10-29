// AlasGhostty.App.swift
// Wraps ghostty_app_t + registers C runtime callbacks.
//
// Threading:
//   - All methods must be called on the main thread (@MainActor).
//   - C callbacks may arrive on any thread; they dispatch back to main when needed.
//   - `userdata` in ghostty_runtime_config_s points to the AppWakeupBox owned by App.
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
        nonisolated(unsafe) let cValue: ghostty_app_t

        /// Config kept alive so Ghostty can reference it through the app's lifetime.
        private let config: Config

        /// Box holding a weak-ref back to self; used as runtime-config userdata for wakeup_cb.
        /// Kept alive here so the pointer Ghostty holds remains valid.
        private let wakeupBox: AppWakeupBox

        /// Whether the config draws the default background transparent, so
        /// surfaces need a non-opaque layer for content behind them to show.
        let transparentBackground: Bool

        // MARK: Init

        /// - Parameter configPath: Path to a Ghostty config file, or nil for defaults.
        /// - Parameter transparentBackground: Must match the config's `background-opacity`.
        /// - Throws: `ConfigError` if config has diagnostics; `AppError` if app alloc fails.
        init(configPath: String? = nil, transparentBackground: Bool = false) throws {
            AlasGhostty.ensureInitialized()
            let cfg = try Config(filePath: configPath)
            self.config = cfg
            self.transparentBackground = transparentBackground

            // Create the box before self is fully initialised so we can pass its
            // pointer as `userdata`. The box will be filled with the weak `app` ref
            // immediately after all stored properties are set.
            let box = AppWakeupBox()
            self.wakeupBox = box

            // The userdata for wakeup_cb is an unretained pointer to `box`.
            // `box` is a heap object whose lifetime is tied to this App instance.
            let boxPtr = Unmanaged.passUnretained(box).toOpaque()

            var rtCfg = makeAlasGhosttyRuntimeConfig(userdata: boxPtr)

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

/// Builds callbacks without inheriting the caller's actor isolation.
func makeAlasGhosttyRuntimeConfig(userdata: UnsafeMutableRawPointer?) -> ghostty_runtime_config_s {
    ghostty_runtime_config_s(
        userdata: userdata,
        supports_selection_clipboard: false,
        wakeup_cb: { @Sendable ud in
            guard let ud else { return }
            let box = Unmanaged<AppWakeupBox>.fromOpaque(ud).takeUnretainedValue()
            guard let app = box.app else { return }
            DispatchQueue.main.async { app.tick() }
        },
        action_cb: { @Sendable cApp, target, action in
            alasGhosttyAction(cApp, target: target, action: action)
        },
        read_clipboard_cb: { @Sendable ud, clipboard, state, mimes, mimesLen, list in
            alasGhosttyReadClipboard(ud, clipboard: clipboard, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
        },
        confirm_read_clipboard_cb: { @Sendable ud, confirm, state, request in
            alasGhosttyConfirmReadClipboard(ud, confirm: confirm, state: state, request: request)
        },
        write_clipboard_cb: { @Sendable ud, clipboard, content, len, confirm in
            alasGhosttyWriteClipboard(ud, clipboard: clipboard, content: content, len: len, confirm: confirm)
        },
        close_surface_cb: { @Sendable ud, processAlive in
            alasGhosttyCloseSurface(ud, processAlive: processAlive)
        }
    )
}

/// Executes AppKit-dependent callback work on the main actor while preserving
/// synchronous C callback semantics.
func alasGhosttyOnMain<T: Sendable>(
    _ body: @escaping @MainActor @Sendable () -> T
) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { body() }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated { body() }
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
        guard let sv = surfaceView else { return true }
        let pwd = action.action.pwd.pwd.map { String(cString: $0) } ?? ""
        guard !pwd.isEmpty else { return true }
        // OSC 7 emits a file:// URL when shell integration is active. Parse
        // it as a URL first and fall back to treating the string as a raw
        // filesystem path for any shell that emits one directly.
        let url: URL = {
            if let parsed = URL(string: pwd), parsed.isFileURL {
                return URL(fileURLWithPath: parsed.path)
            }
            return URL(fileURLWithPath: pwd)
        }()
        DispatchQueue.main.async { sv.setCurrentWorkingDirectory(url) }
        return true

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
        // No cell-snapping in v1, but a font-size change alters the grid
        // without resizing the view, and peer console viewers follow it.
        if let sv = surfaceView { DispatchQueue.main.async { sv.reportGridSizeIfChanged() } }
        return true

    case GHOSTTY_ACTION_INITIAL_SIZE:
        return true // Alas controls window geometry.

    case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
        guard let sv = surfaceView else { return true }
        // Shell may still be running (user hit cmd-W inside Ghostty); we pass
        // false to signal "dismiss the pane regardless," not as a liveness claim.
        DispatchQueue.main.async { sv.processExitHandler?(false) }
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
        DispatchQueue.main.async {
            if let handler = surfaceView?.openURLHandler, handler(s) { return }
            guard let url = URL(string: s) else { return }
            NSWorkspace.shared.open(url)
        }
        return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        guard let sv = surfaceView else { return false }
        DispatchQueue.main.async { sv.processExitHandler?(false) }
        return true

    default:
        AlasGhostty.logger.debug("Unhandled Ghostty action tag=\(action.tag.rawValue)")
        return false
    }
}

// ---------------------------------------------------------------------------
// read_clipboard_cb
// The `userdata` here is the SurfaceView's pointer (set in surface_config.userdata).
// Alas serves plain text from the general pasteboard only; other requested
// MIME types are left out and the standard clipboard is the only location.
// ---------------------------------------------------------------------------
private let alasGhosttyTextMime = "text/plain"

private func alasGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD, let ud = userdata else {
        return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }
    let sv = Unmanaged<AlasGhostty.SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    guard let surface = sv.cSurface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    let wantsText = (0..<mimesLen).contains { i in
        mimes?[i].map { String(cString: $0) == alasGhosttyTextMime } ?? false
    }
    guard wantsText || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    let text = alasGhosttyOnMain {
        NSPasteboard.general.string(forType: .string)
    }
    let served = wantsText ? text : nil
    guard served != nil || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    alasGhosttyCompleteClipboardRead(surface, state: state, text: served, listText: list && text != nil)
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

// ---------------------------------------------------------------------------
// confirm_read_clipboard_cb — skip dialog, approve the would-be completion.
// ---------------------------------------------------------------------------
private func alasGhosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    state: UnsafeMutableRawPointer?,
    request _: ghostty_clipboard_request_e
) {
    guard let ud = userdata else { return }
    let sv = Unmanaged<AlasGhostty.SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    guard let surface = sv.cSurface else { return }
    guard let confirm else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
    }
    // The confirmation's buffers are borrowed for this call, which completes
    // synchronously, so they can be handed straight back.
    let c = confirm.pointee
    var complete = ghostty_clipboard_complete_s(
        contents: c.contents,
        contents_len: c.contents_len,
        available: c.available,
        available_len: c.available_len,
        confirmed: true,
        remember: false
    )
    ghostty_surface_complete_clipboard_request(surface, &complete, state)
}

/// Completes a read with the plain-text representation, if any, and, for
/// listing requests, `text/plain` as the only available type. Every C buffer
/// is borrowed by Ghostty for the duration of the call only.
private func alasGhosttyCompleteClipboardRead(
    _ surface: ghostty_surface_t,
    state: UnsafeMutableRawPointer?,
    text: String?,
    listText: Bool
) {
    alasGhosttyTextMime.withCString { mime in
        let available: [UnsafePointer<CChar>?] = listText ? [mime] : []
        let bytes = (text ?? "").utf8CString
        bytes.withUnsafeBufferPointer { data in
            // utf8CString carries a trailing NUL that is not part of the contents.
            let content = ghostty_clipboard_content_s(mime: mime, data: data.baseAddress, len: data.count - 1)
            withUnsafePointer(to: content) { contentPtr in
                available.withUnsafeBufferPointer { availablePtr in
                    var complete = ghostty_clipboard_complete_s(
                        contents: text == nil ? nil : contentPtr,
                        contents_len: text == nil ? 0 : 1,
                        available: availablePtr.baseAddress,
                        available_len: availablePtr.count,
                        confirmed: false,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
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
        guard let mimePtr = item.mime, String(cString: mimePtr) == alasGhosttyTextMime else { continue }
        // Contents are binary-safe with an explicit length, not NUL-terminated.
        let bytes = item.data.map { UnsafeRawBufferPointer(start: $0, count: item.len) }
        text = bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
        break
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
    DispatchQueue.main.async { sv.processExitHandler?(processAlive) }
}
