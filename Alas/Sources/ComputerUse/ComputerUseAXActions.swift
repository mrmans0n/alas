import AlasCore
import ApplicationServices
import CoreGraphics
import Foundation

/// AX actions on elements retained by a read. They run on the reader's serial
/// queue, so they never overlap a walk, with the same per-message timeout.
enum ComputerUseAXActions {
    /// An AX call failed in a way an event at the element might still get past.
    struct Unsupported: Error {
        var error: AXError
    }

    static func press(_ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity) async throws {
        try await perform(kAXPressAction, handles, handle, app: app)
    }

    static func showMenu(_ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity) async throws {
        try await perform(kAXShowMenuAction, handles, handle, app: app)
    }

    /// Replaces the element's value. Refuses secure text fields.
    static func setValue(
        _ text: String, _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity
    ) async throws {
        try await onQueue {
            let element = try resolve(handles, handle)
            try refuseSecure(element, app: app)
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            guard result == .success else {
                throw mapped(result, app: app)
                    ?? ComputerUseSystemError.actionFailed("\(app.name) did not accept the value (AXError \(result.rawValue)).")
            }
        }
    }

    /// Focuses the element before typing into it. Refuses secure text fields.
    static func focus(_ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity) async throws {
        try await onQueue {
            let element = try resolve(handles, handle)
            try refuseSecure(element, app: app)
            let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard result == .success else {
                throw mapped(result, app: app)
                    ?? ComputerUseSystemError.actionFailed("\(app.name) did not focus the element (AXError \(result.rawValue)).")
            }
        }
    }

    /// The element's centre from its current position and size, global points.
    static func center(_ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity) async throws -> CGPoint {
        try await onQueue {
            let element = try resolve(handles, handle)
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(try value(element, kAXPositionAttribute, app: app), .cgPoint, &position),
                  AXValueGetValue(try value(element, kAXSizeAttribute, app: app), .cgSize, &size)
            else { throw noFrame }
            return ComputerUseInputGeometry.center(of: CGRect(origin: position, size: size))
        }
    }

    /// Throws `Unsupported` when the app refused the action for a reason other
    /// than a stale element or a stalled app.
    private static func perform(
        _ action: String, _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity
    ) async throws {
        try await onQueue {
            let element = try resolve(handles, handle)
            let result = AXUIElementPerformAction(element, action as CFString)
            guard result == .success else { throw mapped(result, app: app) ?? Unsupported(error: result) }
        }
    }

    /// Runs `body` on the reader's queue. A call cancelled while queued makes no AX request.
    private static func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let cancel = ComputerUseAXReader.CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ComputerUseAXReader.queue.async {
                    if cancel.isSet {
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

    /// Read live rather than trusting the cached node: the element may have changed.
    private static func refuseSecure(_ element: AXUIElement, app: ComputerUseAppIdentity) throws {
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if let error = mapped(result, app: app) { throw error }
            if result == .success, let string = value as? String, string == kAXSecureTextFieldSubrole {
                throw ComputerUseSystemError.actionFailed("Secure text fields can't be typed into.")
            }
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
