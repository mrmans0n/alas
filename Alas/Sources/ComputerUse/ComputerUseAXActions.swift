import AlasCore
import ApplicationServices
import CoreGraphics
import Foundation

/// AX actions on elements retained by a read. They run on the reader's serial
/// queue, so they never overlap a walk, with the same per-message timeout.
/// `isCancelled` is checked on the queue right before the AX call, so a Stop
/// that lands while the call waits behind a walk performs nothing. Calls that
/// change the app take the whole `interrupt`: the user may also have come back
/// to it while the call waited.
enum ComputerUseAXActions {
    typealias IsCancelled = @Sendable () -> Bool
    typealias Interrupt = @Sendable () -> ComputerUseInputInterrupt?

    /// An AX call failed in a way an event at the element might still get past.
    struct Unsupported: Error {
        var error: AXError
    }

    /// An AX press the app didn't answer in time (kAXErrorCannotComplete). It most likely took
    /// effect: a modal panel the press opened keeps the app from replying until it closes. The
    /// input counts as delivered, with `unconfirmedWarning`, and is never pressed again.
    struct Unconfirmed: Error {
        var menuItem: String?
        var button: String?
    }

    static let unconfirmedWarning =
        "The app didn't answer in time; the press probably took effect (a modal panel may be open). Inspect to check."

    static func press(
        _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity, interrupt: @escaping Interrupt
    ) async throws {
        try await perform(kAXPressAction, handles, handle, app: app, interrupt: interrupt)
    }

    static func showMenu(
        _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity, interrupt: @escaping Interrupt
    ) async throws {
        try await perform(kAXShowMenuAction, handles, handle, app: app, interrupt: interrupt)
    }

    /// Replaces the element's value. Refuses secure text fields. Throws
    /// `Unsupported` when the element doesn't take a value this way, or reads
    /// back as it was, so typing can be tried instead.
    static func setValue(
        _ text: String, _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity,
        interrupt: @escaping Interrupt
    ) async throws {
        try await onQueue(interrupt: interrupt) {
            let element = try resolve(handles, handle)
            try refuseSecure(element, app: app)
            try setValueChecked(text, element, app: app)
        }
    }

