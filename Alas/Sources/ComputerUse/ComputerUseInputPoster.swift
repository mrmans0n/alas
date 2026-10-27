import AlasCore
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Synthesized input posted straight to an app's pid, so the system cursor and
/// the frontmost app are untouched. Mouse events carry their window and the point inside it,
/// so they reach a window that isn't frontmost; see `ComputerUseSkyLight`. A background drag stays
/// on that path; a system drag goes system-wide with the app activated and puts the cursor back
/// after. Every sequence that presses something releases it before returning or checking for
/// cancellation.
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
    /// Lets table views and Chromium arm their drag tracking before the first drag event.
    private static let backgroundDragDownHold: Duration = .milliseconds(30)
    private static let systemDragHover: Duration = .milliseconds(300)
    private static let minimumDropHover: Duration = .milliseconds(100)
    /// The final approach to the drop: these last moves keep the standard pace under the debug
    /// step override, so the drag doesn't linger over what it passes on the way in.
    private static let systemDragFinalSteps = 3
    /// Back at the start before a cancelled drag's release, for the trailing drag session to follow.
    private static let systemDragCancelSettle: Duration = .milliseconds(100)
    private static let cursorRestoreDelay: Duration = .milliseconds(100)

    /// A drag the system's drag and drop can follow: posted at the HID level, so the cursor moves
    /// with it. A file drag hands off to a drag session that tracks the cursor, not the events
    /// posted to a pid. Every event carries Alas's marker, so the input tap never takes it for the
    /// user's. `interrupt`, checked before every step and the release, cancels it in place: dragged
    /// back to the start and released there, so nothing moves; so does a covered drop
    /// (`dropIsVisible` false before the release). The button is always released. The cursor then
    /// goes back where it was, except when the user took over, since their hand is on it.
    /// `modifiers` go down as key events right before the press and come up right after the
    /// button, on every path; every mouse event carries exactly them, so a key the user holds
    /// doesn't ride along. A cancel lets the keys go before the button and releases with no
    /// flags, so an Option drag stopped in place can't drop a copy at the start. A drag key the
    /// user already holds refuses the drag before anything moves.
    /// Pauses don't shorten under cancellation, so a Stop can't turn into an early drop.
    static func systemDrag(
        from start: CGPoint, to end: CGPoint, modifiers: Set<ComputerUseKeyChord.Modifier>,
        dropIsVisible: @Sendable () -> Bool,
        interrupt: @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        // Build everything first so a failure can't leave the button or a key down, or the cursor moved.
        let held = flags(for: modifiers)
        let cursor = CGEvent(source: nil)?.location ?? start
        let restore = try systemMouseEvent(.mouseMoved, at: cursor, clickState: 0, flags: [])
        let primer = try systemMouseEvent(.mouseMoved, at: start, clickState: 0, flags: [])
        let (keysDown, keysUp) = try systemModifierEvents(modifiers)
        let down = try systemMouseEvent(.leftMouseDown, at: start, clickState: 1, flags: held)
        // Two short moves first cross the drag threshold while still over the item.
        let points = [CGPoint(x: start.x + 3, y: start.y + 3), CGPoint(x: start.x + 8, y: start.y + 8)]
            + ComputerUseInputGeometry.interpolate(from: start, to: end, steps: systemDragSteps)
        let moves = try points.map { try systemMouseEvent(.leftMouseDragged, at: $0, clickState: 1, flags: held) }
        let back = try systemMouseEvent(.leftMouseDragged, at: start, clickState: 1, flags: held)
        // A cancel's release: the keys are already up, so it carries none.
        let upAtStart = try systemMouseEvent(.leftMouseUp, at: start, clickState: 1, flags: [])
        let up = try systemMouseEvent(.leftMouseUp, at: end, clickState: 1, flags: held)
        var pressed = false
        var keysAreDown = false
        /// After the button: the keys come up in reverse order. Once only.
        func releaseKeys() {
            guard keysAreDown else { return }
            keysAreDown = false
            keysUp.forEach(postSystemWide)
        }
        // Whatever ends the drag, no key of Alas's stays down.
        defer { releaseKeys() }
        /// Cancels in place on a stop or the user's input, before the next event goes out.
        func checkInterrupt() async throws {
            switch interrupt() {
            case .cancelled:
                if pressed { await cancelInPlace() } else { releaseKeys() }
                throw CancellationError()
            case .userActive:
                // Stopping takes the user's input too (a click on the badge, the Stop shortcut),
                // which the tap sees before the Stop lands: released first, a Stop that follows
                // within `stopGrace` is a Stop, and the cursor goes back.
                if pressed { await cancelInPlace() } else { releaseKeys() }
                if await stopFollows(interrupt) { throw CancellationError() }
                throw pressed ? ComputerUseSystemError.userTookOverDrag : ComputerUseSystemError.userActive
            case nil:
                break
            }
        }
        /// Settles back at the start before the release, so the button comes up where the drag
        /// began. The keys come up first: a release with Option still down drops a copy.
        func cancelInPlace() async {
            postSystemWide(back)
            await steadyPause(systemDragCancelSettle)
            releaseKeys()
            postSystemWide(upAtStart)
        }
        // Nothing has moved yet: an active user keeps their cursor where it is.
        try await checkInterrupt()
        if userHoldsDragKey() { throw ComputerUseSystemError.userActive }
        do {
            postSystemWide(primer)
            await steadyPause(stepDelay)
            try await checkInterrupt()
            if !keysDown.isEmpty {
                keysAreDown = true
                keysDown.forEach(postSystemWide)
                await steadyPause(stepDelay)
                try await checkInterrupt()
            }
            postSystemWide(down)
            pressed = true
            await steadyPause(systemDragDownHold)
            for (index, move) in moves.enumerated() {
                try await checkInterrupt()
                postSystemWide(move)
                let approaching = index >= moves.count - systemDragFinalSteps
                await steadyPause(approaching ? systemDragStepDelay : dragStepDelay(systemDragStepDelay))
            }
            await steadyPause(dropHover())
            try await checkInterrupt()
            guard dropIsVisible() else {
                await cancelInPlace()
                throw ComputerUseSystemError.actionFailed("The drop point is covered by another window.")
            }
            postSystemWide(up)
            releaseKeys()
        } catch let error as ComputerUseSystemError where error.isUserTakeover {
            // The user's hand is on the cursor: it stays where they put it.
            throw error
        } catch {
            await steadyPause(cursorRestoreDelay)
            postSystemWide(restore)
            throw error
        }
        await steadyPause(cursorRestoreDelay)
        postSystemWide(restore)
    }

    enum BackgroundDragOutcome: Equatable {
        case done
        /// A native drag-and-drop session started; it follows the hardware cursor, so the drag
        /// was released at its start and has to go through the foreground.
        case dragSession
    }

    /// A drag inside one window of `pid` that leaves the cursor and the frontmost app alone: the
    /// background click's per-pid route stretched over a gesture. Every event carries the window,
    /// the point inside it and one gesture id; nothing is posted system-wide. One stamped move
    /// primes the window's tracking state, then down, `ComputerUseBackgroundDrag.steps` drags and
    /// the release. Once the app shows a new drag-layer window (a drag-and-drop session), the
    /// button comes up at the start and the outcome is `.dragSession`. `interrupt`, checked before
    /// every event, releases at the start and throws what `systemDrag` throws. The button is
    /// always released. `modifiers` ride on every event's flags, as a chord's do: no key events,
    /// so none can stay down, and none of the user's keys show in them. The release at the start
    /// (a cancel, a takeover, a drag session) carries no flags, so it can't drop a copy there.
    static func backgroundDrag(
        from start: CGPoint, to end: CGPoint, modifiers: Set<ComputerUseKeyChord.Modifier>,
        pid: Int32, windowID: UInt32, windowFrame: CGRect,
        screenWindows: @Sendable () -> [ComputerUseInputGeometry.ScreenWindow],
        interrupt: @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> BackgroundDragOutcome {
        // Every event is addressed to the one window: a drop into another window goes to the front
        // before any event (`ComputerUseBackgroundDrag.route`).
        let target = Target(pid: pid, windowID: windowID, windowOrigin: windowFrame.origin)
        let gesture = Int64.random(in: 1 ... Int64(Int32.max))
        let held = flags(for: modifiers)
        func event(
            _ type: CGEventType, at point: CGPoint, clickState: Int, flags: CGEventFlags? = nil
        ) throws -> CGEvent {
            let event = try mouseEvent(type, at: point, button: .left, clickState: clickState, target: target)
            event.setIntegerValueField(gestureField, value: gesture)
            event.flags = flags ?? held
            return event
        }
        // Build everything first so a failure can't leave the button down.
        let primer = try event(.mouseMoved, at: start, clickState: 0)
        let down = try event(.leftMouseDown, at: start, clickState: 1)
        let drags = try ComputerUseInputGeometry.interpolate(from: start, to: end, steps: ComputerUseBackgroundDrag.steps)
            .map { try event(.leftMouseDragged, at: $0, clickState: 1) }
        let upAtStart = try event(.leftMouseUp, at: start, clickState: 1, flags: [])
        let up = try event(.leftMouseUp, at: end, clickState: 1)
        let post = { (event: CGEvent) in ComputerUseSkyLight.post(event, pid: pid) }

        var pressed = false
        // Whatever ends the drag early, the button comes up where it went down.
        defer { if pressed { post(upAtStart) } }
        func checkInterrupt() throws {
            switch interrupt() {
            case .cancelled:
                throw CancellationError()
            case .userActive:
                throw pressed ? ComputerUseSystemError.userTookOverDrag : ComputerUseSystemError.userActive
            case nil:
                break
            }
        }

        try checkInterrupt()
        post(primer)
        await steadyPause(ComputerUseBackgroundDrag.stepDelay)
        try checkInterrupt()
        let before = Set(screenWindows().map(\.id))
        post(down)
        pressed = true
        await steadyPause(backgroundDragDownHold)
        for drag in drags {
            try checkInterrupt()
            if ComputerUseBackgroundDrag.startedSession(before: before, now: screenWindows(), sourcePID: pid) {
                return .dragSession
            }
            post(drag)
            await steadyPause(dragStepDelay(ComputerUseBackgroundDrag.stepDelay))
        }
        try checkInterrupt()
        // One last look: a drag image can come up a moment after the last move.
        await steadyPause(ComputerUseBackgroundDrag.sessionPoll)
        if ComputerUseBackgroundDrag.startedSession(before: before, now: screenWindows(), sourcePID: pid) {
            return .dragSession
        }
        post(up)
        pressed = false
        return .done
    }

    /// How long a drag's takeover waits for the Stop that the user's input may have been.
    private static let stopGrace: Duration = .milliseconds(500)
    private static let stopGracePoll: Duration = .milliseconds(50)

    /// Whether `interrupt` turns into a Stop within `stopGrace`, polled every `stopGracePoll`:
    /// a takeover seen just before a Stop may have been the Stop's own click or shortcut.
    static func stopFollows(_ interrupt: () -> ComputerUseInputInterrupt?) async -> Bool {
        let deadline = ContinuousClock.now + stopGrace
        while true {
            if interrupt() == .cancelled { return true }
            guard ContinuousClock.now < deadline else { return false }
            await steadyPause(stopGracePoll)
        }
    }

    /// A pause that a cancelled task still waits out in full.
    static func steadyPause(_ duration: Duration) async {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    /// `flags` replace the keyboard state the HID source would stamp on the event.
    private static func systemMouseEvent(
        _ type: CGEventType, at point: CGPoint, clickState: Int, flags: CGEventFlags
    ) throws -> CGEvent {
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: point,
            mouseButton: .left)
        else { throw ComputerUseSystemError.actionFailed("Could not create a mouse event.") }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.flags = flags
        return event
    }

    /// The modifier keys going down one by one, as a keyboard sends them (flags changed, each
    /// carrying the keys down so far), and coming up in reverse order.
    private static func systemModifierEvents(
        _ modifiers: Set<ComputerUseKeyChord.Modifier>
    ) throws -> (down: [CGEvent], up: [CGEvent]) {
        let ordered = modifierOrder.filter { modifiers.contains($0.modifier) }
        func event(_ code: Int, down: Bool, flags: CGEventFlags) throws -> CGEvent {
            guard let event = CGEvent(
                keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(code), keyDown: down)
            else { throw ComputerUseSystemError.actionFailed("Could not create a key event.") }
            event.type = .flagsChanged
            event.flags = flags
            return event
        }
        var downs: [CGEvent] = []
        var flags: CGEventFlags = []
        for (modifier, code) in ordered {
            flags.formUnion(self.flags(for: [modifier]))
            downs.append(try event(code, down: true, flags: flags))
        }
        var ups: [CGEvent] = []
        for (modifier, code) in ordered.reversed() {
            flags.subtract(self.flags(for: [modifier]))
            ups.append(try event(code, down: false, flags: flags))
        }
        return (downs, ups)
    }

    private static let modifierOrder: [(modifier: ComputerUseKeyChord.Modifier, code: Int)] = [
        (.command, kVK_Command), (.option, kVK_Option), (.control, kVK_Control), (.shift, kVK_Shift),
    ]

    /// Whether the user holds ⌘, ⌥, ⌃ or ⇧ on the keyboard now. The input tap only sees a key
    /// change, so a key held since before the idle wait goes unseen, and an app that reads the
    /// keyboard state during a system-wide drag (a Finder copy) would take it as the drag's.
    /// Only meaningful while Alas holds no key itself.
    static func userHoldsDragKey() -> Bool {
        !CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    /// The pause over the drop before the release, at most `systemDragHover`. While spring-loaded
    /// folders are on it is half their delay, so a folder under the drop point doesn't open, but at
    /// least `minimumDropHover`, so the drag session catches up over the drop. Read on every drag,
    /// since the user can change it any time; missing keys are macOS's defaults, on with 0.5 s.
    private static func dropHover() -> Duration {
        func value(_ key: String) -> NSNumber? {
            CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? NSNumber
        }
        guard value("com.apple.springing.enabled")?.boolValue ?? true else { return systemDragHover }
        let delay = value("com.apple.springing.delay")?.doubleValue ?? 0.5
        // A floor, so Finder's drag session still catches up over the drop with a short delay.
        return max(minimumDropHover, min(systemDragHover, .milliseconds(Int(min(max(0, delay), 1) * 500))))
    }

    /// A drag's pause between moves. Debug builds take `ALAS_COMPUTER_DRAG_STEP_MS` (1...1000)
    /// instead, so a drag lasts long enough to press Stop in the middle.
    private static func dragStepDelay(_ standard: Duration) -> Duration {
        #if DEBUG
        debugDragStepDelay ?? standard
        #else
        standard
        #endif
    }

    #if DEBUG
    private static let debugDragStepDelay: Duration? = {
        guard let text = ProcessInfo.processInfo.environment["ALAS_COMPUTER_DRAG_STEP_MS"],
              let milliseconds = Int(text.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return .milliseconds(min(max(milliseconds, 1), 1000))
    }()
    #endif

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
    /// The raw field that groups events into one gesture; no public name.
    private static let gestureField = CGEventField(rawValue: 58)!

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
