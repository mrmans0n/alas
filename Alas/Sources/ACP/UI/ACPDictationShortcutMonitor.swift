import AppKit

/// Routes the Dictate shortcut to the focused chat composer. Menu key
/// equivalents only report the press, and hold-to-talk needs the release
/// too, so this watches key and modifier transitions directly. Events that
/// aren't the shortcut, or arrive while no composer has focus, pass through
/// untouched.
@MainActor
enum ACPDictationShortcutMonitor {
    private static var monitor: Any?
    private static var binding: @MainActor () -> ShortcutBinding? = { nil }
    /// The composer the current press went to, until the shortcut is
    /// released. The release goes there even if focus moved meanwhile.
    private static weak var pressedTextView: ACPNSTextView?
    /// The shortcut's key while it's physically down after a handled press.
    /// Outlives the release when a modifier comes up first, so the key's
    /// repeats and key-up still never reach the text.
    private static var heldKey: String?

    /// The effective binding, for help text. Nil when unbound.
    static var currentBinding: ShortcutBinding? { binding() }

    static func install(binding: @escaping @MainActor () -> ShortcutBinding?) {
        self.binding = binding
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
        // Local monitors see nothing once another app is active, so a hold
        // in progress would never hear its release and keep recording.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                heldKey = nil
                finishPress(.interrupted)
            }
        }
    }

    /// Returns true when the event belonged to the shortcut and is consumed.
    private static func handle(_ event: NSEvent) -> Bool {
        guard let binding = binding() else { return false }
        if event.type == .flagsChanged {
            // Letting go of any of the shortcut's modifiers ends a hold, even
            // with the key still down. Modifier changes always pass through.
            let held = Set(ShortcutRecorderSession.modifiers(from: event.modifierFlags))
            if !Set(binding.modifiers).isSubset(of: held) { finishPress(.released(at: event.timestamp)) }
            return false
        }
        guard let pressed = ShortcutRecorderSession.binding(from: event), pressed.key == binding.key else {
            return false
        }
        if event.type == .keyUp {
            guard heldKey == pressed.key else { return false }
            heldKey = nil
            finishPress(.released(at: event.timestamp))
            return true
        }
        if event.isARepeat { return heldKey == pressed.key }
        heldKey = nil
        guard Set(pressed.modifiers) == Set(binding.modifiers),
              let textView = event.window?.firstResponder as? ACPNSTextView,
              textView.isEditable, !textView.hasMarkedText()
        else { return false }
        pressedTextView = textView
        heldKey = pressed.key
        textView.onDictationShortcut(.pressed(at: event.timestamp))
        return true
    }

    private static func finishPress(_ event: ACPDictationShortcutEvent) {
        guard let textView = pressedTextView else { return }
        pressedTextView = nil
        textView.onDictationShortcut(event)
    }
}