    /// Refuses typing when the app's focused element is a secure text field.
    /// Proceeds when the focused element can't be read.
    static func refuseSecureFocus(app: ComputerUseAppIdentity, isCancelled: @escaping IsCancelled) async throws {
        try await onQueue(isCancelled) {
            let application = try ComputerUseAXReader.target(app.pid)
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

    /// Refuses a chord that may edit text while a secure field reads as focused: the app's focused
    /// element, or one inside the window. In a web page a field can read as focused while the
    /// keyboard stays in the address bar, which the app reports as its focused element. A read of
    /// the window cut short checks what it reached; the app-level check still runs either way.
    static func refuseSecureFocus(
        _ chord: ComputerUseKeyChord, in window: ComputerUseWindow, isCancelled: @escaping IsCancelled
    ) async throws {
        guard chord.mayEditText else { return }
        let app = window.app
        var focused = try await onQueue(isCancelled) { () -> [ComputerUseSecureFocus.Element] in
            guard let element = focusedElement(of: app) else { return [] }
            return [ComputerUseSecureFocus.Element(
                role: string(of: element, kAXRoleAttribute), subrole: string(of: element, kAXSubroleAttribute))]
        }
        if let tree = try? await ComputerUseAXReader.read(
            window, maxDepth: secureFocusDepth, nodeBudget: secureFocusNodes, timeLimit: secureFocusTime) {
            func collect(_ node: ComputerUseAXNode) {
                if node.isFocused { focused.append(.init(role: node.role, subrole: node.subrole)) }
                node.children.forEach(collect)
            }
            collect(tree.root)
        }
        try Task.checkCancellation()
        if isCancelled() { throw CancellationError() }
        if ComputerUseSecureFocus.refuses(chord, focused: focused) { throw secureRefusal }
    }

    static let webAreaAncestorLevels = 32
    private static let webAreaRole = "AXWebArea"
    static let secureFocusDepth = 32
    static let secureFocusNodes = 3000
    static let secureFocusTime: Duration = .milliseconds(500)

    /// For a left click by ref on a web page's field: puts the keyboard in it, as a click would,
    /// where an AX press may only mark it focused inside the page. False, touching nothing, for
    /// any other element (`ComputerUseSecureFocus.focusesOnClick`). A secure field may be
    /// clicked; only typing into one is refused.
    static func focusTextEntry(
        _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity, interrupt: @escaping Interrupt
    ) async throws -> Bool {
        try await onQueue(interrupt: interrupt) {
            let element = try resolve(handles, handle)
            let identity = ComputerUseSecureFocus.Element(
                role: string(of: element, kAXRoleAttribute), subrole: string(of: element, kAXSubroleAttribute))
            guard ComputerUseSecureFocus.isTextEntry(identity) else { return false }
            let inWebArea = ancestor(of: element, levels: webAreaAncestorLevels) {
                string(of: $0, kAXRoleAttribute) == webAreaRole
            } != nil
            guard ComputerUseSecureFocus.focusesOnClick(identity, inWebArea: inWebArea) else { return false }
            // Confirmed by the caller through the app's focused element, so the result says nothing.
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return true
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
                // Gone, or this process's: never messaged (P5-R13).
                guard let element = try? resolve(handles, handle) else { return continuation.resume(returning: false) }
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

    /// Where pointer input lands on the element: the centre of the part its nearest scroll area
    /// and `window` show, global points. Nil when none of it shows, or with `requireOwnCenter` when
    /// its own centre is scrolled or moved out of view.
    static func visibleCenter(
        _ handles: ComputerUseAXHandles, _ handle: Int, within window: CGRect, app: ComputerUseAppIdentity,
        requireOwnCenter: Bool, isCancelled: @escaping IsCancelled
    ) async throws -> CGPoint? {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(try value(element, kAXPositionAttribute, app: app), .cgPoint, &position),
                  AXValueGetValue(try value(element, kAXSizeAttribute, app: app), .cgSize, &size)
            else { throw noFrame }
            return ComputerUseInputGeometry.visibleCenter(
                of: CGRect(origin: position, size: size), clippedTo: clips(of: element, within: window),
                requireOwnCenter: requireOwnCenter)
        }
    }

    /// Whether any of the element shows in its nearest scroll area and `window`, as inspect's
    /// `visible` says. An element whose frame can't be read counts as shown, as in inspect: an
    /// AX action on it needs no position.
    static func isShown(
        _ handles: ComputerUseAXHandles, _ handle: Int, within window: CGRect, isCancelled: @escaping IsCancelled
    ) async throws -> Bool {
        try await onQueue(isCancelled) {
            let element = try resolve(handles, handle)
            guard let frame = frame(of: element) else { return true }
            return ComputerUseInputGeometry.isShown(frame, clippedTo: clips(of: element, within: window))
        }
    }

    static let hiddenRefusal = ComputerUseSystemError.actionFailed("The element is scrolled out of view or hidden.")

    /// The element at a point as `ComputerUseInputGeometry.pointRoute` weighs it: retained in
    /// `handles` (handle 0), so an AX action can go to it like to an inspected one.
    struct PointElement: Sendable {
        var hit: ComputerUseInputGeometry.PointHit
        var handles: ComputerUseAXHandles
    }

    /// The element at `point`, global points, as the app hit-tests its own windows (also under
    /// other apps' windows), or, when that finds nothing real there
    /// (`ComputerUseInputGeometry.isRealHit`), the deepest element of `window` holding the point
    /// (`path(at:in:application:)`); nil when there is none or it can't be read. Never the
    /// system-wide hit test: what is on top may be Alas's own window (the drawn cursor), and an AX
    /// message to this process runs its AppKit handlers right here, off the main thread.
    static func element(
        at point: CGPoint, in window: ComputerUseWindow, isCancelled: @escaping IsCancelled
    ) async throws -> PointElement? {
        try await onQueue(isCancelled) {
            let application = try ComputerUseAXReader.target(window.app.pid)
            guard let element = hit(at: point, in: window, application: application) else { return nil }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return nil }
            return PointElement(hit: .init(pid: pid, frame: frame(of: element)), handles: ComputerUseAXHandles([element]))
        }
    }

    /// In an app that hosts content remotely (`ComputerUseRemoteContent`), the element an x/y
    /// input at `point` goes to as AX: the deepest pressable element (click) or scroll area
    /// (scroll) on the way down `window` to the point; nil when there is none.
    static func remoteContentElement(
        at point: CGPoint, in window: ComputerUseWindow, for input: ComputerUseRemoteContent.Input,
        isCancelled: @escaping IsCancelled
    ) async throws -> ComputerUseAXHandles? {
        try await onQueue(isCancelled) {
            let application = try ComputerUseAXReader.target(window.app.pid)
            let path = path(at: point, in: window, application: application)
            let steps = path.map {
                ComputerUseRemoteContent.Step(role: string(of: $0, kAXRoleAttribute) ?? "AXUnknown", actions: actionNames(of: $0))
            }
            return ComputerUseRemoteContent.target(for: input, path: steps).map { ComputerUseAXHandles([path[$0]]) }
        }
    }

    /// The app's own hit at `point` when it is real, else the deepest element of `window` holding
    /// the point; never an element of this process. Call on the AX queue.
    private static func hit(at point: CGPoint, in window: ComputerUseWindow, application: AXUIElement) -> AXUIElement? {
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element) == .success,
           let element, isMessageable(element) {
            AXUIElementSetMessagingTimeout(element, ComputerUseAXReader.messagingTimeout)
            if ComputerUseInputGeometry.isRealHit(role: string(of: element, kAXRoleAttribute), frame: frame(of: element), point: point) {
                return element
            }
        }
        let path = path(at: point, in: window, application: application)
        // The window alone is no element at the point.
        return path.count > 1 ? path.last : nil
    }

    /// How deep, how wide and how long the walk down a window to the element at a point goes.
    static let descentDepth = 16
    static let descentNodes = 200
    static let descentTime: Duration = .seconds(1)

    /// `window`'s AX window, then at each level the front-most child whose frame holds `point`
    /// (`ComputerUseInputGeometry.frontmostChild`), down to the deepest; empty when the window
    /// can't be found. Never an element of this process. Call on the AX queue.
    static func path(at point: CGPoint, in window: ComputerUseWindow, application: AXUIElement) -> [AXUIElement] {
        guard let root = axWindow(elements(of: application, kAXWindowsAttribute), for: window) else { return [] }
        let deadline = ContinuousClock.now + descentTime
        var path = [root]
        var visited = 0
        for _ in 0 ..< descentDepth {
            var candidates: [AXUIElement] = []
            var layers: [(role: String?, frame: CGRect?)] = []
            for child in children(of: path[path.count - 1]) {
                visited += 1
                // Out of budget mid-level: the front-most child may be among those not read yet.
                guard visited <= descentNodes, ContinuousClock.now < deadline else { return path }
                guard isMessageable(child), let childFrame = frame(of: child),
                      ComputerUseInputGeometry.holds(childFrame, point)
                else { continue }
                candidates.append(child)
                layers.append((string(of: child, kAXRoleAttribute), childFrame))
            }
            guard let index = ComputerUseInputGeometry.frontmostChild(holding: point, in: layers) else { break }
            path.append(candidates[index])
        }
        return path
    }

    /// Whether the element is another process's, which AX messages may go to (P5-R13).
    private static func isMessageable(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && ComputerUseAXReader.mayMessage(pid)
    }

    /// `window` and the element's nearest scroll area: what pointer input at it must land inside.
    private static func clips(of element: AXUIElement, within window: CGRect) -> [CGRect] {
        var clips = [window]
        if let parent = elementAttribute(element, kAXParentAttribute),
           let area = ancestor(of: parent, levels: scrollAncestorLevels, where: {
               string(of: $0, kAXRoleAttribute) == kAXScrollAreaRole
           }),
           let areaFrame = frame(of: area) {
            clips.append(areaFrame)
        }
        return clips
    }

    /// Makes the table or outline row holding the element (itself or up to `rowLevels` above) the
    /// only selected row, as a press on it would: Finder starts a drag only from a row already
    /// selected when the button goes down, and other selected rows would be dragged along.
    /// Sets the table's selected rows, else the row's own selected flag; nothing without a row.
    static func selectRow(_ handles: ComputerUseAXHandles, _ handle: Int, isCancelled: @escaping IsCancelled) async throws {
        try await onQueue(isCancelled) {
            guard let row = ancestor(of: try resolve(handles, handle), levels: rowLevels, where: {
                string(of: $0, kAXRoleAttribute) == kAXRowRole
            }) else { return }
            if let table = elementAttribute(row, kAXParentAttribute),
               [kAXTableRole, kAXOutlineRole].contains(string(of: table, kAXRoleAttribute)),
               isSettable(table, kAXSelectedRowsAttribute),
               AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success {
                return
            }
            guard isSettable(row, kAXSelectedAttribute) else { return }
            AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        }
    }

    static let rowLevels = 4

    /// Keys and typed text go to the app's key window: makes `window` that window, raising it
    /// if needed, or refuses with `notActiveWindow`. Events posted to the pid can't pick a window
    /// themselves. `raise` only with the app activated: an AXRaise on a background app can bring
    /// it to the front. With `raise` false it only checks.
    static func makeActiveWindow(
        _ window: ComputerUseWindow, raise: Bool, isCancelled: @escaping IsCancelled
    ) async throws {
        try await onQueue(isCancelled) {
            let app = window.app
            let application = try ComputerUseAXReader.target(app.pid)
            let notActive = ComputerUseSystemError.notActiveWindow(
                "Window \(window.windowID) isn't \(app.name)'s active window. Click in it first or pass delivery: \"direct\".")
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete || result == .apiDisabled, let error = mapped(result, app: app) { throw error }
            guard result == .success, let axWindows = windowsRef as? [AXUIElement],
                  let target = axWindow(axWindows, for: window)
            else { throw notActive }
            if isFocusedWindow(target, window, of: application) { return }
            guard raise else { throw notActive }
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            guard isFocusedWindow(target, window, of: application) else { throw notActive }
        }
    }

    /// Raises `window` above its app's other windows, without checking focus. For an activated app
    /// only: an AXRaise on a background app can bring it to the front.
    static func raise(_ window: ComputerUseWindow, isCancelled: @escaping IsCancelled) async throws {
        try await onQueue(isCancelled) {
            let app = window.app
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                try ComputerUseAXReader.target(app.pid), kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete || result == .apiDisabled, let error = mapped(result, app: app) { throw error }
            guard result == .success, let axWindows = windowsRef as? [AXUIElement],
                  let target = axWindow(axWindows, for: window)
            else { throw ComputerUseSystemError.windowNotFound(window.windowID) }
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        }
    }

    /// Whether `window` is its app's key window: the app reports itself frontmost, which follows
    /// AppKit's activation state rather than the user's front app, and `window` as its focused
    /// window. The focused window alone proves nothing: an inactive app reports its main window
    /// there while it has no key window. A sheet open on `window` counts as `window`: it takes the
    /// keys while it is up. Also returns the focused window's id, nil when unknown.
    static func keyWindowState(
        _ window: ComputerUseWindow, isCancelled: @escaping IsCancelled
    ) async throws -> (isKey: Bool, focusedWindowID: UInt32?) {
        try await onQueue(isCancelled) {
            let app = window.app
            let application = try ComputerUseAXReader.target(app.pid)
            let focused = elementAttribute(application, kAXFocusedWindowAttribute).map(owningWindow(of:))
            let focusedID = focused.flatMap(ComputerUseSkyLight.windowID(of:))
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete || result == .apiDisabled, let error = mapped(result, app: app) { throw error }
            guard bool(of: application, kAXFrontmostAttribute) == true, let focused else { return (false, focusedID) }
            // Two windows can share a frame and title (a duplicated document); the window id can't.
            if ComputerUseSkyLight.canIdentifyWindows { return (focusedID == window.windowID, focusedID) }
            guard let axWindows = windowsRef as? [AXUIElement],
                  let target = axWindow(axWindows, for: window)
            else { return (false, focusedID) }
            return (CFEqual(focused, target), focusedID)
        }
    }

    /// The AX window behind `window`: by its CG window id where AX can name it, else by frame,
    /// with the title breaking ties.
    private static func axWindow(_ candidates: [AXUIElement], for window: ComputerUseWindow) -> AXUIElement? {
        ComputerUseAXReader.axWindow(candidates, for: window, frame: frame(of:), title: { string(of: $0, kAXTitleAttribute) })
    }

    /// Whether the app's focused window is `target`, the AX window of `window`: by window id where
    /// AX can name it, else by element equality.
    private static func isFocusedWindow(_ target: AXUIElement, _ window: ComputerUseWindow, of application: AXUIElement) -> Bool {
        guard let focused = elementAttribute(application, kAXFocusedWindowAttribute).map(owningWindow(of:)) else { return false }
        if ComputerUseSkyLight.canIdentifyWindows { return ComputerUseSkyLight.windowID(of: focused) == window.windowID }
        return CFEqual(focused, target)
    }

    /// The window a focused sheet is attached to, else the focused window itself.
    private static func owningWindow(of focused: AXUIElement) -> AXUIElement {
        guard string(of: focused, kAXRoleAttribute) == kAXSheetRole,
              let parent = elementAttribute(focused, kAXParentAttribute),
              string(of: parent, kAXRoleAttribute) == kAXWindowRole
        else { return focused }
        return parent
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
        interrupt: @escaping Interrupt
    ) async throws {
        try await onQueue(interrupt: interrupt) {
            let element = try resolve(handles, handle)
            let result = AXUIElementPerformAction(element, action as CFString)
            guard result == .success else {
                if result == .cannotComplete { throw Unconfirmed() }
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
    /// `onQueue` for a call that changes the app: refused on the queue when the user is working in it.
    private static func onQueue<T: Sendable>(
        interrupt: @escaping Interrupt, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await onQueue({ interrupt() == .cancelled }) {
            if interrupt() == .userActive { throw ComputerUseSystemError.userActive }
            return try body()
        }
    }

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
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, ComputerUseAXReader.mayMessage(pid) else {
            throw ComputerUseAXReader.hostRefusal
        }
        AXUIElementSetMessagingTimeout(element, ComputerUseAXReader.messagingTimeout)
        return element
    }

    private static let secureRefusal = ComputerUseSystemError.actionFailed("Secure text fields can't be typed into.")

    /// Read live rather than trusting the cached node: the element may have changed.
    private static func refuseSecure(_ element: AXUIElement, app: ComputerUseAppIdentity) throws {
        var identity: [String?] = []
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if let error = mapped(result, app: app) { throw error }
            identity.append(result == .success ? value as? String : nil)
        }
        if ComputerUseSecureFocus.isSecure(.init(role: identity[0], subrole: identity[1])) { throw secureRefusal }
    }

    /// Some apps expose a password field as the role rather than the subrole.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        ComputerUseSecureFocus.isSecure(.init(role: string(of: element, kAXRoleAttribute), subrole: string(of: element, kAXSubroleAttribute)))
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
    /// Values longer than this aren't read back to check an insert; the length check stands in.
    static let valueCheckCharacters = 200_000
    /// After an AX insert or replace left the value as it was, how often and how long it is read
    /// again before the text counts as not taken: an app may update its value a moment later.
    static let landedPolls = 8
    static let landedPoll: TimeInterval = 0.025

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
            let application = try ComputerUseAXReader.target(app.pid)
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
            let path = target.path.joined(separator: " > ")
            do {
                try press(target.item, app: app)
            } catch var unconfirmed as Unconfirmed {
                unconfirmed.menuItem = path
                throw unconfirmed
            }
            return path
        }
    }

