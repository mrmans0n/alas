// AlasGhostty.SurfaceView.swift
// NSView subclass that hosts a Ghostty terminal surface via CAMetalLayer.
//
// One SurfaceView = one terminal session.
// The view owns the ghostty_surface_t lifetime.
//
// Key implementation notes:
//   - `wantsLayer = true`; the layer is a CAMetalLayer. Ghostty renders into it via Metal.
//   - `userdata` in ghostty_surface_config_s = Unmanaged(self), so C callbacks can
//     recover this view.
//   - Key events: translated directly to ghostty_input_key_s using NSEvent helpers
//     ported from upstream's NSEvent+Extension.swift and SurfaceView_AppKit.swift.
//   - Mouse events: forwarded to ghostty_surface_mouse_*.
//   - Title changes: delivered via App's action_cb → `titleHandler` closure.
//   - Process exit: delivered via close_surface_cb → `processExitHandler` closure.

import AppKit
import Metal
import ObjectiveC
import QuartzCore
import GhosttyKit

// MARK: - GhosttySurfaceIO

/// Narrow seam around the four ghostty_surface_* C calls used by the input
/// pipeline. Lets unit tests drive NSTextInputClient methods without standing
/// up a real Ghostty surface.
@MainActor
protocol GhosttySurfaceIO {
    func sendKey(_ event: ghostty_input_key_s) -> Bool
    func sendText(_ text: String)
    func setPreedit(_ text: String?)
    func imePoint() -> CGRect
}

/// Production adapter that forwards to the C ABI of a real ghostty_surface_t.
@MainActor
final class LiveGhosttySurfaceIO: GhosttySurfaceIO {
    nonisolated(unsafe) private let surface: ghostty_surface_t
    init(_ surface: ghostty_surface_t) { self.surface = surface }

    func sendKey(_ event: ghostty_input_key_s) -> Bool {
        return ghostty_surface_key(surface, event)
    }

