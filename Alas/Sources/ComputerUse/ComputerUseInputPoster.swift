import AlasCore
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Synthesized input posted straight to an app's pid, so the system cursor and
/// the frontmost app are untouched. Mouse events carry their window and the point inside it,
/// so they reach a window that isn't frontmost; see `ComputerUseSkyLight`. Drags are the exception:
/// they go system-wide with the app activated and put the cursor back after. Every sequence that
/// presses something releases it before returning or checking for cancellation.
enum ComputerUseInputPoster {
    /// Unicode text per keyboard event; larger strings are dropped by some apps.
    static let textChunkUnits = 20
    private static let stepDelay: Duration = .milliseconds(8)

    struct Target {
        var pid: Int32
        var windowID: UInt32
        /// The window's top-left corner, global points.
        var windowOrigin: CGPoint
    }

    static func click(
        at point: CGPoint, button: ComputerUseCommand.Button, count: Int, target: Target
    ) async throws {
        let (down, up, mouseButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        }
        // A window that never saw the pointer hit-tests against stale tracking state.
        ComputerUseSkyLight.post(try mouseEvent(.mouseMoved, at: point, button: .left, clickState: 0, target: target), pid: target.pid)
        // A double click is two pairs, the second carrying click state 2.
        for clickState in 1 ... max(1, count) {
            let pair = try [down, up].map {
                try mouseEvent($0, at: point, button: mouseButton, clickState: clickState, target: target)
            }
            for event in pair {
                ComputerUseSkyLight.post(event, pid: target.pid)
            }
            if clickState < count { await pause() }
        }
    }

    /// Steps and pauses for a system-wide drag: Finder's drag session trails the cursor, so it
    /// needs time over the drop target before the release.
    static let systemDragSteps = 20
    private static let systemDragStepDelay: Duration = .milliseconds(16)
    private static let systemDragDownHold: Duration = .milliseconds(100)
    private static let systemDragHover: Duration = .milliseconds(300)
    private static let cursorRestoreDelay: Duration = .milliseconds(100)

    /// A drag the system's drag and drop can follow: posted at the HID level, so the cursor moves
    /// with it. A file drag hands off to a drag session that tracks the cursor, not the events
    /// posted to a pid. Every event carries Alas's marker, so the input tap never takes it for the
    /// user's. Between steps, `userActive` true cancels it: dragged back to the start and released
    /// there, as for a covered drop (`dropIsVisible` false before the release), so nothing moves.
    /// The button is always released, and then the cursor goes back where it was.
    static func systemDrag(
        from start: CGPoint, to end: CGPoint, dropIsVisible: @Sendable () -> Bool, userActive: @Sendable () -> Bool
    ) async throws {
        // Build everything first so a failure can't leave the button down or the cursor moved.
        let cursor = CGEvent(source: nil)?.location ?? start
        let restore = try systemMouseEvent(.mouseMoved, at: cursor, clickState: 0)
        let primer = try systemMouseEvent(.mouseMoved, at: start, clickState: 0)
        let down = try systemMouseEvent(.leftMouseDown, at: start, clickState: 1)
        // Two short moves first cross the drag threshold while still over the item.
        let points = [CGPoint(x: start.x + 3, y: start.y + 3), CGPoint(x: start.x + 8, y: start.y + 8)]
            + ComputerUseInputGeometry.interpolate(from: start, to: end, steps: systemDragSteps)
        let moves = try points.map { try systemMouseEvent(.leftMouseDragged, at: $0, clickState: 1) }
        let back = try systemMouseEvent(.leftMouseDragged, at: start, clickState: 1)
        let upAtStart = try systemMouseEvent(.leftMouseUp, at: start, clickState: 1)
        let up = try systemMouseEvent(.leftMouseUp, at: end, clickState: 1)
        func cancel() {
            postSystemWide(back)
            postSystemWide(upAtStart)
        }
        do {
            postSystemWide(primer)
            await pause()
            postSystemWide(down)
            try? await Task.sleep(for: systemDragDownHold)
            for move in moves {
                try? await Task.sleep(for: systemDragStepDelay)
                if userActive() {
                    cancel()
                    throw ComputerUseSystemError.userActive
                }
                postSystemWide(move)
            }
            try? await Task.sleep(for: systemDragHover)
            if userActive() {
                cancel()
                throw ComputerUseSystemError.userActive
            }
            guard dropIsVisible() else {
                cancel()
                throw ComputerUseSystemError.actionFailed("The drop point is covered by another window.")
            }
            postSystemWide(up)
        } catch {
            try? await Task.sleep(for: cursorRestoreDelay)
            postSystemWide(restore)
            throw error
        }
        try? await Task.sleep(for: cursorRestoreDelay)
        postSystemWide(restore)
    }

    private static func systemMouseEvent(_ type: CGEventType, at point: CGPoint, clickState: Int) throws -> CGEvent {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: point,
            mouseButton: .left)
        else { throw ComputerUseSystemError.actionFailed("Could not create a mouse event.") }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        return event
    }

    /// Into the HID stream, where WindowServer routes it like the user's own input; marked as Alas's.
    private static func postSystemWide(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: ComputerUseUserInput.postedEventMarker)
        event.post(tap: .cghidEventTap)
    }

    /// Positive `dy` scrolls down and positive `dx` right, like CSS. CG wheel
    /// deltas run the other way (positive wheel1 scrolls up, wheel2 left).
    static func scroll(at point: CGPoint, dx: Int, dy: Int, target: Target) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: try source(), units: .line, wheelCount: 2,
            wheel1: Int32(clamping: -dy), wheel2: Int32(clamping: -dx), wheel3: 0
        ) else { throw ComputerUseSystemError.actionFailed("Could not create a scroll event.") }
        event.location = point
        setWindow(event, at: point, target)
        ComputerUseSkyLight.post(event, pid: target.pid)
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
        ComputerUseSkyLight.post(down, pid: pid)
        ComputerUseSkyLight.post(up, pid: pid)
    }

    /// Posts `text` as unicode keyboard events in chunks of at most
    /// `textChunkUnits` UTF-16 units, never splitting a character. Between
    /// chunks, throws `CancellationError` once `interrupt` reports `.cancelled`
    /// and `userTookOver` with the characters typed once it reports `.userActive`.
    static func type(_ text: String, pid: Int32, interrupt: @Sendable () -> ComputerUseInputInterrupt?) async throws {
        let source = try source()
        let total = text.count
        var typed = 0
        for (index, chunk) in chunks(text).enumerated() {
            if index > 0 {
                switch interrupt() {
                case .cancelled: throw CancellationError()
                case .userActive: throw ComputerUseSystemError.userTookOver(typed: typed, of: total)
                case nil: break
                }
                await pause()
            }
            typed += chunk.count
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw ComputerUseSystemError.actionFailed("Could not create a key event.") }
            for event in [down, up] {
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            ComputerUseSkyLight.post(down, pid: pid)
            ComputerUseSkyLight.post(up, pid: pid)
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
        setWindow(event, at: point, target)
        return event
    }

    /// The raw window-number field AppKit builds `NSEvent.windowNumber` from; no public name.
    private static let windowNumberField = CGEventField(rawValue: 51)!

    /// Routes the event to the target window at `point` (global) without a screen hit test.
    private static func setWindow(_ event: CGEvent, at point: CGPoint, _ target: Target) {
        let windowID = Int64(target.windowID)
        event.setIntegerValueField(windowNumberField, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.pid))
        ComputerUseSkyLight.setWindowLocation(
            event, CGPoint(x: point.x - target.windowOrigin.x, y: point.y - target.windowOrigin.y))
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
