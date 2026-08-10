import AppKit
import GhosttyKit
import Testing
@testable import Alas

/// Records calls made by SurfaceView to the Ghostty surface, so tests can
/// drive NSTextInputClient methods without standing up a real surface.
@MainActor
final class FakeGhosttySurfaceIO: GhosttySurfaceIO {
    enum Call: Equatable {
        case key(action: UInt32, keycode: UInt32, mods: UInt32, text: String?, composing: Bool)
        case text(String)
        case preedit(String?)
    }

    private(set) var calls: [Call] = []
    var keyConsumed: Bool = false
    var imePointRect: CGRect = CGRect(x: 0, y: 0, width: 0, height: 0)

    func sendKey(_ event: ghostty_input_key_s) -> Bool {
        let textStr: String? = event.text.map { String(cString: $0) }
        calls.append(.key(
            action: event.action.rawValue,
            keycode: event.keycode,
            mods: event.mods.rawValue,
            text: textStr,
            composing: event.composing
        ))
        return keyConsumed
    }

    func sendText(_ text: String) {
        calls.append(.text(text))
    }

    func setPreedit(_ text: String?) {
        calls.append(.preedit(text))
    }

    func clearCalls() {
        calls.removeAll()
    }

    func imePoint() -> CGRect {
        return imePointRect
    }
}

/// Tests for the NSEvent keyboard-translation helpers that feed Ghostty.
/// These exercise the pure modifier/character logic without needing a live
/// Ghostty surface.
struct SurfaceViewKeyboardTests {
    // MARK: - Modifier translation

    @Test func noModifiersReturnsNone() {
        let mods = alasGhosttyMods([])
        #expect(mods == GHOSTTY_MODS_NONE)
    }

    @Test func shiftModifierReturnsShift() {
        let mods = alasGhosttyMods(.shift)
        #expect(mods == GHOSTTY_MODS_SHIFT)
    }

    @Test func controlModifierReturnsCtrl() {
        let mods = alasGhosttyMods(.control)
        #expect(mods == GHOSTTY_MODS_CTRL)
    }

    @Test func optionModifierReturnsAlt() {
        let mods = alasGhosttyMods(.option)
        #expect(mods == GHOSTTY_MODS_ALT)
    }

    @Test func commandModifierReturnsSuper() {
        let mods = alasGhosttyMods(.command)
        #expect(mods == GHOSTTY_MODS_SUPER)
    }

    @Test func capsLockModifierReturnsCaps() {
        let mods = alasGhosttyMods(.capsLock)
        #expect(mods == GHOSTTY_MODS_CAPS)
    }

    @Test func combinedModifiersReturnCombinedBits() {
        let mods = alasGhosttyMods([.shift, .control, .option])
        let expected = GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_ALT.rawValue
        #expect(mods.rawValue == expected)
    }

    // MARK: - Key event builder (consumed_mods from translation flags)

    @Test func keyEventUsesPhysicalModsAndTranslationConsumedMods() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.shift, .control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        let keyEv = event.alasGhosttyKeyEvent(
            GHOSTTY_ACTION_PRESS,
            translationFlags: .shift
        )