    func sendText(_ text: String) {
        let bytes = text.utf8.count
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(bytes))
        }
    }

    func setPreedit(_ text: String?) {
        if let text {
            let bytes = text.utf8.count
            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(bytes))
            }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func imePoint() -> CGRect {
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

extension AlasGhostty {
    /// Terminal display view. Each session owns exactly one of these.
    @MainActor
    final class SurfaceView: NSView, FontSizeResponder {
        // MARK: - Public callbacks

        /// Called (on main thread) whenever the terminal title changes.
        var titleHandler: ((String) -> Void)?

        /// Called (on main thread) when the pane should be dismissed.
        /// `processAlive == false` is the dismiss signal — emitted authoritatively
        /// by `close_surface_cb` when the shell exits, and conventionally by the
        /// `CLOSE_WINDOW`/`CLOSE_TAB`/`SHOW_CHILD_EXITED` Ghostty actions to mean
        /// "Alas should tear down this pane regardless of shell liveness."
        /// `processAlive == true` only arrives from `close_surface_cb` when Ghostty
        /// is tearing down a surface whose shell is still running because we asked
        /// it to (manual-close path); receivers should no-op in that case.
        /// May fire more than once for a single shell exit (e.g. `SHOW_CHILD_EXITED`
        /// followed by `close_surface_cb`); receivers must be idempotent.
        var processExitHandler: ((_ processAlive: Bool) -> Void)?

        // Current working directory, derived from Ghostty's GHOSTTY_ACTION_PWD events
        // (which fire when the shell emits OSC 7). Nil until the shell reports one.
        private(set) var currentWorkingDirectory: URL?

        /// Fired on the main queue when the shell reports a new working directory.
        var cwdHandler: ((URL) -> Void)?

        /// Invoked on the main queue when Ghostty emits a cmd-click URL.
        /// Return `true` to swallow the event; `false` lets the caller fall
        /// back to `NSWorkspace.shared.open` for default macOS handling.
        var openURLHandler: ((String) -> Bool)?

        func setCurrentWorkingDirectory(_ url: URL) {
            currentWorkingDirectory = url
            cwdHandler?(url)
        }

        // MARK: - Internal state

        /// The raw C surface pointer. Nil only if surface creation failed.
        /// Marked nonisolated(unsafe) so C callbacks (which run on arbitrary threads) can
        /// read the pointer without a MainActor hop. The pointer itself is set once at init
        /// time and never mutated afterward, so this is safe.
        nonisolated(unsafe) private(set) var cSurface: ghostty_surface_t?

        /// Narrow IO seam around ghostty_surface_* calls used by the input
        /// pipeline. Initialized after a successful ghostty_surface_new();
        /// `nil` when surface init failed. Call sites must guard before use.
        private var surfaceIO: GhosttySurfaceIO?

        /// Unretained back-reference to the owning App. Optional so the
        /// test-only `init(testIO:)` can omit it.
        private let app: App?

        /// Whether the surface currently has keyboard focus.
        private var isFocused: Bool = false

        /// Temporarily non-nil while inside keyDown so insertText can accumulate
        /// text without double-delivering it via both insertText and raw key events.
        var keyTextAccumulator: [String]?

        // MARK: - Init

        /// - Parameters:
        ///   - app: The owning `AlasGhostty.App` instance.
        ///   - configuration: Per-surface overrides (shell, cwd, env, …).
        ///   - uuid: Unique identifier for this surface (used for logging).
        init(
            app: App,
            configuration: SurfaceConfiguration = SurfaceConfiguration(),
            uuid: UUID = UUID()
        ) {
            self.app = app
            // Use a sensible initial frame; Ghostty will size itself properly once
            // the view is in a window and we send the first set_size call.
            super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            // Enable layer-backed rendering. We'll configure the layer in makeBackingLayer().
            wantsLayer = true
            registerForDraggedTypes([.alasDropPayload])

            // The surface config passes `self` as userdata so C callbacks can recover us.
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            let surface = configuration.withCValue(nsView: self, userdata: selfPtr) { cfg in
                ghostty_surface_new(app.cValue, &cfg)
            }

            guard let surface else {
                AlasGhostty.logger.error("ghostty_surface_new() returned nil — surface init failed")
                return
            }
            self.cSurface = surface
            self.surfaceIO = LiveGhosttySurfaceIO(surface)

            // Set up mouse tracking so we receive mouseMoved events.
            updateTrackingAreas()
        }

        /// Test-only initializer that bypasses ghostty_surface_new and uses
        /// the supplied IO seam. Never call from production code.
        init(testIO: GhosttySurfaceIO) {
            self.app = nil
            super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            wantsLayer = true
            registerForDraggedTypes([.alasDropPayload])
            self.cSurface = nil
            self.surfaceIO = testIO
        }

        /// Test-only accessor for the IO seam.
        var surfaceIOForTesting: GhosttySurfaceIO { surfaceIO! }

        required init?(coder: NSCoder) {
            fatalError("SurfaceView does not support NSCoder")
        }

        deinit {
            if let surface = cSurface {
                ghostty_surface_free(surface)
            }
        }

        // MARK: - CAMetalLayer setup

        override func makeBackingLayer() -> CALayer {
            let metalLayer = CAMetalLayer()
            metalLayer.device = MTLCreateSystemDefaultDevice()
            metalLayer.pixelFormat = .bgra8Unorm
            // Must be false so Ghostty (or Metal) can read back from the framebuffer.
            metalLayer.framebufferOnly = false
            metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            return metalLayer
        }

        // MARK: - NSView lifecycle

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                isFocused = true
                cSurface.map { ghostty_surface_set_focus($0, true) }
            }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                isFocused = false
                cSurface.map { ghostty_surface_set_focus($0, false) }
            }
            return result
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }

            // Update layer scale factor.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()

            // Notify Ghostty of the content scale.
            if let surface = cSurface {
                let scale = window.backingScaleFactor
                ghostty_surface_set_content_scale(surface, scale, scale)
            }

            // Send initial size.
            sendCurrentSize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            guard let window else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()

            guard let surface = cSurface else { return }
            let fbFrame = convertToBacking(frame)
            let xScale = fbFrame.size.width / frame.size.width
            let yScale = fbFrame.size.height / frame.size.height
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            sendCurrentSize()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            sendCurrentSize()
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            sendCurrentSize()
        }

        override func updateTrackingAreas() {
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            canHandleAlasDrop(from: sender.draggingPasteboard) ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            handleAlasDrop(from: sender.draggingPasteboard)
        }

        private func canHandleAlasDrop(from pasteboard: NSPasteboard) -> Bool {
            guard surfaceIO != nil,
                  let data = pasteboard.data(forType: .alasDropPayload)
            else { return false }
            return AlasDropPayload.decode(data) != nil
        }

        @discardableResult
        func handleAlasDrop(from pasteboard: NSPasteboard) -> Bool {
            guard let io = surfaceIO,
                  let data = pasteboard.data(forType: .alasDropPayload),
                  let payload = AlasDropPayload.decode(data)
            else { return false }
            window?.makeFirstResponder(self)
            io.sendText(payload.terminalText)
            return true
        }

        // Ghostty performs its own Metal rendering; we just trigger a draw call.
        override func draw(_ dirtyRect: NSRect) {
            cSurface.map { ghostty_surface_draw($0) }
        }

        // MARK: - Size helpers

        private func sendCurrentSize() {
            guard let surface = cSurface, let window else { return }
            let backing = convertToBacking(bounds)
            let scale = window.backingScaleFactor
            _ = scale // scale already baked into backing size via convertToBacking
            ghostty_surface_set_size(
                surface,
                UInt32(max(1, backing.width)),
                UInt32(max(1, backing.height))
            )
        }

        // MARK: - Public API

        /// Foreground process pid in the surface's PTY (or nil if surface or pid unavailable).
        /// `cSurface` is nonisolated(unsafe) — Ghostty's foreground-pid read is a safe
        /// atomic query and does not mutate surface state, so we can call it off-main.
        nonisolated var foregroundPid: pid_t? {
            guard let surface = cSurface else { return nil }
            let pid = ghostty_surface_foreground_pid(surface)
            guard pid > 0 else { return nil }
            return pid_t(truncatingIfNeeded: pid)
        }

        /// Inject text directly into the PTY (e.g. for paste or synthetic input).
        func sendText(_ text: String) {
            surfaceIO?.sendText(text)
        }

        /// Apply a cursor shape from a Ghostty mouse_shape action.
        func applyCursorShape(_ shape: ghostty_action_mouse_shape_e) {
            switch shape {
            case GHOSTTY_MOUSE_SHAPE_TEXT:    NSCursor.iBeam.set()
            case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
            case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: NSCursor.crosshair.set()
            case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: NSCursor.operationNotAllowed.set()
            case GHOSTTY_MOUSE_SHAPE_GRAB:    NSCursor.openHand.set()
            case GHOSTTY_MOUSE_SHAPE_GRABBING: NSCursor.closedHand.set()
            case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: NSCursor.resizeLeftRight.set()
            case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: NSCursor.resizeUpDown.set()
            case GHOSTTY_MOUSE_SHAPE_W_RESIZE: NSCursor.resizeLeft.set()
            case GHOSTTY_MOUSE_SHAPE_E_RESIZE: NSCursor.resizeRight.set()
            case GHOSTTY_MOUSE_SHAPE_N_RESIZE: NSCursor.resizeUp.set()
            case GHOSTTY_MOUSE_SHAPE_S_RESIZE: NSCursor.resizeDown.set()
            default: NSCursor.arrow.set()
            }
        }

        // MARK: - Font size (FontSizeResponder)

        // The app's menu shortcuts ⌘= / ⌘- / ⌘0 walk the responder chain via
        // `NSApp.sendAction(...)`. Without these, the menu would intercept the
        // keystroke before Ghostty's `performKeyEquivalent` could see it and
        // terminal users would lose font zoom entirely. We forward each menu
        // action straight to Ghostty's named binding action so behavior matches
        // pressing the shortcut directly inside the surface.

        @objc func increaseFontSize(_ sender: Any?) { runBindingAction("increase_font_size:1") }
        @objc func decreaseFontSize(_ sender: Any?) { runBindingAction("decrease_font_size:1") }
        @objc func resetFontSize(_ sender: Any?)    { runBindingAction("reset_font_size") }

        private func runBindingAction(_ action: String) {
            guard let surface = cSurface else { return }
            action.withCString { ptr in
                _ = ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
            }
        }

        // MARK: - Keyboard events

        override func keyDown(with event: NSEvent) {
            guard let surface = cSurface, surfaceIO != nil else { return }

            let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            // Translation-modifier dance (same as before).
            let rawMods = alasGhosttyMods(event.modifierFlags)
            let translatedGhosttyMods = ghostty_surface_key_translation_mods(surface, rawMods)
            let translatedAppKitMods = alasAppKitModifierFlags(from: translatedGhosttyMods)
            var translationFlags = event.modifierFlags
            for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
                if translatedAppKitMods.contains(flag) {
                    translationFlags.insert(flag)
                } else {
                    translationFlags.remove(flag)
                }
            }

            let translationEvent: NSEvent
            if translationFlags == event.modifierFlags {
                translationEvent = event
            } else {
                translationEvent = NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationFlags) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
            }

            // 0. While an IME composition is already active, just let AppKit handle it.
            if hasMarkedText() {
                interpretKeyEvents([translationEvent])
                return
            }

            // 1. Record pre-IME state.
            let markedTextBefore = hasMarkedText()

            // 2. Initialise the accumulator so insertText can collect text.
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }

            // 3. Let AppKit handle dead keys, IME, and selectors.
            interpretKeyEvents([translationEvent])

            // 4. Determine whether we are still composing.
            let composing = hasMarkedText() || markedTextBefore

            // 5. If we had preedit and it committed, send the committed text first.
            if markedTextBefore,
               let accumulator = keyTextAccumulator,
               !accumulator.isEmpty {
                for text in accumulator {
                    if SurfaceView.shouldSuppressComposingControlInput(text, composing: composing) {
                        continue
                    }
                    _ = keyAction(action, event: event, translationEvent: translationEvent, text: text, composing: composing)
                }

                // If the key should still reach the terminal after committing preedit,
                // send a raw key event with composing=false.  For simplicity we replay
                // all non-modifier keys here; upstream is more selective.
                _ = keyAction(action, event: event, translationEvent: translationEvent, composing: false)
                return
            }

            // 6. If interpretKeyEvents committed text, send it.
            if let accumulator = keyTextAccumulator, !accumulator.isEmpty {
                for text in accumulator {
                    if SurfaceView.shouldSuppressComposingControlInput(text, composing: composing) {
                        continue
                    }
                    _ = keyAction(action, event: event, translationEvent: translationEvent, text: text, composing: composing)
                }
                return
            }

            // 7. No text produced — raw key event.
            if SurfaceView.shouldSuppressComposingControlInput(event.characters, composing: composing) {
                return
            }
            _ = keyAction(action, event: event, translationEvent: translationEvent, text: translationEvent.alasGhosttyForwardedText, composing: composing)
        }

        /// Send a key event to the Ghostty surface, respecting composition.
        private func keyAction(
            _ action: ghostty_input_action_e,
            event: NSEvent,
            translationEvent: NSEvent? = nil,
            text: String? = nil,
            composing: Bool = false
        ) -> Bool {
            guard let io = surfaceIO else { return false }

            var keyEv = event.alasGhosttyKeyEvent(
                action,
                translationFlags: translationEvent?.modifierFlags
            )
            keyEv.composing = composing

            if let text, !text.isEmpty,
               let first = text.utf8.first, first >= 0x20 {
                return text.withCString { ptr -> Bool in
                    keyEv.text = ptr
                    return io.sendKey(keyEv)
                }
            }
            return io.sendKey(keyEv)
        }

        /// Return true if a text string contains only bare control characters
        /// that the IME produced while composing. We drop these so they don't
        /// leak into the terminal.
        static func shouldSuppressComposingControlInput(
            _ text: String?, composing: Bool
        ) -> Bool {
            guard composing, let text else { return false }
            // A single control character produced during composition should be
            // suppressed.  Any printable text or multi-character text is fine.
            guard text.count == 1,
                  let scalar = text.unicodeScalars.first,
                  scalar.value < 0x20 else { return false }
            return true
        }

        override func keyUp(with event: NSEvent) {
            guard let io = surfaceIO else { return }
            let keyEv = event.alasGhosttyKeyEvent(GHOSTTY_ACTION_RELEASE)
            _ = io.sendKey(keyEv)
        }

        override func flagsChanged(with event: NSEvent) {
            guard let io = surfaceIO else { return }

            // Don't disturb an active IME composition with modifier noise.
            if hasMarkedText() { return }

            // Determine which modifier changed and whether it was pressed or released.
            let mod: UInt32
            switch event.keyCode {
            case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
            case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
            case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
            case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
            case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
            default: return
            }

            let mods = alasGhosttyMods(event.modifierFlags)
            let action: ghostty_input_action_e = (mods.rawValue & mod != 0)
                ? GHOSTTY_ACTION_PRESS
                : GHOSTTY_ACTION_RELEASE

            let keyEv = event.alasGhosttyKeyEvent(action)
            _ = io.sendKey(keyEv)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown, isFocused else { return false }
            if Self.isReservedAppKeyEquivalent(event) { return false }

            // Pass Cmd+key and Ctrl+key through to Ghostty if we're focused.
            let flags = event.modifierFlags
            if flags.contains(.command) || flags.contains(.control) {
                keyDown(with: event)
                return true
            }
            return false
        }

        static func isReservedAppKeyEquivalent(_ event: NSEvent) -> Bool {
            isReservedAppKeyEquivalent(event, in: ShortcutReservations.current)
        }

        /// Test seam: same logic against an explicit reservation set so unit
        /// tests don't depend on the global registry state.
        static func isReservedAppKeyEquivalent(
            _ event: NSEvent,
            in reservations: Set<ShortcutBinding>
        ) -> Bool {
            guard event.type == .keyDown else { return false }
            guard let binding = ShortcutRecorderSession.binding(from: event) else { return false }
            return reservations.contains(binding)
        }

        // MARK: - NSTextInputClient doCommand

        // NSResponder declares doCommand(by:); the NSTextInputClient extension
        // conforms our class to the protocol, but the override of NSResponder's
        // method lives here in the main class body for conventional placement.
        // The raw keyDown was already delivered to Ghostty before
        // interpretKeyEvents fired, so we intentionally swallow the selector.
        // Calling super would let AppKit beep or perform a default behavior
        // that is wrong for a terminal.
        override func doCommand(by selector: Selector) {
            // intentionally empty
        }

        // MARK: - Mouse events

        override func mouseDown(with event: NSEvent) {
            guard let surface = cSurface else { return }
            let mods = alasGhosttyMods(event.modifierFlags)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func mouseUp(with event: NSEvent) {
            guard let surface = cSurface else { return }
            let mods = alasGhosttyMods(event.modifierFlags)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let surface = cSurface else { return super.rightMouseDown(with: event) }
            let mods = alasGhosttyMods(event.modifierFlags)
            if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
                super.rightMouseDown(with: event)
            }
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let surface = cSurface else { return super.rightMouseUp(with: event) }
            let mods = alasGhosttyMods(event.modifierFlags)
            if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
                super.rightMouseUp(with: event)
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let surface = cSurface else { return }
            let mods = alasGhosttyMods(event.modifierFlags)
            let button = alasGhosttyMouseButton(event.buttonNumber)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button, mods)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let surface = cSurface else { return }
            let mods = alasGhosttyMods(event.modifierFlags)
            let button = alasGhosttyMouseButton(event.buttonNumber)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, mods)
        }

        override func mouseMoved(with event: NSEvent) {
            guard let surface = cSurface else { return }
            // Convert from window-space to view-space. NSView is bottom-left origin,
            // Ghostty expects top-left origin, so we flip Y.
            let pos = convert(event.locationInWindow, from: nil)
            let mods = alasGhosttyMods(event.modifierFlags)
            ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
        }

        override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
        override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
        override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

        override func mouseEntered(with event: NSEvent) {
            guard let surface = cSurface else { return }
            let pos = convert(event.locationInWindow, from: nil)
            let mods = alasGhosttyMods(event.modifierFlags)
            ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
        }

        override func mouseExited(with event: NSEvent) {
            guard let surface = cSurface else { return }
            let mods = alasGhosttyMods(event.modifierFlags)
            // Negative coordinates signal that the cursor left the viewport.
            ghostty_surface_mouse_pos(surface, -1, -1, mods)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let surface = cSurface else { return }

            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            let precise = event.hasPreciseScrollingDeltas

            if precise {
                // 2× multiplier per upstream — feels better.
                dx *= 2
                dy *= 2
            }

            // ghostty_input_scroll_mods_t is an int packed as: bit 0 = precise, bits 1-4 = momentum.
            var scrollMods: Int32 = 0
            if precise { scrollMods |= 1 }
            // Momentum phase (bits 1-4 correspond to ghostty_input_mouse_momentum_e values).
            let momentum = alasGhosttyMomentum(event.momentumPhase)
            scrollMods |= Int32(momentum.rawValue) << 1

            ghostty_surface_mouse_scroll(surface, Double(dx), Double(dy), scrollMods)
        }
    }
}

