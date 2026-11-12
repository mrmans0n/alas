import Testing
import AlasCore

struct DeviceTextInputTests {
    @Test func textBecomesKeyPressesWithShiftWhereNeeded() {
        guard case .keys(let presses) = DeviceTextInput.runs(for: "Hello, World!\n").first else {
            Issue.record("expected one key run")
            return
        }
        #expect(DeviceTextInput.runs(for: "Hello, World!\n").count == 1)
        #expect(presses.filter(\.shift).map(\.usage) == [0x0B, 0x1A, 0x1E]) // H, W, !
        #expect(presses.map(\.usage) == [
            0x0B, 0x08, 0x0F, 0x0F, 0x12, 0x36, 0x2C, // Hello,<space>
            0x1A, 0x12, 0x15, 0x0F, 0x07, 0x1E, 0x28, // World!<return>
        ])
    }

    /// Each run as "k:<typed text>" or "p:<pasted text>".
    private func shape(_ text: String) -> [String] {
        DeviceTextInput.runs(for: text).map { run in
            switch run {
            case .keys(let presses): "k:\(presses.count)"
            case .paste(let text): "p:\(text)"
            }
        }
    }

    @Test(arguments: [
        ("Café au lait\n", ["p:Café", "k:9"]),
        ("日本 語", ["p:日本 語"]),
        ("é", ["p:é"]),
        ("a ☕️ b", ["k:2", "p:☕️", "k:2"]),
        ("👋\nhi 👋", ["p:👋", "k:4", "p:👋"]),
        ("say (é)!", ["k:4", "p:(é)!"]),
    ])
    func charactersTheKeyboardLacksArePasted(text: String, runs: [String]) {
        #expect(shape(text) == runs)
    }
}
