import AlasCore
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Observation
import os

/// A system-wide hot key, through Carbon's `RegisterEventHotKey`: it fires while another app is
/// frontmost and needs no Accessibility or Input Monitoring grant. A combination another app holds
/// is tried again while it is requested: when the status item's menu opens, when an app quits,
/// and every `retryInterval`.
@MainActor
@Observable
final class ComputerUseStopHotKey {
    private static let log = Logger(subsystem: "io.nlopez.alas", category: "computer-use")
    /// "ALSC": tells this hot key's events apart from any other the process registers.
    nonisolated private static let signature: OSType = 0x414C_5343

    static let retryInterval: Duration = .seconds(10)

    @ObservationIgnored private let onPress: @MainActor () -> Void
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    /// The binding last passed to `update`, so config saves that don't change it do nothing.
    @ObservationIgnored private var requested: ShortcutBinding?
    /// The last binding a failure was logged for, so repeated drives don't log it again.
    @ObservationIgnored private var loggedFailure: ShortcutBinding?
    @ObservationIgnored private var handlerInstalled = false
    /// The Carbon status of the last failed registration; nil when it never reached Carbon.
    @ObservationIgnored private var failedStatus: Int32?
    /// Live while a taken binding waits to be tried again.
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    /// Called when a newly requested binding is held by another app, once per request: not again
    /// for the retries.
    @ObservationIgnored var onTaken: (@MainActor (ShortcutBinding) -> Void)?

    /// Why the requested binding isn't live, for the status item's menu; nil when it is
    /// registered or none is requested.
    private(set) var unavailableReason: String?

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        installHandler()
    }

    isolated deinit {
        stopRetrying()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Unregisters the previous hot key and registers `binding`, or none when nil.
    func update(_ binding: ShortcutBinding?) {
        guard binding != requested else { return }
        requested = binding
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        unavailableReason = nil
        failedStatus = nil
        guard let binding else {
            stopRetrying()
            return
        }
        register(binding)
        // Once per registration request, not per retry: a drive requests its binding when it
        // starts, though a binding change mid-drive requests it again.
        if isTaken { onTaken?(binding) } else { stopRetrying() }
    }

    /// Registers the requested binding again if another app held it.
    func retryIfTaken() {
        guard let requested, isTaken else { return }
        register(requested)
    }

    private var isTaken: Bool {
        hotKey == nil && ComputerUseStopShortcut.retries(status: failedStatus, driverActive: requested != nil)
    }

    private func register(_ binding: ShortcutBinding) {
        failedStatus = nil
        guard handlerInstalled else {
            fail(binding, reason: "Stop shortcut unavailable", log: "handler is not installed")
            return
        }
        guard let keyCode = Self.keyCode(for: binding) else {
            fail(
                binding, reason: "Stop shortcut \(Self.inline(binding)) can't be used as a system-wide shortcut",
                log: "has no key code"
            )
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
            failedStatus = status
            fail(
                binding, reason: "Stop shortcut unavailable: another app uses \(Self.inline(binding))",
                log: "could not be registered (\(status))"
            )
            if isTaken { startRetrying() }
            return
        }
        hotKey = ref
        stopRetrying()
        if unavailableReason != nil { unavailableReason = nil }
    }

    /// The holder quitting is the usual way a combination frees up; the timer covers one that
    /// lets it go without quitting.
    private func startRetrying() {
        if terminationObserver == nil {
            terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryIfTaken() }
            }
        }
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.retryInterval)
                guard !Task.isCancelled, let self else { return }
                self.retryIfTaken()
            }
        }
    }

    private func stopRetrying() {
        retryTask?.cancel()
        retryTask = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
    }

    /// The transcript line for a drive whose Stop shortcut another app holds.
    static func takenNotice(_ binding: ShortcutBinding) -> String {
        "\(inline(binding)) is used by another app; stop computer use from the menu bar item."
    }

    private func fail(_ binding: ShortcutBinding, reason: String, log: String) {
        // Unchanged on a retry, so observers aren't woken every `retryInterval`.
        if unavailableReason != reason { unavailableReason = reason }
        guard loggedFailure != binding else { return }
        loggedFailure = binding
        Self.log.error("Stop shortcut \(binding.displayString, privacy: .public) \(log, privacy: .public)")
    }

    /// "⌃⌥⌘." rather than the chip's spaced "⌃ ⌥ ⌘ .", to read inside a sentence.
    private static func inline(_ binding: ShortcutBinding) -> String {
        binding.displayString.replacingOccurrences(of: " ", with: "")
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
        handlerInstalled = status == noErr
        if !handlerInstalled {
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