// MARK: - NSEvent key-translation helpers (ported from upstream NSEvent+Extension.swift)

extension NSEvent {
    /// Build a `ghostty_input_key_s` for the given action. Does NOT set `text` or `composing`.
    ///
    /// - Parameter translationFlags: AppKit modifiers used for text translation (may differ
    ///   from the physical event modifiers when Ghostty translates them for configs such as
    ///   `macos-option-as-alt`). Defaults to the event's own `modifierFlags`.
    func alasGhosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationFlags: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        // Ghostty uses the macOS virtual key code directly as `keycode`.
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = alasGhosttyMods(modifierFlags)

        // Consumed mods: the modifiers that contributed to the translated text.
        // Control and Command never contribute to character translation.
        let consumedFlags = (translationFlags ?? modifierFlags).subtracting([.control, .command])
        ev.consumed_mods = alasGhosttyMods(consumedFlags)

        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let scalar = chars.unicodeScalars.first {
                ev.unshifted_codepoint = scalar.value
            }
        }
        return ev
    }

    /// The text string to pass as `ghostty_input_key_s.text`, filtering out
    /// control characters and PUA function-key ranges.
    ///
    /// For Ctrl-modified keys (e.g. Ctrl+A), we strip Ctrl and return the
    /// layout-translated character so that alternative layouts (Dvorak etc.)
    /// produce the correct control key.
    ///
    /// For Shift-modified keys that produce control characters natively
    /// (e.g. Shift+Enter → \\r, Shift+Tab → \\t), we return nil so Ghostty
    /// encodes them from keycode + mods. Otherwise Shift+Enter would be
    /// flattened to a plain Enter text payload.
    var alasGhosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                if modifierFlags.contains(.control) {
                    return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
                }
                return nil
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    /// Text payload to attach to the raw Ghostty key event before asking
    /// Ghostty whether it consumes the key. Printable text is safe here
    /// because unconsumed keys still fall through to AppKit's insertText path.
    var alasGhosttyForwardedText: String? {
        guard let text = alasGhosttyCharacters, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Modifier translation helpers

/// Convert Ghostty modifier bits back to AppKit `NSEvent.ModifierFlags`.
/// Used when Ghostty's `ghostty_surface_key_translation_mods` tells us
/// which modifiers should participate in character translation.
func alasAppKitModifierFlags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue   != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue    != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue     != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue   != 0 { flags.insert(.command) }
    if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue     != 0 { flags.insert(.capsLock) }
    return flags
}