    /// Escape and Return on a window with a sheet or dialog up: presses its cancel or default button
    /// (`ComputerUseDialogButton.resolve`: the sheet's own attribute, else a button by identifier,
    /// title or description) and returns the label it shows. Nil when the chord isn't a bare Escape
    /// or Return, there is no sheet or dialog, or the focused element takes the key itself: a text
    /// area (Return is a new line) or an editable control with a popup, menu or completion list open.
    /// Looks at the window's sheets and child sheets, the app's focused sheet, the window itself as
    /// a dialog, sheets and dialogs the app lists as windows over it, and, for an app hosting its
    /// content remotely or a window off screen, sheets anywhere in its tree. For such a sheet, and
    /// for Return on a panel whose default button can't be read, a key that finds no button fails
    /// rather than going out as events that can't reach it.
    static func pressDialogButton(
        _ chord: ComputerUseKeyChord, in window: ComputerUseWindow,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> String? {
        guard chord.modifiers.isEmpty, case .named(let key) = chord.key else { return nil }
        let attribute: String
        switch key {
        case .escape: attribute = kAXCancelButtonAttribute
        case .return: attribute = kAXDefaultButtonAttribute
        default: return nil
        }
        let app = window.app
        return try await onQueue({ interrupt() == .cancelled }) {
            let application = try ComputerUseAXReader.target(app.pid)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .cannotComplete || result == .apiDisabled, let error = mapped(result, app: app) { throw error }
            guard result == .success, let axWindows = windowsRef as? [AXUIElement],
                  let target = axWindow(axWindows, for: window)
            else { return nil }
            if let focused = focusedElement(of: app), takesKeyItself(focused) { return nil }
            var candidates = elements(of: target, sheetsAttribute)
            candidates += children(of: target).filter { string(of: $0, kAXRoleAttribute) == kAXSheetRole }
            if let focused = elementAttribute(application, kAXFocusedWindowAttribute),
               string(of: focused, kAXRoleAttribute) == kAXSheetRole,
               elementAttribute(focused, kAXParentAttribute).map({ CFEqual($0, target) }) == true {
                candidates.append(focused)
            }
            if let subrole = string(of: target, kAXSubroleAttribute), [kAXDialogSubrole, kAXSystemDialogSubrole].contains(subrole) {
                candidates.append(target)
            }
            // A sheet some apps list as a window of their own, over the window it belongs to: one
            // whose parent is the window, or, when its parent names no window, one over no other.
            if candidates.isEmpty, let targetFrame = frame(of: target) {
                func isDialog(_ element: AXUIElement) -> Bool {
                    string(of: element, kAXRoleAttribute) == kAXSheetRole
                        || [kAXDialogSubrole, kAXSystemDialogSubrole].contains(string(of: element, kAXSubroleAttribute) ?? "")
                }
                let others = axWindows.filter { !CFEqual($0, target) && isMessageable($0) }
                for other in others where isDialog(other) {
                    guard let otherFrame = frame(of: other), otherFrame.intersects(targetFrame) else { continue }
                    let parent = elementAttribute(other, kAXParentAttribute)
                    if parent.map({ !CFEqual($0, target) }) ?? true {
                        // Another document's dialog.
                        if let parent, string(of: parent, kAXRoleAttribute) == kAXWindowRole { continue }
                        // Over another document too: whose it is can't be told.
                        let overOther = others.contains { window in
                            !CFEqual(window, other) && !isDialog(window) && frame(of: window)?.intersects(otherFrame) == true
                        }
                        if overOther { continue }
                    }
                    candidates.append(other)
                }
            }
            // A sheet a pane hosted in another process opens (System Settings') sits deeper in the
            // window's tree, among the pane's own elements.
            // Only where a sheet can be that deep: an app hosting its content remotely, or a window
            // off screen, whose sheet can't take posted keys either.
            let displays = ComputerUseAXReader.displayFrames()
            let searchesTree = ComputerUseRemoteContent.hostsContentRemotely(bundleID: app.bundleID)
                || !ComputerUseInputGeometry.frameIsOnScreen(window.frame, displays: displays)
            let remote = candidates.isEmpty && searchesTree ? nestedSheets(in: target) : []
            candidates += remote
            func pressChecked(_ button: AXUIElement, title: String) throws {
                switch interrupt() {
                case .cancelled: throw CancellationError()
                case .userActive: throw ComputerUseSystemError.userActive
                case nil: break
                }
                do {
                    try press(button, app: app)
                } catch var unconfirmed as Unconfirmed {
                    unconfirmed.button = title
                    throw unconfirmed
                }
            }
            // Panels hosted out of process (TextEdit's Save sheet, System Settings' sheets) list the
            // attribute with no value: their buttons are found by identifier or label instead.
            let role: ComputerUseDialogButton.Role = key == .escape ? .cancel : .default
            var unreadable = false
            for candidate in candidates {
                let own = elementAttribute(candidate, attribute)
                if own == nil { unreadable = true }
                let ownInfo = own.map(buttonInfo)
                let buttons = ownInfo?.isEnabled == true ? [] : dialogButtons(in: candidate)
                switch ComputerUseDialogButton.resolve(role, attributeButton: ownInfo, candidates: buttons.map(buttonInfo)) {
                case .attribute(let label):
                    if let own { try pressChecked(own, title: label) }
                    return label
                case .candidate(let index, let label):
                    try pressChecked(buttons[index], title: label)
                    return label
                case .none:
                    continue
                }
            }
            guard !candidates.isEmpty else { return nil }
            // A posted key can't reach a sheet another process draws, or one in a window off screen:
            // saying it was delivered would be wrong. One of the app's own may still take the key.
            if !remote.isEmpty || searchesTree {
                throw ComputerUseSystemError.actionFailed(key == .escape ? noCancelButton : defaultButtonUnreadable)
            }
            // Which button is an unreadable panel's default can't be guessed, and a posted Return
            // doesn't reach it, from a field in it either.
            if unreadable, key == .return { throw ComputerUseSystemError.actionFailed(defaultButtonUnreadable) }
            return nil
        }
    }

    static let noCancelButton =
        "This sheet or dialog has no Cancel button to press for Escape, and a posted key doesn't reach it. Click one of its buttons by ref (computer_inspect lists them)."

    /// How deep, how wide and how long the search of a window's tree for a nested sheet goes.
    static let nestedSheetDepth = 16
    static let nestedSheetNodes = 200
    static let nestedSheetTime: Duration = .seconds(1)

    /// The sheets anywhere in `window`'s tree below its own children, breadth first, within
    /// `nestedSheetDepth` levels, `nestedSheetNodes` elements and `nestedSheetTime`. A sheet's own
    /// contents aren't searched.
    private static func nestedSheets(in window: AXUIElement) -> [AXUIElement] {
        let deadline = ContinuousClock.now + nestedSheetTime
        var level = children(of: window)
        var visited = 0
        var sheets: [AXUIElement] = []
        for _ in 0 ..< nestedSheetDepth {
            var next: [AXUIElement] = []
            for element in level {
                visited += 1
                guard visited <= nestedSheetNodes, ContinuousClock.now < deadline else { return sheets }
                guard isMessageable(element) else { continue }
                if string(of: element, kAXRoleAttribute) == kAXSheetRole {
                    sheets.append(element)
                } else {
                    next += children(of: element)
                }
            }
            guard !next.isEmpty else { break }
            level = next
        }
        return sheets
    }

    static let defaultButtonUnreadable =
        "This dialog's default button can't be pressed with a key here. Click the button by ref (computer_inspect lists the dialog's buttons)."

    /// Levels below a sheet or dialog searched for its buttons, and how many elements.
    static let cancelButtonSearchDepth = 8
    static let cancelButtonSearchNodes = 300

    /// The buttons within `cancelButtonSearchDepth` levels of `dialog`, breadth first, at most
    /// `cancelButtonSearchNodes` elements read, never one of Alas's own.
    private static func dialogButtons(in dialog: AXUIElement) -> [AXUIElement] {
        var level = [dialog]
        var visited = 0
        var buttons: [AXUIElement] = []
        for _ in 0 ..< cancelButtonSearchDepth {
            var next: [AXUIElement] = []
            for element in level {
                for child in children(of: element) {
                    visited += 1
                    guard visited <= cancelButtonSearchNodes else { return buttons }
                    guard isMessageable(child) else { continue }
                    if string(of: child, kAXRoleAttribute) == kAXButtonRole { buttons.append(child) } else { next.append(child) }
                }
            }
            guard !next.isEmpty else { break }
            level = next
        }
        return buttons
    }

    /// A button as `ComputerUseDialogButton.resolve` weighs it.
    private static func buttonInfo(_ button: AXUIElement) -> ComputerUseDialogButton.Candidate {
        .init(title: string(of: button, kAXTitleAttribute), description: string(of: button, kAXDescriptionAttribute),
              identifier: string(of: button, "AXIdentifier"), subrole: string(of: button, kAXSubroleAttribute),
              isEnabled: bool(of: button, kAXEnabledAttribute) != false)
    }

    /// No header constant exists for it.
    private static let sheetsAttribute = "AXSheets"
    private static let expandedAttribute = "AXExpanded"

    /// Whether Escape or Return belongs to the focused element rather than to a dialog button.
    private static func takesKeyItself(_ focused: AXUIElement) -> Bool {
        let role = string(of: focused, kAXRoleAttribute) ?? ""
        if role == kAXTextAreaRole { return true }
        guard [kAXTextFieldRole, kAXComboBoxRole].contains(role) || isSettable(focused, kAXValueAttribute) else { return false }
        if bool(of: focused, expandedAttribute) == true { return true }
        return children(of: focused).contains { child in
            guard [kAXListRole, kAXMenuRole].contains(string(of: child, kAXRoleAttribute) ?? ""),
                  let frame = frame(of: child)
            else { return false }
            return frame.width > 0 && frame.height > 0
        }
    }

    /// An attribute holding a list of elements, with the messaging timeout set on each.
    private static func elements(of element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return [] }
        for element in elements {
            AXUIElementSetMessagingTimeout(element, ComputerUseAXReader.messagingTimeout)
        }
        return elements
    }

