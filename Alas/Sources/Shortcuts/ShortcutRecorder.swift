import AppKit
import SwiftUI

enum ShortcutRecorderValidation: Equatable, Sendable {
    case ok
    case needsModifier
    case reserved
}

enum ShortcutRecorder {
    /// Pure validation against rules in the spec:
    /// - must include at least one of ⌘ ⌥ ⌃
    /// - shift alone with a letter is not enough (would shadow typing)
    /// - reserved bindings are rejected outright
    static func validate(_ binding: ShortcutBinding) -> ShortcutRecorderValidation {
        if ShortcutAction.reservedBindings.contains(binding) {
            return .reserved
        }
        let hasStrongModifier = binding.modifiers.contains(.command)
            || binding.modifiers.contains(.option)
            || binding.modifiers.contains(.control)
        guard hasStrongModifier else { return .needsModifier }
        return .ok
    }
}

/// Live key-capture session. Install one while a chip is in recording state,
/// uninstall on commit/cancel. The callback is invoked on the main queue for
/// each captured key-down event (after validation in the UI layer).
@MainActor
final class ShortcutRecorderSession {
    typealias Callback = (ShortcutBinding) -> Void
    typealias CancelCallback = () -> Void

    // `monitor` holds an opaque token from `NSEvent.addLocalMonitorForEvents`.
    // Marked `nonisolated(unsafe)` so the (nonisolated) `deinit` can call
    // `NSEvent.removeMonitor` on it; all live accesses go through MainActor-
    // isolated methods, so concurrent reads/writes are not possible in practice.
    nonisolated(unsafe) private var monitor: Any?
    private let onCapture: Callback
    private let onCancel: CancelCallback

    init(onCapture: @escaping Callback, onCancel: @escaping CancelCallback) {
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {  // Escape
                self.onCancel()
                return nil
            }
            if let binding = Self.binding(from: event) {
                self.onCapture(binding)
                return nil  // swallow — don't propagate to the app
            }
            return event
        }
    }

    func stop() {
        teardownMonitor()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func teardownMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Translate an NSEvent.keyDown into a ShortcutBinding, or nil if the
    /// event isn't recordable (e.g. modifier-only).
    static func binding(from event: NSEvent) -> ShortcutBinding? {
        let flags = event.modifierFlags
        var mods: [ShortcutBinding.Modifier] = []
        if flags.contains(.command) { mods.append(.command) }
        if flags.contains(.option)  { mods.append(.option) }
        if flags.contains(.control) { mods.append(.control) }
        if flags.contains(.shift)   { mods.append(.shift) }

        let key: String
        switch event.keyCode {
        case 36:  key = "return"
        case 48:  key = "tab"
        case 49:  key = "space"
        case 51:  key = "delete"
        case 53:  key = "escape"
        case 123: key = "leftArrow"
        case 124: key = "rightArrow"
        case 125: key = "downArrow"
        case 126: key = "upArrow"
        default:
            let raw = (event.charactersIgnoringModifiers ?? "").lowercased()
            guard !raw.isEmpty, raw.first?.isLetter == true || "0123456789-=,.;'/[]\\`".contains(raw) else {
                return nil
            }
            key = raw
        }
        return ShortcutBinding(key: key, modifiers: mods)
    }
}
