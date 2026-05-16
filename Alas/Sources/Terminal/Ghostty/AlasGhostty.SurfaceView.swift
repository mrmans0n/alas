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
import QuartzCore
import GhosttyKit

extension AlasGhostty {
    /// Terminal display view. Each session owns exactly one of these.
    @MainActor
    final class SurfaceView: NSView, FontSizeResponder {
        // MARK: - Public callbacks

        /// Called (on main thread) whenever the terminal title changes.
        var titleHandler: ((String) -> Void)?

        /// Called (on main thread) when the child process exits or the surface is closed.
        var processExitHandler: (() -> Void)?

        // Current working directory, derived from Ghostty's GHOSTTY_ACTION_PWD events
        // (which fire when the shell emits OSC 7). Nil until the shell reports one.
        private(set) var currentWorkingDirectory: URL?

        /// Fired on the main queue when the shell reports a new working directory.
        var cwdHandler: ((URL) -> Void)?

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

        /// Unretained back-reference to the owning App.
        private let app: App

        /// Whether the surface currently has keyboard focus.
        private var isFocused: Bool = false

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

            // Set up mouse tracking so we receive mouseMoved events.
            updateTrackingAreas()
        }

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
            guard let surface = cSurface else { return }
            let bytes = text.utf8.count
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(bytes))
            }
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
            guard let surface = cSurface else {
                interpretKeyEvents([event])
                return
            }

            let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            // Ask Ghostty which modifiers should be used for text translation.
            // This handles configs such as `macos-option-as-alt` correctly.
            let rawMods = alasGhosttyMods(event.modifierFlags)
            let translatedGhosttyMods = ghostty_surface_key_translation_mods(surface, rawMods)

            // Convert translated Ghostty mods back to AppKit flags so we can
            // derive the correct composed characters (e.g. Option+n → ~).
            let translatedAppKitMods = alasAppKitModifierFlags(from: translatedGhosttyMods)
            var translationFlags = event.modifierFlags
            for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
                if translatedAppKitMods.contains(flag) {
                    translationFlags.insert(flag)
                } else {
                    translationFlags.remove(flag)
                }
            }

            // If translation modifiers differ we must build a new event.
            // Reusing the original event when they're equal is required for
            // some IME behaviours (see upstream Ghostty comment).
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

            var keyEv = event.alasGhosttyKeyEvent(action, translationFlags: translationFlags)
            let chars = translationEvent.alasGhosttyCharacters

            if let chars {
                chars.withCString { ptr in
                    keyEv.text = ptr
                    _ = ghostty_surface_key(surface, keyEv)
                }
            } else {
                _ = ghostty_surface_key(surface, keyEv)
            }
        }

        override func keyUp(with event: NSEvent) {
            guard let surface = cSurface else { return }
            let keyEv = event.alasGhosttyKeyEvent(GHOSTTY_ACTION_RELEASE)
            _ = ghostty_surface_key(surface, keyEv)
        }

        override func flagsChanged(with event: NSEvent) {
            guard let surface = cSurface else { return }

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
            _ = ghostty_surface_key(surface, keyEv)
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
            guard event.type == .keyDown else { return false }

            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // ⌘T — reserved for the app's New Terminal Tab.
            if flags == .command && chars == "t" { return true }
            // ⌘1..⌘9 — reserved for app tab switching.
            if flags == .command && ("1"..."9").contains(chars) { return true }
            // ⌘D / ⇧⌘D — Split Right / Split Down.
            if flags == .command && chars == "d" { return true }
            if flags == [.command, .shift] && chars == "d" { return true }
            // ⌘W — Close Pane / Close Tab (AppState decides).
            if flags == .command && chars == "w" { return true }
            // Arrow shortcuts: focus (⌥⌘) and resize (⌃⌘).
            let arrows: Set<UInt16> = [123, 124, 125, 126]  // left, right, down, up
            if (flags == [.command, .option] || flags == [.command, .control])
                && arrows.contains(event.keyCode) {
                return true
            }
            return false
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
