import AlasCore
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Synthesized input posted straight to an app's pid, so the system cursor and
/// the frontmost app are untouched. Every sequence that presses something
/// releases it before returning or checking for cancellation.
enum ComputerUseInputPoster {
    /// Unicode text per keyboard event; larger strings are dropped by some apps.
    static let textChunkUnits = 20
    static let dragSteps = 10
    private static let stepDelay: Duration = .milliseconds(8)

    struct Target {
        var pid: Int32
        var windowID: UInt32
    }

    static func click(
        at point: CGPoint, button: ComputerUseCommand.Button, count: Int, target: Target
    ) async throws {
        let (down, up, mouseButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        }
        // A double click is two pairs, the second carrying click state 2.
        for clickState in 1 ... max(1, count) {
            let pair = try [down, up].map {
                try mouseEvent($0, at: point, button: mouseButton, clickState: clickState, target: target)
            }
            for event in pair {
                event.postToPid(target.pid)
            }
            if clickState < count { await pause() }
        }
    }

    static func drag(from start: CGPoint, to end: CGPoint, target: Target) async throws {
        let points = ComputerUseInputGeometry.interpolate(from: start, to: end, steps: dragSteps)
        // Build everything first so a failure can't leave the button down.
        let down = try mouseEvent(.leftMouseDown, at: start, button: .left, clickState: 1, target: target)
        let moves = try points.map { try mouseEvent(.leftMouseDragged, at: $0, button: .left, clickState: 1, target: target) }
        let up = try mouseEvent(.leftMouseUp, at: end, button: .left, clickState: 1, target: target)
        down.postToPid(target.pid)
        for move in moves {
            await pause()
            move.postToPid(target.pid)
        }
        await pause()
        up.postToPid(target.pid)
    }

    /// Positive `dy` scrolls down and positive `dx` right, like CSS. CG wheel
    /// deltas run the other way (positive wheel1 scrolls up, wheel2 left).
    static func scroll(at point: CGPoint, dx: Int, dy: Int, target: Target) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: try source(), units: .line, wheelCount: 2,
            wheel1: Int32(clamping: -dy), wheel2: Int32(clamping: -dx), wheel3: 0
        ) else { throw ComputerUseSystemError.actionFailed("Could not create a scroll event.") }
        event.location = point
        setWindow(event, target)
        event.postToPid(target.pid)
    }

    /// Modifiers ride on the flags; no separate modifier key events, so none can stay down.
    static func key(_ chord: ComputerUseKeyChord, pid: Int32) throws {
        guard let code = keyCode(for: chord.key) else {
            let name = switch chord.key {
            case .character(let character): String(character)
            case .named(let named): named.rawValue
            }
            throw ComputerUseSystemError.actionFailed("No key for \"\(name)\".")
        }
        try postKey(code, flags: flags(for: chord.modifiers), pid: pid)
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags, pid: Int32) throws {
        let source = try source()
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { throw ComputerUseSystemError.actionFailed("Could not create a key event.") }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    /// Posts `text` as unicode keyboard events in chunks of at most
    /// `textChunkUnits` UTF-16 units, never splitting a character. Throws
    /// `CancellationError` between chunks once `isCancelled` turns true.
    static func type(_ text: String, pid: Int32, isCancelled: @Sendable () -> Bool) async throws {
        let source = try source()
        for (index, chunk) in chunks(text).enumerated() {
            if index > 0 {
                if isCancelled() { throw CancellationError() }
                await pause()
            }
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw ComputerUseSystemError.actionFailed("Could not create a key event.") }
            for event in [down, up] {
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            down.postToPid(pid)
            up.postToPid(pid)
        }
    }

    static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let count = character.utf16.count
            if units + count > textChunkUnits, !current.isEmpty {
                result.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func flags(for modifiers: Set<ComputerUseKeyChord.Modifier>) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    static func keyCode(for key: ComputerUseKeyChord.Key) -> CGKeyCode? {
        switch key {
        case .character(let character):
            characterCodes[Character(character.lowercased())].map(CGKeyCode.init)
        case .named(let named):
            namedCodes[named].map(CGKeyCode.init)
        }
    }

    private static func source() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw ComputerUseSystemError.actionFailed("Could not create an event source.")
        }
        return source
    }

    private static func mouseEvent(
        _ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, target: Target
    ) throws -> CGEvent {
        guard let event = CGEvent(
            mouseEventSource: try source(), mouseType: type, mouseCursorPosition: point, mouseButton: button
        ) else { throw ComputerUseSystemError.actionFailed("Could not create a mouse event.") }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        setWindow(event, target)
        return event
    }

    private static func setWindow(_ event: CGEvent, _ target: Target) {
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
    }

    /// Lets the target's event queue keep up; never cancelled midway.
    private static func pause() async {
        try? await Task.sleep(for: stepDelay)
    }

    /// US ANSI layout.
    private static let characterCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
    ]

    private static let namedCodes: [ComputerUseKeyChord.NamedKey: Int] = [
        .return: kVK_Return, .tab: kVK_Tab, .space: kVK_Space, .delete: kVK_Delete,
        .forwardDelete: kVK_ForwardDelete, .escape: kVK_Escape,
        .up: kVK_UpArrow, .down: kVK_DownArrow, .left: kVK_LeftArrow, .right: kVK_RightArrow,
        .home: kVK_Home, .end: kVK_End, .pageUp: kVK_PageUp, .pageDown: kVK_PageDown,
        .f1: kVK_F1, .f2: kVK_F2, .f3: kVK_F3, .f4: kVK_F4, .f5: kVK_F5, .f6: kVK_F6,
        .f7: kVK_F7, .f8: kVK_F8, .f9: kVK_F9, .f10: kVK_F10, .f11: kVK_F11, .f12: kVK_F12,
    ]
}
