import AlasCore
import Testing

struct HeldSimulatorKeysTests {
    static let delete: UInt16 = 0x33
    static let leftShift: UInt16 = 0x38
    static let rightShift: UInt16 = 0x3C
    /// NSEvent's device-dependent modifier bits (`NX_DEVICELSHIFTKEYMASK`, `NX_DEVICERSHIFTKEYMASK`).
    static let leftShiftBit: UInt = 0x2
    static let rightShiftBit: UInt = 0x4

    /// The simulator repeats a held key itself, so a lost key-up keeps it deleting.
    @Test func keysStillDownWhenFocusLeavesAreReleased() {
        var held = HeldSimulatorKeys()
        #expect(held.keyDown(Self.delete, command: false) == .init(usage: 0x2A, down: true))
        #expect(held.keyDown(Self.delete, command: false) == nil)
        #expect(held.releaseAll() == [.init(usage: 0x2A, down: false)])
        #expect(held.keyUp(Self.delete) == nil)
    }

    @Test func aKeyReleasedAfterCommandWasPressedStillLiftsInTheSimulator() {
        var held = HeldSimulatorKeys()
        #expect(held.keyDown(0x00, command: true) == nil)
        #expect(held.keyUp(0x00) == nil)
        #expect(held.keyDown(0x00, command: false) == .init(usage: 0x04, down: true))
        #expect(held.keyUp(0x00) == .init(usage: 0x04, down: false))
    }

    /// Shift was down before the screen got focus: its release is not a press.
    @Test func aModifierHeldBeforeFocusIsNotSentWhenReleased() {
        var held = HeldSimulatorKeys()
        #expect(held.modifierChanged(Self.leftShift, modifierFlags: 0) == nil)
        #expect(held.releaseAll().isEmpty)
    }

    @Test func eachSideOfAModifierFollowsItsOwnBit() {
        var held = HeldSimulatorKeys()
        #expect(held.modifierChanged(Self.leftShift, modifierFlags: Self.leftShiftBit) == .init(usage: 0xE1, down: true))
        #expect(held.modifierChanged(Self.rightShift, modifierFlags: Self.leftShiftBit | Self.rightShiftBit)
            == .init(usage: 0xE5, down: true))
        #expect(held.modifierChanged(Self.leftShift, modifierFlags: Self.rightShiftBit) == .init(usage: 0xE1, down: false))
        #expect(held.releaseAll() == [.init(usage: 0xE5, down: false)])
    }
}
