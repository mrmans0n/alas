import AppKit

/// Routes the Dictate shortcut to the focused chat composer. Menu key
/// equivalents only report the press, and hold-to-talk needs the release
/// too, so this watches key-down and key-up directly. Events that aren't the
/// shortcut, or arrive while no composer has focus, pass through untouched.
@MainActor
enum ACPDictationShortcutMonitor {
    private static var monitor: Any?
    private static var binding: @MainActor () -> ShortcutBinding? = { nil }
    /// The composer the current press went to. Its release goes there even
    /// if focus moved while the key was held.
    private static weak var pressedTextView: ACPNSTextView?

    /// The effective binding, for help text. Nil when unbound.
    static var currentBinding: ShortcutBinding? { binding() }

    static func install(binding: @escaping @MainActor () -> ShortcutBinding?) {
        self.binding = binding
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    /// Returns true when the event was the shortcut and has been handled.
    private static func handle(_ event: NSEvent) -> Bool {
        guard let binding = binding(),
              let pressed = ShortcutRecorderSession.binding(from: event),
              pressed.key == binding.key
        else { return false }
        if event.type == .keyUp {
            guard let textView = pressedTextView else { return false }
            pressedTextView = nil
            textView.onDictationShortcut(.released(at: event.timestamp))
            return true
        }
        // Repeats while held would otherwise type the key, even after the
        // modifiers are let go.
        if event.isARepeat { return pressedTextView != nil }
        guard Set(pressed.modifiers) == Set(binding.modifiers),
              let textView = event.window?.firstResponder as? ACPNSTextView,
              textView.isEditable, !textView.hasMarkedText()
        else { return false }
        pressedTextView = textView
        textView.onDictationShortcut(.pressed(at: event.timestamp))
        return true
    }
}
