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
    typealias FlagsCallback = ([ShortcutBinding.Modifier]) -> Void

    // `keyMonitor` and `flagsMonitor` hold opaque tokens from
    // `NSEvent.addLocalMonitorForEvents`. Marked `nonisolated(unsafe)` so the
    // (nonisolated) `deinit` can call `NSEvent.removeMonitor` on them; all live
    // accesses go through MainActor-isolated methods, so concurrent reads/writes
    // are not possible in practice.
    nonisolated(unsafe) private var keyMonitor: Any?
    nonisolated(unsafe) private var flagsMonitor: Any?
    private let onCapture: Callback
    private let onCancel: CancelCallback
    private let onFlagsChanged: FlagsCallback

    init(
        onCapture: @escaping Callback,
        onCancel: @escaping CancelCallback,
        onFlagsChanged: @escaping FlagsCallback = { _ in }
    ) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        self.onFlagsChanged = onFlagsChanged
    }

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            self.onFlagsChanged(Self.modifiers(from: event.modifierFlags))
            return event
        }
    }

    func stop() {
        teardownMonitors()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    private func teardownMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> [ShortcutBinding.Modifier] {
        var mods: [ShortcutBinding.Modifier] = []
        if flags.contains(.control) { mods.append(.control) }
        if flags.contains(.option)  { mods.append(.option) }
        if flags.contains(.shift)   { mods.append(.shift) }
        if flags.contains(.command) { mods.append(.command) }
        return mods
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
            guard ShortcutBinding.isSupportedLiteralKey(raw) else {
                return nil
            }
            key = raw
        }
        return ShortcutBinding(key: key, modifiers: mods)
    }
}