// MARK: - Modifier translation (ported from upstream Ghostty.Input.swift)

func alasGhosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift)   { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option)  { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock){ mods |= GHOSTTY_MODS_CAPS.rawValue }

    let raw = flags.rawValue
    if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCTLKEYMASK)   != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERALTKEYMASK)   != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCMDKEYMASK)   != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(mods)
}

// MARK: - Mouse button mapping

private func alasGhosttyMouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
    switch buttonNumber {
    case 0: return GHOSTTY_MOUSE_LEFT
    case 1: return GHOSTTY_MOUSE_RIGHT
    case 2: return GHOSTTY_MOUSE_MIDDLE
    case 3: return GHOSTTY_MOUSE_FOUR
    case 4: return GHOSTTY_MOUSE_FIVE
    case 5: return GHOSTTY_MOUSE_SIX
    case 6: return GHOSTTY_MOUSE_SEVEN
    case 7: return GHOSTTY_MOUSE_EIGHT
    default: return GHOSTTY_MOUSE_UNKNOWN
    }
}

// MARK: - Scroll momentum mapping

private func alasGhosttyMomentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
    switch phase {
    case .began:        return GHOSTTY_MOUSE_MOMENTUM_BEGAN
    case .stationary:   return GHOSTTY_MOUSE_MOMENTUM_STATIONARY
    case .changed:      return GHOSTTY_MOUSE_MOMENTUM_CHANGED
    case .ended:        return GHOSTTY_MOUSE_MOMENTUM_ENDED
    case .cancelled:    return GHOSTTY_MOUSE_MOMENTUM_CANCELLED
    case .mayBegin:     return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
    default:            return GHOSTTY_MOUSE_MOMENTUM_NONE
    }
}

