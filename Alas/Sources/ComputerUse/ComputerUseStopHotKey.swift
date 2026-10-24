import AlasCore
import Carbon.HIToolbox
import CoreGraphics
import os

/// A system-wide hot key, through Carbon's `RegisterEventHotKey`: it fires while another app is
/// frontmost and needs no Accessibility or Input Monitoring grant.
@MainActor
final class ComputerUseStopHotKey {
    private static let log = Logger(subsystem: "io.nlopez.alas", category: "computer-use")
    /// "ALSC": tells this hot key's events apart from any other the process registers.
    nonisolated private static let signature: OSType = 0x414C_5343

    private let onPress: @MainActor () -> Void
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var registered: ShortcutBinding?

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        installHandler()
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Unregisters the previous hot key and registers `binding`, or none when nil.
    func update(_ binding: ShortcutBinding?) {
        guard binding != registered else { return }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registered = nil
        guard let binding else { return }
        guard let keyCode = Self.keyCode(for: binding) else {
            Self.log.error("Stop shortcut \(binding.displayString, privacy: .public) has no key code")
            return
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), Self.modifiers(for: binding.modifiers),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            // Another app may own the combo already.
            Self.log.error("Could not register stop shortcut \(binding.displayString, privacy: .public): \(status)")
            return
        }
        hotKey = ref
        registered = binding
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard read == noErr, id.signature == ComputerUseStopHotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // The application event target dispatches on the main thread.
            let hotKey = Unmanaged<ComputerUseStopHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.onPress() }
            return noErr
        }, 1, &spec, context, &handler)
        if status != noErr {
            Self.log.error("Could not install the stop shortcut handler: \(status)")
        }
    }

    private static let namedKeys: [String: ComputerUseKeyChord.NamedKey] = [
        "return": .return, "tab": .tab, "space": .space, "delete": .delete, "escape": .escape,
        "leftArrow": .left, "rightArrow": .right, "upArrow": .up, "downArrow": .down,
    ]

    private static func keyCode(for binding: ShortcutBinding) -> CGKeyCode? {
        if let named = namedKeys[binding.key] {
            return ComputerUseInputPoster.keyCode(for: .named(named))
        }
        guard binding.key.count == 1, let character = binding.key.first else { return nil }
        return ComputerUseInputPoster.keyCode(for: .character(character))
    }

    private static func modifiers(for modifiers: [ShortcutBinding.Modifier]) -> UInt32 {
        modifiers.reduce(0) { mask, modifier in
            switch modifier {
            case .command: mask | UInt32(cmdKey)
            case .shift: mask | UInt32(shiftKey)
            case .option: mask | UInt32(optionKey)
            case .control: mask | UInt32(controlKey)
            }
        }
    }
}