        #expect(keyEv.action == GHOSTTY_ACTION_PRESS)
        #expect(keyEv.mods == alasGhosttyMods([.shift, .control]))
        #expect(keyEv.consumed_mods == alasGhosttyMods(.shift))
    }

    @Test func keyEventWithNoTranslationFlagsUsesPhysicalFlagsMinusCtrlCmd() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.shift, .control, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        let keyEv = event.alasGhosttyKeyEvent(GHOSTTY_ACTION_PRESS)

        #expect(keyEv.consumed_mods == alasGhosttyMods(.shift))
    }

    // MARK: - Character extraction

    @Test func plainCharacterReturnsCharacters() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        #expect(event.alasGhosttyCharacters == "a")
    }

    @Test func puaFunctionKeyReturnsNil() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{F700}", // NSUpArrowFunctionKey
                charactersIgnoringModifiers: "\u{F700}",
                isARepeat: false,
                keyCode: 126
            )
        )

        #expect(event.alasGhosttyCharacters == nil)
    }

    @Test func ctrlPlusLetterReturnsLayoutCharacter() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .control,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{01}",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        #expect(event.alasGhosttyCharacters == "a")
    }

    @Test func shiftEnterReturnsNilForText() throws {
        // Enter keycode 0x24 with shift held produces \r (U+000D < 0x20).
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 0x24
            )
        )

        #expect(event.alasGhosttyCharacters == nil)
    }

    @Test func shiftEnterWithNoTextStillHasShiftInConsumedMods() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 0x24
            )
        )

        let keyEv = event.alasGhosttyKeyEvent(
            GHOSTTY_ACTION_PRESS,
            translationFlags: .shift
        )

        #expect(keyEv.mods == GHOSTTY_MODS_SHIFT)
        #expect(keyEv.consumed_mods == GHOSTTY_MODS_SHIFT)
    }

    @Test func shiftedPrintableCharacterIsForwardedAsGhosttyText() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\"",
                charactersIgnoringModifiers: "'",
                isARepeat: false,
                keyCode: 39
            )
        )

        #expect(event.alasGhosttyForwardedText == "\"")
    }

    @Test func shiftedControlCharacterIsNotForwardedAsGhosttyText() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 0x24
            )
        )

        #expect(event.alasGhosttyForwardedText == nil)
    }

    @Test @MainActor func fakeIOConformsToProtocol() {
        let io = FakeGhosttySurfaceIO()
        io.sendText("hi")
        io.setPreedit("か")
        io.setPreedit(nil)
        #expect(io.calls == [
            .text("hi"),
            .preedit("か"),
            .preedit(nil),
        ])
    }

    @Test @MainActor func textInputClient_defaultsAreEmpty() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        #expect(view.hasMarkedText() == false)
        #expect(view.selectedRange().location == NSNotFound)
        #expect(view.selectedRange().length == 0)
        #expect(view.markedRange().location == NSNotFound)
        #expect(view.markedRange().length == 0)
        #expect(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 0), actualRange: nil) == nil)
        #expect(view.validAttributesForMarkedText().isEmpty)
        #expect(view.characterIndex(for: .zero) == NSNotFound)
    }

    @Test @MainActor func insertText_sendsTextAndClearsPreedit() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        view.insertText("é" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(io.calls == [.text("é"), .preedit(nil)])
        #expect(view.hasMarkedText() == false)
    }

    @Test @MainActor func insertText_acceptsAttributedString() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        let attr = NSAttributedString(string: "ñ")
        view.insertText(attr, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(io.calls == [.text("ñ"), .preedit(nil)])
    }

    @Test @MainActor func insertText_emptyStringIsNoop() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        view.insertText("" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(io.calls.isEmpty)
    }

    @Test @MainActor func setMarkedText_sendsPreeditAndTracksState() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        view.setMarkedText(
            "か" as NSString,
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(io.calls == [.preedit("か")])
        #expect(view.hasMarkedText() == true)
        #expect(view.markedRange() == NSRange(location: 0, length: 1))
    }

    @Test @MainActor func setMarkedText_emptyClearsState() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        view.setMarkedText("か" as NSString, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("" as NSString, selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(io.calls == [.preedit("か"), .preedit(nil)])
        #expect(view.hasMarkedText() == false)
    }

    @Test @MainActor func setMarkedText_acceptsAttributedString() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        let attr = NSAttributedString(string: "한")
        view.setMarkedText(attr, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(io.calls == [.preedit("한")])
        #expect(view.hasMarkedText() == true)
    }

    @Test @MainActor func unmarkText_commitsMarkedTextAndClearsPreedit() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        view.setMarkedText("か" as NSString, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        // Per Apple's contract: marked text is accepted (sent as text) and
        // then preedit is cleared.
        #expect(io.calls == [.preedit("か"), .text("か"), .preedit(nil)])
        #expect(view.hasMarkedText() == false)
    }

    @Test @MainActor func unmarkText_withoutMarkedTextOnlyClearsPreedit() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        view.unmarkText()
        #expect(io.calls == [.preedit(nil)])
        #expect(view.hasMarkedText() == false)
    }

    @Test @MainActor func firstRect_noWindowReturnsZero() {
        let io = FakeGhosttySurfaceIO()
        io.imePointRect = CGRect(x: 10, y: 20, width: 8, height: 16)
        let view = AlasGhostty.SurfaceView(testIO: io)
        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        #expect(rect == .zero)
    }

    @Test @MainActor func firstRect_withWindowConvertsToScreen() {
        let io = FakeGhosttySurfaceIO()
        io.imePointRect = CGRect(x: 10, y: 20, width: 8, height: 16)
        let view = AlasGhostty.SurfaceView(testIO: io)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        #expect(rect.size == CGSize(width: 8, height: 16))
        #expect(rect.origin != .zero)
    }

    @Test @MainActor func doCommand_doesNotForwardToIO() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        view.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(io.calls.isEmpty)
    }

    @Test @MainActor func testInitializerWiresFakeIO() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        var keyEv = ghostty_input_key_s()
        keyEv.action = GHOSTTY_ACTION_PRESS
        keyEv.keycode = 42
        _ = view.surfaceIOForTesting.sendKey(keyEv)
        #expect(io.calls == [.key(
            action: GHOSTTY_ACTION_PRESS.rawValue,
            keycode: 42,
            mods: 0,
            text: nil,
            composing: false
        )])
    }

    @Test @MainActor func alasPathDropTargetsOnlyTheReceivingPaneAndFocusesIt() throws {
        let firstIO = FakeGhosttySurfaceIO()
        let secondIO = FakeGhosttySurfaceIO()
        let first = AlasGhostty.SurfaceView(testIO: firstIO)
        let second = AlasGhostty.SurfaceView(testIO: secondIO)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        container.addSubview(first)
        container.addSubview(second)
        #expect(window.makeFirstResponder(first))
        let pasteboard = NSPasteboard(name: .init("alas-terminal-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let payload = AlasDropPayload.file(
            relativePath: "Sources/App State.swift",
            absolutePath: "/tmp/work tree/Sources/App State.swift"
        )
        pasteboard.setData(try #require(payload.encoded()), forType: .alasDropPayload)

        #expect(second.handleAlasDrop(from: pasteboard))
        #expect(firstIO.calls.isEmpty)
        #expect(secondIO.calls == [.text("'/tmp/work tree/Sources/App State.swift'")])
        #expect(window.firstResponder === second)
    }

    @Test @MainActor func alasSHADropSendsFullSHAWithoutANewline() throws {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        let pasteboard = NSPasteboard(name: .init("alas-terminal-sha-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let sha = "0123456789abcdef0123456789abcdef01234567"
        pasteboard.setData(
            try #require(AlasDropPayload.commitSHA(sha).encoded()),
            forType: .alasDropPayload
        )

        #expect(view.handleAlasDrop(from: pasteboard))
        #expect(io.calls == [.text(sha)])
    }

    @Test @MainActor func malformedOrUnrelatedTerminalDropsAreIgnored() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        let malformed = NSPasteboard(name: .init("alas-terminal-malformed-\(UUID().uuidString)"))
        malformed.clearContents()
        malformed.setData(Data("not-json".utf8), forType: .alasDropPayload)
        let unrelated = NSPasteboard(name: .init("alas-terminal-unrelated-\(UUID().uuidString)"))
        unrelated.clearContents()
        unrelated.setString("do not inject", forType: .string)

        #expect(!view.handleAlasDrop(from: malformed))
        #expect(!view.handleAlasDrop(from: unrelated))
        #expect(io.calls.isEmpty)
    }

    // MARK: - Dead-key pipeline tests

    @Test @MainActor func keyDown_aggregatesInsertTextIntoAccumulator() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)

        // Simulate interpretKeyEvents calling insertText twice inside keyDown.
        // In reality this happens via AppKit, but we drive the callback directly.
        view.keyTextAccumulator = [] // simulate accumulator start (normally set by keyDown)
        view.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyTextAccumulator = nil

        // Because insertText returns early when accumulator is active, no direct
        // io.sendText calls should have occurred yet.
        #expect(io.calls.isEmpty)
    }

    @Test @MainActor func markTextAndUnmarkText_updatesCompositionState() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)

        view.setMarkedText("か" as NSString, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == true)

        view.unmarkText()
        #expect(view.hasMarkedText() == false)
    }

    @Test @MainActor func flagsChanged_doesNothingWhileCompositionActive() {
        let io = FakeGhosttySurfaceIO()
        let view = AlasGhostty.SurfaceView(testIO: io)
        view.setMarkedText("か" as NSString, selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        io.clearCalls() // isolate flagsChanged behavior from setMarkedText side effects

        // Simulate a shift-key flagsChanged event.
        let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x38
        )!
        view.flagsChanged(with: event)

        // No key events should have been sent.
        #expect(io.calls.isEmpty)
    }
}
