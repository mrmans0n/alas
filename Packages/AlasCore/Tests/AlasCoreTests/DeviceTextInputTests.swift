import Testing
import AlasCore

struct DeviceTextInputTests {
    @Test func textBecomesKeyPressesWithShiftWhereNeeded() throws {
        let presses = try DeviceTextInput.presses(for: "Hello, World!\n").get()
        #expect(presses.filter(\.shift).map(\.usage) == [0x0B, 0x1A, 0x1E]) // H, W, !
        #expect(presses.map(\.usage) == [
            0x0B, 0x08, 0x0F, 0x0F, 0x12, 0x36, 0x2C, // Hello,<space>
            0x1A, 0x12, 0x15, 0x0F, 0x07, 0x1E, 0x28, // World!<return>
        ])
    }

    @Test func stopsAtTheFirstCharacterItCannotType() {
        #expect(DeviceTextInput.presses(for: "café") == .failure(DeviceTextInputError(character: "é")))
    }
}
