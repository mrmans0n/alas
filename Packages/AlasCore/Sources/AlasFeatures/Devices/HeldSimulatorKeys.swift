/// The keys and modifiers Alas has pressed in the simulator, so each press
/// gets exactly one release, also when the screen loses focus mid-press.
public struct HeldSimulatorKeys: Sendable {
    /// One HID key transition to send.
    public struct Event: Equatable, Sendable {
        public let usage: UInt32
        public let down: Bool

        public init(usage: UInt32, down: Bool) {
            self.usage = usage
            self.down = down
        }
    }

    /// NSEvent's device-dependent modifier bits (IOLLEvent.h), by Mac key code.
    private static let modifierBits: [UInt16: UInt] = [
        0x3B: 0x0001, // NX_DEVICELCTLKEYMASK
        0x38: 0x0002, // NX_DEVICELSHIFTKEYMASK
        0x3A: 0x0020, // NX_DEVICELALTKEYMASK
        0x3E: 0x2000, // NX_DEVICERCTLKEYMASK
        0x3C: 0x0004, // NX_DEVICERSHIFTKEYMASK
        0x3D: 0x0040, // NX_DEVICERALTKEYMASK
    ]

    private var keys: Set<UInt16> = []
    private var modifiers: Set<UInt16> = []

    public init() {}

    /// A key press, unless it carries Command (Alas keeps those), the simulator
    /// has no usage for it, or it is already down (the simulator repeats held keys).
    public mutating func keyDown(_ keyCode: UInt16, command: Bool) -> Event? {
        guard !command, let usage = HIDKeyboardUsage.usage(forKeyCode: keyCode),
              keys.insert(keyCode).inserted else { return nil }
        return Event(usage: usage, down: true)
    }

    /// The release of a key this sent down, whatever modifiers are held now.
    public mutating func keyUp(_ keyCode: UInt16) -> Event? {
        guard keys.remove(keyCode) != nil, let usage = HIDKeyboardUsage.usage(forKeyCode: keyCode) else { return nil }
        return Event(usage: usage, down: false)
    }

    /// A modifier's transition, read from the event's own modifier state
    /// (`NSEvent.modifierFlags.rawValue`) rather than toggled from what this
    /// saw. A modifier already down before the screen had focus is never sent.
    public mutating func modifierChanged(_ keyCode: UInt16, modifierFlags: UInt) -> Event? {
        guard let usage = HIDKeyboardUsage.usage(forModifierKeyCode: keyCode),
              let bit = Self.modifierBits[keyCode] else { return nil }
        let down = modifierFlags & bit != 0
        let changed = down ? modifiers.insert(keyCode).inserted : modifiers.remove(keyCode) != nil
        return changed ? Event(usage: usage, down: down) : nil
    }

    /// Releases for everything still down, which this then forgets.
    public mutating func releaseAll() -> [Event] {
        let events = (keys.sorted().compactMap { HIDKeyboardUsage.usage(forKeyCode: $0) }
            + modifiers.sorted().compactMap { HIDKeyboardUsage.usage(forModifierKeyCode: $0) })
            .map { Event(usage: $0, down: false) }
        keys.removeAll()
        modifiers.removeAll()
        return events
    }
}
