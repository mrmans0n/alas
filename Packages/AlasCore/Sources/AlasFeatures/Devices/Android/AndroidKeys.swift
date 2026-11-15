/// Mac keys, as the USB HID usages the screen view sends, to Android keycodes.
public enum AndroidKeys {
    public static func keycode(forHIDUsage usage: UInt32) -> Int32? {
        switch usage {
        case 0x04...0x1D: Int32(29 + usage - 0x04) // A–Z
        case 0x1E...0x26: Int32(8 + usage - 0x1E) // 1–9
        case 0x27: 7 // 0
        case 0x3A...0x45: Int32(131 + usage - 0x3A) // F1–F12
        default: table[usage]
        }
    }

    private static let table: [UInt32: Int32] = [
        0x28: 66, 0x29: 111, 0x2A: 67, 0x2B: 61, 0x2C: 62, 0x2D: 69, 0x2E: 70, 0x2F: 71, 0x30: 72, 0x31: 73,
        0x33: 74, 0x34: 75, 0x35: 68, 0x36: 55, 0x37: 56, 0x38: 76, 0x39: 115,
        0x4A: 122, 0x4B: 92, 0x4C: 112, 0x4D: 123, 0x4E: 93, 0x4F: 22, 0x50: 21, 0x51: 20, 0x52: 19,
        0xE0: 113, 0xE1: 59, 0xE2: 57, 0xE3: 117, 0xE4: 114, 0xE5: 60, 0xE6: 58, 0xE7: 118,
    ]

    /// The gutter's buttons.
    public static func button(_ name: String) -> Int32? {
        switch name {
        case "back": 4
        case "home": 3
        case "app_switch": 187
        case "power": 26
        case "volume_up": 24
        case "volume_down": 25
        default: nil
        }
    }
}

/// Android's meta state for the modifiers held down.
public struct AndroidMetaState: Sendable {
    private var held: Set<UInt32> = []

    public init() {}

    /// Each modifier's `*_ON` bit and its side's bit.
    private static let bits: [UInt32: Int32] = [
        0xE0: 0x3000, // left control: CTRL_ON | CTRL_LEFT_ON
        0xE1: 0x41, // left shift: SHIFT_ON | SHIFT_LEFT_ON
        0xE2: 0x12, // left option: ALT_ON | ALT_LEFT_ON
        0xE3: 0x30000, // left command: META_ON | META_LEFT_ON
        0xE4: 0x5000, // right control
        0xE5: 0x81, // right shift
        0xE6: 0x22, // right option
        0xE7: 0x50000, // right command
    ]

    public var value: Int32 {
        held.reduce(0) { $0 | (Self.bits[$1] ?? 0) }
    }

    public mutating func update(hidUsage: UInt32, down: Bool) {
        guard Self.bits[hidUsage] != nil else { return }
        if down { held.insert(hidUsage) } else { held.remove(hidUsage) }
    }
}