    /// Inserts `text` at the element's caret, replacing its selection. Refuses secure text fields.
    /// Focuses the element first, keeping its selection; see `insert` for chunking and interrupts.
    static func insertText(
        _ text: String, _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        let element = try await onQueue(interrupt: interrupt) {
            let element = try resolve(handles, handle)
            try refuseSecure(element, app: app)
            focusKeepingSelection(element, app: app)
            return Retained(element)
        }
        try await insert(text, into: textTarget(element.element), app: app, interrupt: interrupt)
    }

    /// Types into the app's focused element: replaces its value or inserts at its caret.
    /// Refuses secure text fields; `Unsupported` when nothing has focus.
    static func typeIntoFocused(
        _ text: String, replace: Bool, app: ComputerUseAppIdentity,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        let element = try await onQueue(interrupt: interrupt) { () -> Retained? in
            guard let element = focusedElement(of: app) else { throw Unsupported(error: .noValue) }
            try refuseSecure(element, app: app)
            guard replace else { return Retained(element) }
            try setValueChecked(text, element, app: app)
            return nil
        }
        if let element { try await insert(text, into: textTarget(element.element), app: app, interrupt: interrupt) }
    }

    /// An element carried from one block on the AX queue to the next; only messaged there.
    private struct Retained: @unchecked Sendable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
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

