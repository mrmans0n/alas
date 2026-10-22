import AlasCore
import ApplicationServices
import CoreGraphics
import Foundation

/// AX actions on elements retained by a read. They run on the reader's serial
/// queue, so they never overlap a walk, with the same per-message timeout.
/// `isCancelled` is checked on the queue right before the AX call, so a Stop
/// that lands while the call waits behind a walk performs nothing.
enum ComputerUseAXActions {
    typealias IsCancelled = @Sendable () -> Bool

    /// An AX call failed in a way an event at the element might still get past.
    struct Unsupported: Error {
        var error: AXError
    }

    static func press(
        _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity, isCancelled: @escaping IsCancelled
    ) async throws {
        try await perform(kAXPressAction, handles, handle, app: app, isCancelled: isCancelled)
    }

    static func showMenu(
        _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity, isCancelled: @escaping IsCancelled
    ) async throws {
        try await perform(kAXShowMenuAction, handles, handle, app: app, isCancelled: isCancelled)
    }

    /// Replaces the element's value. Refuses secure text fields. Throws
    /// `Unsupported` when the element doesn't take a value this way, so typing
    /// can be tried instead.
    static func setValue(
        _ text: String, _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity,
        isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            try refuseSecure(element, app: app)
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            guard result == .success else { throw failure(result, app: app) }
        }
    }

    /// Refuses typing when the app's focused element is a secure text field.
    /// Proceeds when the focused element can't be read.
    static func refuseSecureFocus(app: ComputerUseAppIdentity, isCancelled: @escaping IsCancelled) async throws {
        try await onQueue(isCancelled) {
            let application = ComputerUseAXReader.application(app.pid)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
                == .success,
                let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
            else { return }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, ComputerUseAXReader.messagingTimeout)
            if isSecure(element) { throw secureRefusal }
        }
    }

    /// Focuses the element before typing into it. Refuses secure text fields.
    static func focus(
        _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity, isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            try refuseSecure(element, app: app)
            let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard result == .success else {
                throw mapped(result, app: app)
                    ?? ComputerUseSystemError.actionFailed("\(app.name) did not focus the element (AXError \(result.rawValue)).")
            }
        }
    }

    /// Whether the element still reads with `role` and `title`; false when it is gone or unreadable.
    static func elementMatches(_ handles: ComputerUseAXHandles, _ handle: Int, role: String, title: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            ComputerUseAXReader.queue.async {
                guard let element = handles.element(handle) else { return continuation.resume(returning: false) }
                AXUIElementSetMessagingTimeout(element, ComputerUseAXReader.messagingTimeout)
                var roleValue: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
                // Gone, or the app isn't answering: either way the ref can't be trusted.
                guard result != .invalidUIElement, result != .cannotComplete else {
                    return continuation.resume(returning: false)
                }
                let liveRole = string(of: element, kAXRoleAttribute) ?? "AXUnknown"
                continuation.resume(returning: liveRole == role && string(of: element, kAXTitleAttribute) == title)
            }
        }
    }

    /// A string attribute, nil when unreadable or empty, the way the reader reports it.
    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        let string = value as! String
        return string.isEmpty ? nil : string
    }

    /// The element's centre from its current position and size, global points.
    /// Throws `outOfBounds` when the centre is outside `window` (the window's current frame).
    static func center(
        _ handles: ComputerUseAXHandles, _ handle: Int, within window: CGRect, app: ComputerUseAppIdentity,
        isCancelled: @escaping IsCancelled
    ) async throws -> CGPoint {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(try value(element, kAXPositionAttribute, app: app), .cgPoint, &position),
                  AXValueGetValue(try value(element, kAXSizeAttribute, app: app), .cgSize, &size)
            else { throw noFrame }
            let center = ComputerUseInputGeometry.center(of: CGRect(origin: position, size: size))
            guard window.contains(center) else { throw ComputerUseSystemError.outOfBounds }
            return center
        }
    }

    /// Keys and typed text go to the app's key window: makes `window` that window, raising it
    /// if needed, or refuses with `notActiveWindow`. Events posted to the pid can't pick a window
    /// themselves. With `raise` false it only checks, for a window already made key another way.
    static func makeActiveWindow(
        _ window: ComputerUseWindow, raise: Bool = true, isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            let app = window.app
            let application = ComputerUseAXReader.application(app.pid)
            let notActive = ComputerUseSystemError.notActiveWindow(
                "Window \(window.windowID) isn't \(app.name)'s active window. Click in it first or pass delivery: \"direct\".")
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete || result == .apiDisabled, let error = mapped(result, app: app) { throw error }
            guard result == .success, let axWindows = windowsRef as? [AXUIElement],
                  let target = ComputerUseAXReader.matchingWindow(
                      axWindows, for: window, frame: frame(of:), title: { string(of: $0, kAXTitleAttribute) })
            else { throw notActive }
            if isFocusedWindow(target, of: application) { return }
            guard raise else { throw notActive }
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            guard isFocusedWindow(target, of: application) else { throw notActive }
        }
    }

    /// Whether `window` is its app's key window: the app reports itself frontmost, which follows
    /// AppKit's activation state rather than the user's front app, and `window` as its focused
    /// window. The focused window alone proves nothing: an inactive app reports its main window
    /// there while it has no key window. Also returns the focused window's id, nil when unknown.
    static func keyWindowState(
        _ window: ComputerUseWindow, isCancelled: @escaping IsCancelled
    ) async throws -> (isKey: Bool, focusedWindowID: UInt32?) {
        try await onQueue(isCancelled) {
            let app = window.app
            let application = ComputerUseAXReader.application(app.pid)
            let focused = elementAttribute(application, kAXFocusedWindowAttribute)
            let focusedID = focused.flatMap(ComputerUseSkyLight.windowID(of:))
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete || result == .apiDisabled, let error = mapped(result, app: app) { throw error }
            guard bool(of: application, kAXFrontmostAttribute) == true, let focused,
                  let axWindows = windowsRef as? [AXUIElement],
                  let target = ComputerUseAXReader.matchingWindow(
                      axWindows, for: window, frame: frame(of:), title: { string(of: $0, kAXTitleAttribute) })
            else { return (false, focusedID) }
            return (CFEqual(focused, target), focusedID)
        }
    }

    private static func isFocusedWindow(_ window: AXUIElement, of application: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(focused, window)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Throws `Unsupported` when the element doesn't support the action, so an
    /// event at its centre can be tried instead.
    private static func perform(
        _ action: String, _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity,
        isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            let result = AXUIElementPerformAction(element, action as CFString)
            guard result == .success else {
                // The app timed out answering, which says nothing about whether the press happened.
                if result == .cannotComplete {
                    throw ComputerUseSystemError.actionFailed(
                        "\(app.name) didn't confirm the action; it may have happened. Call computer_inspect before retrying.")
                }
                throw failure(result, app: app)
            }
        }
    }

    /// Errors that mean "not this way": an event may still get the input through.
    private static let fallbackErrors: Set<AXError> = [.actionUnsupported, .attributeUnsupported, .noValue, .illegalArgument]

    /// A failed AX action: `Unsupported` for the errors an event may get past, a tool error otherwise.
    private static func failure(_ result: AXError, app: ComputerUseAppIdentity) -> any Error {
        if let error = mapped(result, app: app) { return error }
        if fallbackErrors.contains(result) { return Unsupported(error: result) }
        return ComputerUseSystemError.actionFailed("\(app.name) refused the action (AXError \(result.rawValue)).")
    }

    /// Runs `body` on the reader's queue. A call cancelled or stopped while
    /// queued makes no AX request.
    private static func onQueue<T: Sendable>(
        _ isCancelled: @escaping IsCancelled, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let cancel = ComputerUseAXReader.CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ComputerUseAXReader.queue.async {
                    if cancel.isSet || isCancelled() {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Result { try body() })
                }
            }
        } onCancel: {
            cancel.set()
        }
    }

    private static func resolve(_ handles: ComputerUseAXHandles, _ handle: Int) throws -> AXUIElement {
        guard let element = handles.element(handle) else { throw ComputerUseSystemError.staleElement }
        AXUIElementSetMessagingTimeout(element, ComputerUseAXReader.messagingTimeout)
        return element
    }

    private static let secureRefusal = ComputerUseSystemError.actionFailed("Secure text fields can't be typed into.")

    /// Read live rather than trusting the cached node: the element may have changed.
    private static func refuseSecure(_ element: AXUIElement, app: ComputerUseAppIdentity) throws {
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if let error = mapped(result, app: app) { throw error }
            if result == .success, let string = value as? String, string == kAXSecureTextFieldSubrole {
                throw secureRefusal
            }
        }
    }

    /// Some apps expose a password field as the role rather than the subrole.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        [kAXRoleAttribute, kAXSubroleAttribute].contains { attribute in
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
                && (value as? String) == kAXSecureTextFieldSubrole
        }
    }

    private static let noFrame = ComputerUseSystemError.actionFailed("The element has no position on screen.")

    private static func value(_ element: AXUIElement, _ attribute: String, app: ComputerUseAppIdentity) throws -> AXValue {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        if let error = mapped(result, app: app) { throw error }
        guard result == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { throw noFrame }
        return ref as! AXValue
    }

    /// The errors every AX action reports the same way; nil for the rest.
    private static func mapped(_ result: AXError, app: ComputerUseAppIdentity) -> ComputerUseSystemError? {
        switch result {
        case .invalidUIElement: .staleElement
        case .cannotComplete: .actionFailed("\(app.name) is not responding")
        case .apiDisabled: .actionFailed("Accessibility permission is not granted")
        default: nil
        }
    }
}

