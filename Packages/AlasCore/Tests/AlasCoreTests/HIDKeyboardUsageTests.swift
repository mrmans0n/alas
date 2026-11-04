import AlasCore
import Testing

struct HIDKeyboardUsageTests {
    @Test(arguments: [
        (UInt16(0x00), UInt32(0x04) as UInt32?), // A
        (0x1D, 0x27),                            // 0
        (0x24, 0x28),                            // Return
        (0x33, 0x2A),                            // Delete (backspace)
        (0x7B, 0x50),                            // Left arrow
        (0x7A, nil),                             // F1, not mapped
    ] as [(UInt16, UInt32?)])
    func keysMapByPosition(keyCode: UInt16, usage: UInt32?) {
        #expect(HIDKeyboardUsage.usage(forKeyCode: keyCode) == usage)
    }

    @Test(arguments: [
        (UInt16(0x38), UInt32(0xE1) as UInt32?), // Shift
        (0x3B, 0xE0),                            // Control
        (0x3D, 0xE6),                            // Right Option
        (0x37, nil),                             // Command stays with Alas
        (0x36, nil),                             // Right Command
    ] as [(UInt16, UInt32?)])
    func commandIsTheOnlyModifierKeptFromTheSimulator(keyCode: UInt16, usage: UInt32?) {
        #expect(HIDKeyboardUsage.usage(forModifierKeyCode: keyCode) == usage)
    }
}