    /// The element's own state as an action could change it: value, selection, enabled, title.
    /// Nil when the element is gone. A secure field's value is never read.
    static func stateHash(_ handles: ComputerUseAXHandles, _ handle: Int) async -> Int? {
        try? await onQueue({ false }) {
            // Gone, or this process's: never messaged (P5-R13).
            guard let element = try? resolve(handles, handle) else { return nil }
            var role: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard result != .invalidUIElement, result != .cannotComplete else { return nil }
            var hasher = Hasher()
            if !isSecure(element) {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, let value {
                    hasher.combine((value as? String) ?? (value as? NSNumber)?.stringValue)
                }
            }
            hasher.combine(bool(of: element, kAXSelectedAttribute))
            hasher.combine(bool(of: element, kAXEnabledAttribute))
            hasher.combine(string(of: element, kAXTitleAttribute))
            return hasher.finalize()
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
                let application = try ComputerUseAXReader.target(app.pid)
                guard let hit = hit(at: point, in: window, application: application) else {
                    throw Unsupported(error: .illegalArgument)
                }
                // Another of the app's windows may be on top at that point; an element found from
                // the window is in it.
                if let hitWindow = elementAttribute(hit, kAXWindowAttribute), axWindow([hitWindow], for: window) == nil {
                    throw Unsupported(error: .illegalArgument)
                }
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
        interrupt: @escaping Interrupt
    ) async throws {
        let sidebar = try await onQueue(interrupt: interrupt) { () -> SidebarOpen? in
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
                return nil
            case .selectRow(let index):
                let row = elements[index]
                let sidebar = count == 1 ? sourceListOpen(row, below: elements[..<index], app: app) : nil
                try select(row, app: app)
                guard count == 2 else { return sidebar }
                // Selected but not opened: the double click as events finishes it.
                guard let open = [openAction, kAXPressAction].first(where: links[index].actions.contains) else {
                    throw Unsupported(error: .actionUnsupported)
                }
                try press(row, action: open, app: app)
                return nil
            case .press, .none:
                throw Unsupported(error: .actionUnsupported)
            }
        }
        // The selection may navigate by itself; opening the cell as well would navigate twice.
        guard let sidebar, (try? await Task.sleep(for: sidebarNavigationWait)) != nil else { return }
        _ = try? await onQueue(interrupt: interrupt) {
            guard string(of: sidebar.window.element, kAXTitleAttribute) == sidebar.title else { return }
            _ = try? press(sidebar.cell.element, action: openAction, app: app)
        }
    }

