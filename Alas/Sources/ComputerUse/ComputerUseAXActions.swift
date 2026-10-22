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