// MARK: - AX-first delivery

/// Background apps ignore many posted events (chords, typed text before focus lands,
/// scroll wheels, clicks on static text), so these reach the same result through AX.
/// Each throws `Unsupported` when the element offers no AX way, so events can be tried.
extension ComputerUseAXActions {
    /// Menu levels walked for a shortcut: a top-level menu is level 1 (Format > Font > Bold is 2).
    static let menuMaxDepth = 6
    static let menuMaxItems = 2000
    /// Ancestors searched for the scroll area around an element.
    static let scrollAncestorLevels = 8
    static let maxScrollSteps = 100
    /// Scroll bar value moved per line when the bar takes no increment action.
    static let scrollValuePerLine = 0.05
    /// Characters set per AX insert, so a stop or takeover can land between them.
    static let insertChunkCharacters = 200

    /// Presses the enabled menu item whose shortcut is `chord` and returns its path in the app's
    /// menu titles ("Format > Font > Bold"); nil when no enabled menu item has it.
    /// Skips the Apple menu: its shortcuts (log out, force quit) belong to the system.
    /// Refuses while a secure text field has focus, since a menu item can paste into it.
    static func pressMenuShortcut(
        _ chord: ComputerUseKeyChord, app: ComputerUseAppIdentity,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> String? {
        guard ComputerUseMenuShortcut.applies(to: chord) else { return nil }
        let chordVirtualKey = ComputerUseInputPoster.keyCode(for: chord.key).map(Int.init)
        return try await onQueue({ interrupt() == .cancelled }) {
            func matches(_ item: AXUIElement) -> Bool {
                // The shortcut key first: most items have none, which settles them in one read.
                let cmdChar = string(of: item, kAXMenuItemCmdCharAttribute)
                var virtualKey: Int?
                switch chord.key {
                case .character: if cmdChar == nil { return false }
                case .named: virtualKey = number(of: item, kAXMenuItemCmdVirtualKeyAttribute)
                }
                // AppKit validates items against the key window: an inactive app's items read as disabled,
                // and pressing one does nothing.
                return ComputerUseMenuShortcut.matches(
                    chord, cmdChar: cmdChar, virtualKey: virtualKey,
                    mask: number(of: item, kAXMenuItemCmdModifiersAttribute), chordVirtualKey: chordVirtualKey)
                    && bool(of: item, kAXEnabledAttribute) == true
            }
            let application = ComputerUseAXReader.application(app.pid)
            guard let menuBar = elementAttribute(application, kAXMenuBarAttribute) else { return nil }
            let deadline = ContinuousClock.now + ComputerUseAXReader.deadline
            var items = 0
            func title(_ element: AXUIElement) -> String { string(of: element, kAXTitleAttribute) ?? "?" }
            func find(in menu: AXUIElement, level: Int, path: [String]) -> (AXUIElement, [String])? {
                for item in children(of: menu) {
                    guard items < menuMaxItems, ContinuousClock.now < deadline, interrupt() != .cancelled else { return nil }
                    items += 1
                    guard string(of: item, kAXRoleAttribute) == kAXMenuItemRole else { continue }
                    if matches(item) { return (item, path + [title(item)]) }
                    guard level < menuMaxDepth else { continue }
                    for submenu in children(of: item) where string(of: submenu, kAXRoleAttribute) == kAXMenuRole {
                        if let found = find(in: submenu, level: level + 1, path: path + [title(item)]) { return found }
                    }
                }
                return nil
            }
            var target: (item: AXUIElement, path: [String])?
            search: for barItem in children(of: menuBar).dropFirst() {
                for menu in children(of: barItem) where string(of: menu, kAXRoleAttribute) == kAXMenuRole {
                    target = find(in: menu, level: 1, path: [title(barItem)])
                    if target != nil { break search }
                }
            }
            guard let target else { return nil }
            // The walk can take seconds: the user may have taken over, or a secure field focus, since it started.
            switch interrupt() {
            case .cancelled: throw CancellationError()
            case .userActive: throw ComputerUseSystemError.userActive
            case nil: break
            }
            if let focused = focusedElement(of: app), isSecure(focused) { throw secureRefusal }
            try press(target.item, app: app)
            return target.path.joined(separator: " > ")
        }
    }

    /// Inserts `text` at the element's caret, replacing its selection. Refuses secure text fields.
    /// Focuses the element first, keeping its selection; see `insert` for chunking and interrupts.
    static func insertText(
        _ text: String, _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        try await onQueue({ interrupt() == .cancelled }) {
            let element = try resolve(handles, handle)
            try refuseSecure(element, app: app)
            focusKeepingSelection(element, app: app)
            try insert(text, into: element, app: app, interrupt: interrupt)
        }
    }

    /// Types into the app's focused element: replaces its value or inserts at its caret.
    /// Refuses secure text fields; `Unsupported` when nothing has focus.
    static func typeIntoFocused(
        _ text: String, replace: Bool, app: ComputerUseAppIdentity,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        try await onQueue({ interrupt() == .cancelled }) {
            guard let element = focusedElement(of: app) else { throw Unsupported(error: .noValue) }
            try refuseSecure(element, app: app)
            if replace {
                let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
                guard result == .success else { throw failure(result, app: app) }
            } else {
                try insert(text, into: element, app: app, interrupt: interrupt)
            }
        }
    }

    /// Focusing a text view may move its caret or drop its selection (an earlier ⌘A), so the
    /// range from before is put back. An element that already has focus is left alone.
    /// Best effort: the insert that follows reports what fails.
    private static func focusKeepingSelection(_ element: AXUIElement, app: ComputerUseAppIdentity) {
        if let focused = focusedElement(of: app), CFEqual(focused, element) { return }
        let range = selectedRange(of: element)
        guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              var range, let value = AXValueCreate(.cfRange, &range)
        else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// The app's focused element as an input could change it; nil when nothing readable has focus.
    /// A secure field's value is never read.
    static func focusState(of app: ComputerUseAppIdentity) async -> ComputerUseWindowFingerprint.Focus? {
        try? await onQueue({ false }) {
            guard let element = focusedElement(of: app) else { return nil }
            let role = string(of: element, kAXRoleAttribute) ?? "AXUnknown"
            var valueHash: Int?
            if !isSecure(element) {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, let value {
                    valueHash = (value as? String)?.hashValue ?? (value as? NSNumber)?.hashValue
                }
            }
            return ComputerUseWindowFingerprint.Focus(
                role: role, title: string(of: element, kAXTitleAttribute), valueHash: valueHash,
                selectedRange: selectedRange(of: element).map { [$0.location, $0.length] })
        }
    }

    /// Whether the app's focused element is the one behind `handle`.
    static func isFocused(
        _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity, isCancelled: @escaping IsCancelled
    ) async throws -> Bool {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            guard let focused = focusedElement(of: app) else { return false }
            return CFEqual(focused, element)
        }
    }

    /// Scrolls the scroll area around the target through its scroll bars, by lines.
    /// Positive `dy` scrolls down and positive `dx` right. A point target must hit `window`.
    /// Checks `interrupt` before every step: once part of the scroll happened it stops there
    /// and reports success, so no event fallback scrolls the same axis again.
    static func scroll(
        _ target: ComputerUseInputTarget, dx: Int, dy: Int, in window: ComputerUseWindow,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        let app = window.app
        try await onQueue({ interrupt() == .cancelled }) {
            let start: AXUIElement
            switch target {
            case .element(let handles, let handle):
                start = try resolve(handles, handle)
            case .point(let point):
                let application = ComputerUseAXReader.application(app.pid)
                var hit: AXUIElement?
                let result = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
                if result == .cannotComplete || result == .apiDisabled, let error = mapped(result, app: app) { throw error }
                guard result == .success, let hit else { throw Unsupported(error: result) }
                AXUIElementSetMessagingTimeout(hit, ComputerUseAXReader.messagingTimeout)
                // Another of the app's windows may be on top at that point.
                guard let hitWindow = elementAttribute(hit, kAXWindowAttribute),
                      ComputerUseAXReader.matchingWindow(
                          [hitWindow], for: window, frame: frame(of:), title: { string(of: $0, kAXTitleAttribute) }) != nil
                else { throw Unsupported(error: .illegalArgument) }
                start = hit
            }
            guard let area = ancestor(of: start, levels: scrollAncestorLevels, where: {
                string(of: $0, kAXRoleAttribute) == kAXScrollAreaRole
            }) else { throw Unsupported(error: .attributeUnsupported) }
            // Every axis must be scrollable before any moves, so a fallback never scrolls one twice.
            var steps: [(bar: AXUIElement, delta: Int, action: String?, vertical: Bool)] = []
            for (attribute, delta, vertical) in [
                (kAXVerticalScrollBarAttribute, dy, true), (kAXHorizontalScrollBarAttribute, dx, false),
            ] where delta != 0 {
                guard let bar = elementAttribute(area, attribute) else { throw Unsupported(error: .attributeUnsupported) }
                let action = delta > 0 ? kAXIncrementAction : kAXDecrementAction
                if actionNames(of: bar).contains(action) {
                    steps.append((bar, delta, action, vertical))
                } else if isSettable(bar, kAXValueAttribute) {
                    steps.append((bar, delta, nil, vertical))
                } else {
                    throw Unsupported(error: .actionUnsupported)
                }
            }
            var moved = false
            /// False once the scroll should stop where it got to; throws when nothing moved yet.
            func mayContinue() throws -> Bool {
                guard let reason = interrupt() else { return true }
                if moved { return false }
                switch reason {
                case .cancelled: throw CancellationError()
                case .userActive: throw ComputerUseSystemError.userActive
                }
            }
            for step in steps {
                let lines = min(abs(step.delta), maxScrollSteps)
                if let action = step.action {
                    for _ in 0 ..< lines {
                        guard try mayContinue() else { return }
                        let result = AXUIElementPerformAction(step.bar, action as CFString)
                        guard result == .success else {
                            if !moved { throw failure(result, app: app) }
                            // Part of the scroll happened; stop rather than retry it with events.
                            return
                        }
                        moved = true
                    }
                } else {
                    guard try mayContinue() else { return }
                    guard let current = double(of: step.bar, kAXValueAttribute) else {
                        if !moved { throw Unsupported(error: .noValue) }
                        return
                    }
                    let perLine = valuePerLine(of: area, vertical: step.vertical)
                    let offset = Double(lines) * perLine * (step.delta > 0 ? 1 : -1)
                    let next = min(1, max(0, current + offset))
                    let result = AXUIElementSetAttributeValue(step.bar, kAXValueAttribute as CFString, next as CFNumber)
                    guard result == .success else {
                        if !moved { throw failure(result, app: app) }
                        return
                    }
                    moved = true
                }
            }
        }
    }

    /// Points a scrolled line covers, as a wheel line roughly does.
    static let scrollLinePoints = 16.0

    /// The scroll bar value one line moves: a line over the scrollable extent (content minus
    /// visible size), or `scrollValuePerLine` when the sizes can't be read.
    private static func valuePerLine(of area: AXUIElement, vertical: Bool) -> Double {
        var contents: CFTypeRef?
        guard let visible = frame(of: area),
              AXUIElementCopyAttributeValue(area, kAXContentsAttribute as CFString, &contents) == .success,
              let content = (contents as? [AXUIElement])?.first
        else { return scrollValuePerLine }
        AXUIElementSetMessagingTimeout(content, ComputerUseAXReader.messagingTimeout)
        guard let contentFrame = frame(of: content) else { return scrollValuePerLine }
        let extent = vertical ? contentFrame.height - visible.height : contentFrame.width - visible.width
        guard extent > 0 else { return scrollValuePerLine }
        return min(1, max(0, scrollLinePoints / Double(extent)))
    }

    /// A left click on an element without AXPress, decided by `ComputerUseClickTarget`: presses
    /// the nearest pressable element below the first container, else selects the row that
    /// container is. A double click selects the row, then opens it.
    static func pressOrSelectNearest(
        _ handles: ComputerUseAXHandles, _ handle: Int, count: Int, app: ComputerUseAppIdentity,
        isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            var elements = [element]
            var links = [(role: string(of: element, kAXRoleAttribute) ?? "AXUnknown", actions: actionNames(of: element))]
            // The pressable levels plus the container above them, which may be the row to select.
            while elements.count <= ComputerUseClickTarget.maxLevels,
                  !ComputerUseClickTarget.stopRoles.contains(links[links.count - 1].role),
                  let parent = elementAttribute(elements[elements.count - 1], kAXParentAttribute) {
                elements.append(parent)
                links.append((string(of: parent, kAXRoleAttribute) ?? "AXUnknown", actionNames(of: parent)))
            }
            switch ComputerUseClickTarget.choose(chain: links) {
            case .press(let index) where count == 1:
                try press(elements[index], app: app)
            case .selectRow(let index):
                let row = elements[index]
                try select(row, app: app)
                guard count == 2 else { return }
                // Selected but not opened: the double click as events finishes it.
                guard let open = [openAction, kAXPressAction].first(where: links[index].actions.contains) else {
                    throw Unsupported(error: .actionUnsupported)
                }
                try press(row, action: open, app: app)
            case .press, .none:
                throw Unsupported(error: .actionUnsupported)
            }
        }
    }

