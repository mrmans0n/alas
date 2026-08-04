import Testing
@testable import Alas

struct ShortcutRecorderValidationTests {
    @Test func rejectsBareLetter() {
        let b = ShortcutBinding(key: "p", modifiers: [])
        #expect(ShortcutRecorder.validate(b) == .needsModifier)
    }

    @Test func rejectsShiftOnlyLetter() {
        let b = ShortcutBinding(key: "p", modifiers: [.shift])
        #expect(ShortcutRecorder.validate(b) == .needsModifier)
    }

    @Test func acceptsShiftPlusCommand() {
        let b = ShortcutBinding(key: "p", modifiers: [.command, .shift])
        #expect(ShortcutRecorder.validate(b) == .ok)
    }

    @Test func acceptsControlOnlyArrow() {
        let b = ShortcutBinding(key: "leftArrow", modifiers: [.control])
        #expect(ShortcutRecorder.validate(b) == .ok)
    }

    @Test func rejectsReservedCommandQ() {
        let b = ShortcutBinding(key: "q", modifiers: [.command])
        #expect(ShortcutRecorder.validate(b) == .reserved)
    }

    @Test func rejectsReservedCommand1() {
        let b = ShortcutBinding(key: "1", modifiers: [.command])
        #expect(ShortcutRecorder.validate(b) == .reserved)
    }

    @Test func rejectsReservedReopenClosedTabShortcut() {
        let binding = ShortcutBinding(key: "t", modifiers: [.command, .shift])
        #expect(ShortcutRecorder.validate(binding) == .reserved)
    }

    @Test func acceptsCommandLetter() {
        let b = ShortcutBinding(key: "j", modifiers: [.command])
        #expect(ShortcutRecorder.validate(b) == .ok)
    }
}
