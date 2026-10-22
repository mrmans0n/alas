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
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, ComputerUseAXReader.messagingTimeout)
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
    /// if needed, or refuses. Events posted to the pid can't pick a window themselves.
    static func makeActiveWindow(_ window: ComputerUseWindow, isCancelled: @escaping IsCancelled) async throws {
        try await onQueue(isCancelled) {
            let app = window.app
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, ComputerUseAXReader.messagingTimeout)
            let notActive = ComputerUseSystemError.actionFailed(
                "Window \(window.windowID) isn't \(app.name)'s active window. Click in it first or pass delivery: \"direct\".")
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete || result == .apiDisabled, let error = mapped(result, app: app) { throw error }
            guard result == .success, let axWindows = windowsRef as? [AXUIElement],
                  let target = ComputerUseAXReader.matchingWindow(
                      axWindows, for: window, frame: frame(of:), title: { string(of: $0, kAXTitleAttribute) })
            else { throw notActive }
            if isFocusedWindow(target, of: application) { return }
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            guard isFocusedWindow(target, of: application) else { throw notActive }
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
    /// Menu levels walked for a shortcut: a top-level menu is level 1.
    static let menuMaxDepth = 4
    static let menuMaxItems = 2000
    /// Ancestors searched for something to press or a row to select.
    static let clickAncestorLevels = 4
    /// Ancestors searched for the scroll area around an element.
    static let scrollAncestorLevels = 8
    static let maxScrollSteps = 100
    /// Scroll bar value moved per line when the bar takes no increment action.
    static let scrollValuePerLine = 0.05

    /// The `AXMenuItemCmdModifiers` mask for a chord; nil when it has none of command,
    /// control or option, or uses fn, which menu shortcuts can't express.
    static func menuModifiers(_ chord: ComputerUseKeyChord) -> Int? {
        let modifiers = chord.modifiers
        guard !modifiers.contains(.function), !modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        // AXMenuItemModifiers: 0 is command alone; shift, option and control add bits 0-2, bit 3 drops command.
        var mask = 0
        if modifiers.contains(.shift) { mask |= 1 << 0 }
        if modifiers.contains(.option) { mask |= 1 << 1 }
        if modifiers.contains(.control) { mask |= 1 << 2 }
        if !modifiers.contains(.command) { mask |= 1 << 3 }
        return mask
    }

    /// Characters AppKit reports as the shortcut of a menu item bound to a named key.
    private static let namedKeyCharacters: [ComputerUseKeyChord.NamedKey: Set<String>] = [
        .return: ["\r", "\n"], .tab: ["\t"], .space: [" "], .escape: ["\u{1B}"], .delete: ["\u{8}", "\u{7F}"],
    ]

    /// Presses the enabled menu item whose shortcut is `chord`; false when no menu item has it.
    /// Skips the Apple menu: its shortcuts (log out, force quit) belong to the system.
    static func pressMenuShortcut(
        _ chord: ComputerUseKeyChord, app: ComputerUseAppIdentity, isCancelled: @escaping IsCancelled
    ) async throws -> Bool {
        guard let mask = menuModifiers(chord) else { return false }
        let character: String?
        let virtualKey: Int?
        let namedCharacters: Set<String>
        switch chord.key {
        case .character(let key):
            character = key.lowercased()
            virtualKey = nil
            namedCharacters = []
        case .named(let named):
            character = nil
            virtualKey = ComputerUseInputPoster.keyCode(for: chord.key).map(Int.init)
            namedCharacters = namedKeyCharacters[named] ?? []
        }
        return try await onQueue(isCancelled) {
            // The shortcut key first: most items have none, which settles them in one read.
            func matches(_ item: AXUIElement) -> Bool {
                let cmdChar = string(of: item, kAXMenuItemCmdCharAttribute)
                if let character {
                    guard cmdChar?.lowercased() == character else { return false }
                } else if let cmdChar {
                    guard namedCharacters.contains(cmdChar) else { return false }
                } else {
                    guard let virtualKey, number(of: item, kAXMenuItemCmdVirtualKeyAttribute) == virtualKey else { return false }
                }
                return (number(of: item, kAXMenuItemCmdModifiersAttribute) ?? 0) == mask
                    && bool(of: item, kAXEnabledAttribute) == true
            }
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, ComputerUseAXReader.messagingTimeout)
            guard let menuBar = elementAttribute(application, kAXMenuBarAttribute) else { return false }
            let deadline = ContinuousClock.now + ComputerUseAXReader.deadline
            var items = 0
            func find(in menu: AXUIElement, level: Int) -> AXUIElement? {
                for item in children(of: menu) {
                    guard items < menuMaxItems, ContinuousClock.now < deadline, !isCancelled() else { return nil }
                    items += 1
                    guard string(of: item, kAXRoleAttribute) == kAXMenuItemRole else { continue }
                    if matches(item) { return item }
                    guard level < menuMaxDepth else { continue }
                    for submenu in children(of: item) where string(of: submenu, kAXRoleAttribute) == kAXMenuRole {
                        if let found = find(in: submenu, level: level + 1) { return found }
                    }
                }
                return nil
            }
            var target: AXUIElement?
            search: for barItem in children(of: menuBar).dropFirst() {
                for menu in children(of: barItem) where string(of: menu, kAXRoleAttribute) == kAXMenuRole {
                    target = find(in: menu, level: 1)
                    if target != nil { break search }
                }
            }
            guard let target else { return false }
            if isCancelled() { throw CancellationError() }
            try press(target, app: app)
            return true
        }
    }

    /// Inserts `text` at the element's caret, replacing its selection. Refuses secure text fields.
    static func insertText(
        _ text: String, _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity,
        isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            try refuseSecure(element, app: app)
            try insert(text, into: element, app: app)
        }
    }

    /// Types into the app's focused element: replaces its value or inserts at its caret.
    /// Refuses secure text fields; `Unsupported` when nothing has focus.
    static func typeIntoFocused(
        _ text: String, replace: Bool, app: ComputerUseAppIdentity, isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            guard let element = focusedElement(of: app) else { throw Unsupported(error: .noValue) }
            try refuseSecure(element, app: app)
            if replace {
                let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
                guard result == .success else { throw failure(result, app: app) }
            } else {
                try insert(text, into: element, app: app)
            }
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
    static func scroll(
        _ target: ComputerUseInputTarget, dx: Int, dy: Int, in window: ComputerUseWindow, isCancelled: @escaping IsCancelled
    ) async throws {
        let app = window.app
        try await onQueue(isCancelled) {
            let start: AXUIElement
            switch target {
            case .element(let handles, let handle):
                start = try resolve(handles, handle)
            case .point(let point):
                let application = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(application, ComputerUseAXReader.messagingTimeout)
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
            var steps: [(bar: AXUIElement, delta: Int, action: String?)] = []
            for (attribute, delta) in [(kAXVerticalScrollBarAttribute, dy), (kAXHorizontalScrollBarAttribute, dx)] where delta != 0 {
                guard let bar = elementAttribute(area, attribute) else { throw Unsupported(error: .attributeUnsupported) }
                let action = delta > 0 ? kAXIncrementAction : kAXDecrementAction
                if actionNames(of: bar).contains(action) {
                    steps.append((bar, delta, action))
                } else if isSettable(bar, kAXValueAttribute) {
                    steps.append((bar, delta, nil))
                } else {
                    throw Unsupported(error: .actionUnsupported)
                }
            }
            var moved = false
            for step in steps {
                if let action = step.action {
                    for _ in 0 ..< min(abs(step.delta), maxScrollSteps) {
                        let result = AXUIElementPerformAction(step.bar, action as CFString)
                        guard result == .success else {
                            if !moved { throw failure(result, app: app) }
                            // Part of the scroll happened; stop rather than retry it with events.
                            return
                        }
                        moved = true
                    }
                } else {
                    guard let current = double(of: step.bar, kAXValueAttribute) else {
                        if !moved { throw Unsupported(error: .noValue) }
                        return
                    }
                    let lines = Double(min(abs(step.delta), maxScrollSteps)) * (step.delta > 0 ? 1 : -1)
                    let next = min(1, max(0, current + lines * scrollValuePerLine))
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

    /// A left click on an element without AXPress: presses the nearest ancestor that has it,
    /// else selects the row the element is in. A double click selects the row, then opens it.
    static func pressOrSelectNearest(
        _ handles: ComputerUseAXHandles, _ handle: Int, count: Int, app: ComputerUseAppIdentity,
        isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            var chain = [element]
            var current = element
            for _ in 0 ..< clickAncestorLevels {
                // Never past the window: pressing it or the app is not a click on the element.
                guard let parent = elementAttribute(current, kAXParentAttribute),
                      let role = string(of: parent, kAXRoleAttribute),
                      ![kAXWindowRole, kAXSheetRole, kAXApplicationRole].contains(role)
                else { break }
                chain.append(parent)
                current = parent
            }
            let row = chain.first { string(of: $0, kAXRoleAttribute) == kAXRowRole }
            if count == 1 {
                if let pressable = chain.dropFirst().first(where: { actionNames(of: $0).contains(kAXPressAction) }) {
                    try press(pressable, app: app)
                    return
                }
                guard let row else { throw Unsupported(error: .actionUnsupported) }
                try select(row, app: app)
                return
            }
            guard count == 2, let row else { throw Unsupported(error: .actionUnsupported) }
            try select(row, app: app)
            let actions = actionNames(of: row)
            // Selected but not opened: the double click as events finishes it.
            guard let open = [openAction, kAXPressAction].first(where: actions.contains) else {
                throw Unsupported(error: .actionUnsupported)
            }
            try press(row, action: open, app: app)
        }
    }

    /// No header constant exists for it.
    private static let openAction = "AXOpen"

    private static func select(_ row: AXUIElement, app: ComputerUseAppIdentity) throws {
        let result = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        guard result == .success else { throw failure(result, app: app) }
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

    /// Sets the selected text and checks the app took it: some report success and insert nothing.
    private static func insert(_ text: String, into element: AXUIElement, app: ComputerUseAppIdentity) throws {
        guard isSettable(element, kAXSelectedTextAttribute) else { throw Unsupported(error: .attributeUnsupported) }
        let countBefore = number(of: element, kAXNumberOfCharactersAttribute)
        let selectionWasEmpty = selectedRange(of: element).map { $0.length == 0 }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard result == .success else { throw failure(result, app: app) }
        // Only with nothing selected does an unchanged length prove nothing went in, so events can't type it twice.
        if !text.isEmpty, selectionWasEmpty == true, let countBefore,
           number(of: element, kAXNumberOfCharactersAttribute) == countBefore {
            throw Unsupported(error: .attributeUnsupported)
        }
    }

    private static func focusedElement(of app: ComputerUseAppIdentity) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(application, ComputerUseAXReader.messagingTimeout)
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