    /// No header constant exists for it.
    private static let openAction = "AXOpen"

    /// Selects the row through its table or outline (`AXSelectedRows`), else the row's own
    /// `AXSelected`, then reads it back: some apps report success and select nothing, which is
    /// `Unsupported` so the click goes as events instead.
    private static func select(_ row: AXUIElement, app: ComputerUseAppIdentity) throws {
        let container = elementAttribute(row, kAXParentAttribute)
        var result = AXError.attributeUnsupported
        if let container, isSettable(container, kAXSelectedRowsAttribute) {
            result = AXUIElementSetAttributeValue(container, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
        }
        if result != .success {
            result = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        }
        if let error = mapped(result, app: app) { throw error }
        guard isSelected(row, in: container) else { throw Unsupported(error: result == .success ? .actionUnsupported : result) }
    }

    private static func isSelected(_ row: AXUIElement, in container: AXUIElement?) -> Bool {
        if bool(of: row, kAXSelectedAttribute) == true { return true }
        guard let container else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(container, kAXSelectedRowsAttribute as CFString, &value) == .success,
              let rows = value as? [AXUIElement]
        else { return false }
        return rows.contains { CFEqual($0, row) }
    }

    private static func press(_ element: AXUIElement, action: String = kAXPressAction, app: ComputerUseAppIdentity) throws {
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            // A modal panel opened by the action keeps the app from answering in time.
            if result == .cannotComplete {
                throw ComputerUseSystemError.actionFailed(
                    "\(app.name) didn't confirm the action; it may have happened. Call computer_inspect before retrying.")
            }
            throw failure(result, app: app)
        }
    }