// MARK: - NSTextInputClient

extension AlasGhostty.SurfaceView: @preconcurrency NSTextInputClient {
    // State for tracking marked (composing) text. nil means "no composition active".
    private nonisolated(unsafe) static var markedTextKey: UInt8 = 0

    private var markedText: String? {
        get { objc_getAssociatedObject(self, &Self.markedTextKey) as? String }
        set { objc_setAssociatedObject(self, &Self.markedTextKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    // MARK: Query methods

    func hasMarkedText() -> Bool {
        return !(markedText ?? "").isEmpty
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard let marked = markedText, !marked.isEmpty else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: (marked as NSString).length)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }

    // MARK: Active methods — full bodies arrive in later tasks

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let a = string as? NSAttributedString { text = a.string }
        else { return }

        guard !text.isEmpty else { return }

        // If we're inside keyDown, accumulate so keyDown can decide
        // whether to send raw keycodes or the resolved text.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }

        // Outside keyDown (e.g. dictation, accessibility), send immediately.
        guard let io = surfaceIO else { return }
        io.sendText(text)
        markedText = nil
        io.setPreedit(nil)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let a = string as? NSAttributedString { text = a.string }
        else { return }

        guard let io = surfaceIO else { return }

        if text.isEmpty {
            markedText = nil
        } else {
            markedText = text
        }

        io.setPreedit(markedText)
    }

    func unmarkText() {
        if let marked = markedText, !marked.isEmpty {
            surfaceIO?.sendText(marked)
        }
        markedText = nil
        surfaceIO?.setPreedit(nil)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Ghostty reports the IME caret in top-left-origin view coordinates
        // (same convention used by mouseMoved which does `frame.height - y`).
        // AppKit's NSView coordinate system is bottom-left-origin, so flip
        // Y before converting to window/screen coordinates.
        guard let io = surfaceIO else { return .zero }
        let ghosttyRect = io.imePoint()
        let viewRect = NSRect(
            x: ghosttyRect.origin.x,
            y: frame.height - ghosttyRect.origin.y - ghosttyRect.size.height,
            width: ghosttyRect.size.width,
            height: ghosttyRect.size.height
        )
        guard let window else { return .zero }
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    // doCommand(by:) lives in SurfaceView's main class body (above) — Swift's
    // convention is to place NSResponder overrides on the class itself, not
    // in extensions. NSTextInputClient.doCommand(by:) is satisfied by that
    // override.
}