    /// A sidebar cell to open once the row is selected, unless the window navigated by itself.
    private struct SidebarOpen: @unchecked Sendable {
        var cell: Retained
        var window: Retained
        /// The window's title before the selection.
        var title: String?
    }

    /// How long a sidebar selection gets to navigate its window before the cell is opened.
    static let sidebarNavigationWait: Duration = .milliseconds(150)
    private static let finderBundleID = "com.apple.finder"

    /// No header constant exists for it.
    private static let openAction = "AXOpen"
    private static let sourceListSubrole = "AXSourceList"

    /// Finder's sidebar (a source list) navigates on a single click, which selecting the row may
    /// not do: the cell that was clicked, else the row's first cell that opens, with the window's
    /// title before the selection. Read before selecting; nil for any other app or table.
    /// Best effort, since the row is selected either way.
    private static func sourceListOpen(
        _ row: AXUIElement, below chain: ArraySlice<AXUIElement>, app: ComputerUseAppIdentity
    ) -> SidebarOpen? {
        guard app.bundleID == finderBundleID,
              let outline = elementAttribute(row, kAXParentAttribute),
              string(of: outline, kAXRoleAttribute) == kAXOutlineRole,
              string(of: outline, kAXSubroleAttribute) == sourceListSubrole,
              let window = elementAttribute(row, kAXWindowAttribute)
        else { return nil }
        let opens = { (element: AXUIElement) in actionNames(of: element).contains(openAction) }
        // The chain runs from the clicked element up to the row: the last entry is the row's child.
        guard let cell = chain.last.flatMap({ opens($0) ? $0 : nil }) ?? children(of: row).first(where: opens) else { return nil }
        return SidebarOpen(cell: Retained(cell), window: Retained(window), title: string(of: window, kAXTitleAttribute))
    }

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
            if result == .cannotComplete { throw Unconfirmed() }
            throw failure(result, app: app)
        }
    }

    /// Sets the selected text `insertChunkCharacters` characters at a time, checking `interrupt`
    /// between chunks: a stop throws `CancellationError` and a takeover `userTookOver` with the
    /// characters inserted so far. Checks the first chunk went in by reading the value back
    /// (`ComputerUseTextCheck`), or its length where the value can't be read, since some apps
    /// (Chromium) report success and insert nothing; that first failure is `Unsupported`, so events
    /// may type the text instead.
    /// Any later failure is a tool error, so nothing already inserted gets typed twice.
    /// Each chunk goes at the caret the text so far left (from the selection read before the first
    /// one): the user or the app moving the caret in between stops the input rather than splitting
    /// the text across two places. Without a readable selection the chunks go wherever the caret is.
    static func insert(
        _ text: String, into target: TextTarget, app: ComputerUseAppIdentity,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        let total = text.count
        var chunks: [String] = []
        var rest = Substring(text)
        repeat {
            let chunk = String(rest.prefix(insertChunkCharacters))
            rest = rest.dropFirst(chunk.count)
            chunks.append(chunk)
        } while !rest.isEmpty
        var typed = 0
        var typedUTF16 = 0
        var start: Int?
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { await Task.yield() }
            let (typedSoFar, utf16SoFar, startLocation) = (typed, typedUTF16, start)
            start = try await onQueue({ interrupt() == .cancelled }) { () -> Int? in
                let moved = ComputerUseSystemError.actionFailed(
                    "\(app.name) moved the text cursor; stopped after typing \(typedSoFar) of \(total) characters.")
                var startLocation = startLocation
                var countBefore: Int?
                var selection: CFRange?
                var valueBefore: String?
                if typedSoFar == 0 {
                    guard target.canSetSelectedText() else { throw Unsupported(error: .attributeUnsupported) }
                    countBefore = target.characterCount()
                    selection = target.selectedRange()
                    startLocation = selection?.location
                    if (countBefore ?? 0) <= valueCheckCharacters { valueBefore = target.value() }
                } else {
                    switch interrupt() {
                    case .cancelled: throw CancellationError()
                    case .userActive: throw ComputerUseSystemError.userTookOver(typed: typedSoFar, of: total)
                    case nil: break
                    }
                    if let startLocation {
                        let caret = CFRange(location: startLocation + utf16SoFar, length: 0)
                        // The app may have moved the selection since the last chunk's check: stop rather than
                        // put the caret back where the text may no longer belong.
                        guard let live = target.selectedRange(), live.location == caret.location, live.length == 0,
                              target.setSelectedRange(caret)
                        else { throw moved }
                    }
                }
                let result = target.setSelectedText(chunk)
                guard result == .success else {
                    if typedSoFar == 0 { throw failure(result, app: app) }
                    throw ComputerUseSystemError.actionFailed(
                        "\(app.name) stopped taking the text after \(typedSoFar) of \(total) characters (AXError \(result.rawValue)).")
                }
                if typedSoFar == 0, !chunk.isEmpty {
                    let landed = awaitLanded {
                        ComputerUseTextCheck.insert(
                            chunk, before: valueBefore, selection: selection.map { (location: $0.location, length: $0.length) },
                            after: valueBefore == nil ? nil : target.value())
                    }
                    switch landed {
                    case .landed: break
                    case .unchanged: throw Unsupported(error: .attributeUnsupported)
                    case .unknown:
                        // Only with nothing selected does an unchanged length prove nothing went in, so events can't type it twice.
                        if selection?.length == 0, let countBefore, target.characterCount() == countBefore {
                            throw Unsupported(error: .attributeUnsupported)
                        }
                    }
                }
                return startLocation
            }
            typed += chunk.count
            typedUTF16 += chunk.utf16.count
        }
    }

    /// A text check's verdict, read again while it says unchanged, up to `landedPolls` times.
    /// Blocks the AX queue it runs on, only while nothing seems to have gone in.
    private static func awaitLanded(_ check: () -> ComputerUseTextCheck.Verdict) -> ComputerUseTextCheck.Verdict {
        var verdict = check()
        var polls = 0
        while verdict == .unchanged, polls < landedPolls {
            Thread.sleep(forTimeInterval: landedPoll)
            polls += 1
            verdict = check()
        }
        return verdict
    }

    /// The text operations chunked insertion uses on one element. Only called on the AX queue.
    struct TextTarget: @unchecked Sendable {
        var canSetSelectedText: () -> Bool
        var characterCount: () -> Int?
        var selectedRange: () -> CFRange?
        var setSelectedRange: (CFRange) -> Bool
        var setSelectedText: (String) -> AXError
        /// The whole value, empty included; nil when it can't be read.
        var value: () -> String? = { nil }
    }

    private static func textTarget(_ element: AXUIElement) -> TextTarget {
        TextTarget(
            canSetSelectedText: { isSettable(element, kAXSelectedTextAttribute) },
            characterCount: { number(of: element, kAXNumberOfCharactersAttribute) },
            selectedRange: { selectedRange(of: element) },
            setSelectedRange: { range in
                var range = range
                guard let value = AXValueCreate(.cfRange, &range) else { return false }
                return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
            },
            setSelectedText: { AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, $0 as CFString) },
            value: { textValue(of: element) })
    }

    /// The element's value as text, empty included; nil when it isn't a string or can't be read.
    private static func textValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return (value as! String)
    }

    /// Sets the element's whole value and reads it back; `Unsupported` when it stayed as it was,
    /// so events can type the text instead. Call on the AX queue.
    private static func setValueChecked(_ text: String, _ element: AXUIElement, app: ComputerUseAppIdentity) throws {
        let before = isLong(element) ? nil : textValue(of: element)
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        guard result == .success else { throw failure(result, app: app) }
        guard let before else { return }
        let landed = awaitLanded { ComputerUseTextCheck.replace(with: text, before: before, after: textValue(of: element)) }
        if landed == .unchanged { throw Unsupported(error: .attributeUnsupported) }
    }

    private static func isLong(_ element: AXUIElement) -> Bool {
        (number(of: element, kAXNumberOfCharactersAttribute) ?? 0) > valueCheckCharacters
    }

    private static func focusedElement(of app: ComputerUseAppIdentity) -> AXUIElement? {
        guard let application = try? ComputerUseAXReader.target(app.pid) else { return nil }
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