    /// Sets the selected text `insertChunkCharacters` characters at a time, checking `interrupt`
    /// between chunks: a stop throws `CancellationError` and a takeover `userTookOver` with the
    /// characters inserted so far. Checks the first chunk went in, since some apps report success
    /// and insert nothing; that first failure is `Unsupported`, so events may type the text instead.
    /// Any later failure is a tool error, so nothing already inserted gets typed twice.
    private static func insert(
        _ text: String, into element: AXUIElement, app: ComputerUseAppIdentity,
        interrupt: @Sendable () -> ComputerUseInputInterrupt?
    ) throws {
        guard isSettable(element, kAXSelectedTextAttribute) else { throw Unsupported(error: .attributeUnsupported) }
        let total = text.count
        var rest = Substring(text)
        var typed = 0
        repeat {
            let chunk = String(rest.prefix(insertChunkCharacters))
            rest = rest.dropFirst(chunk.count)
            if typed > 0 {
                switch interrupt() {
                case .cancelled: throw CancellationError()
                case .userActive: throw ComputerUseSystemError.userTookOver(typed: typed, of: total)
                case nil: break
                }
            }
            let countBefore = typed == 0 ? number(of: element, kAXNumberOfCharactersAttribute) : nil
            let selectionWasEmpty = typed == 0 ? selectedRange(of: element).map { $0.length == 0 } : nil
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, chunk as CFString)
            guard result == .success else {
                if typed == 0 { throw failure(result, app: app) }
                throw ComputerUseSystemError.actionFailed(
                    "\(app.name) stopped taking the text after \(typed) of \(total) characters (AXError \(result.rawValue)).")
            }
            // Only with nothing selected does an unchanged length prove nothing went in, so events can't type it twice.
            if typed == 0, !chunk.isEmpty, selectionWasEmpty == true, let countBefore,
               number(of: element, kAXNumberOfCharactersAttribute) == countBefore {
                throw Unsupported(error: .attributeUnsupported)
            }
            typed += chunk.count
        } while !rest.isEmpty
    }

    private static func focusedElement(of app: ComputerUseAppIdentity) -> AXUIElement? {
        let application = ComputerUseAXReader.application(app.pid)
        return elementAttribute(application, kAXFocusedUIElementAttribute)
    }

    private static func ancestor(
        of element: AXUIElement, levels: Int, where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var current = element
        for _ in 0 ... levels {
            if predicate(current) { return current }
            guard let parent = elementAttribute(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// An element-valued attribute, with the messaging timeout set on it.
    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, ComputerUseAXReader.messagingTimeout)
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return [] }
        for child in children {
            AXUIElementSetMessagingTimeout(child, ComputerUseAXReader.messagingTimeout)
        }
        return children
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func number(of element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFNumberGetTypeID()
        else { return nil }
        return (value as! NSNumber).intValue
    }

    private static func double(of element: AXUIElement, _ attribute: String) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFNumberGetTypeID()
        else { return nil }
        return (value as! NSNumber).doubleValue
    }

    private static func bool(of element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
}
