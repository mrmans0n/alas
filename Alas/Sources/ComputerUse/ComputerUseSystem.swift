import AlasCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import ScreenCaptureKit

/// An on-screen, layer-0 window of a running app.
struct ComputerUseWindow: Sendable, Equatable {
    var windowID: UInt32
    var title: String?
    /// Points, global, top-left origin (CG window bounds).
    var frame: CGRect
    var app: ComputerUseAppIdentity
}

struct ComputerUseScreenshot: Sendable {
    var png: Data
    var pixelSize: CGSize
    /// Output pixels per point.
    var scale: CGFloat
}

/// Retained AX elements from one read; index = `ComputerUseAXNode.handle`.
/// Immutable after the read, and the elements are only messaged on the AX queue.
final class ComputerUseAXHandles: @unchecked Sendable {
    private let elements: [AXUIElement]

    init(_ elements: [AXUIElement] = []) {
        self.elements = elements
    }

    func element(_ handle: Int) -> AXUIElement? {
        elements.indices.contains(handle) ? elements[handle] : nil
    }
}

enum ComputerUseInputTarget: Sendable {
    case element(ComputerUseAXHandles, Int)
    /// Global, points, top-left origin.
    case point(CGPoint)
}

enum ComputerUseInput: Sendable {
    case click(ComputerUseInputTarget, button: ComputerUseCommand.Button, count: Int)
    case type(String, target: ComputerUseInputTarget?, replace: Bool)
    case key(ComputerUseKeyChord)
    case scroll(ComputerUseInputTarget, dx: Int, dy: Int)
    case drag(from: ComputerUseInputTarget, to: ComputerUseInputTarget)
}

/// Why an input in flight must stop before its next event.
enum ComputerUseInputInterrupt: Sendable {
    /// A stop, session or turn end, or the call's cancellation.
    case cancelled
    /// The user is using the target app.
    case userActive
}

/// How an input reached the app, reported to the agent.
enum ComputerUseDelivery: String, Sendable {
    /// `background`: events posted to the window after it became its app's key window, without activation.
    case ax, event, activation, background
}

/// A delivered input: how it got there and, for a chord pressed as a menu item, which one.
struct ComputerUseDelivered: Sendable, Equatable {
    var delivery: ComputerUseDelivery
    /// "Menu > Item" in the app's own menu titles.
    var menuItem: String?
    /// The input made the window key in an app that isn't the user's front app; the app keeps
    /// treating it as its active key window until `releaseBackgroundFocus` hands it back.
    var keyedInBackground = false

    static let ax = ComputerUseDelivered(delivery: .ax)
    static let event = ComputerUseDelivered(delivery: .event)
    static let activation = ComputerUseDelivered(delivery: .activation)
    static let background = ComputerUseDelivered(delivery: .background)
}

enum ComputerUseSystemError: Error, LocalizedError {
    case windowNotFound(UInt32)
    case captureFailed(String)
    /// The element a handle points at no longer exists.
    case staleElement
    case actionFailed(String)
    /// The target window isn't its app's key window, so keys could go to another window.
    case notActiveWindow(String)
    case openFailed(String)
    /// The point the input would land on is outside the target window.
    case outOfBounds
    /// The user took over between the input's events.
    case userActive
    /// The user took over while text was being typed.
    case userTookOver(typed: Int, of: Int)

    var errorDescription: String? {
        switch self {
        case .windowNotFound(let id): "Window \(id) is no longer on screen"
        case .captureFailed(let reason): "Capture failed: \(reason)"
        case .staleElement: "The element is no longer valid"
        case .outOfBounds: "The point is outside the window"
        case .userActive: "The user is using the app"
        case .userTookOver(let typed, let total): "The user took over after \(typed) of \(total) characters"
        case .actionFailed(let reason): reason
        case .notActiveWindow(let reason): reason
        case .openFailed(let reason): reason
        }
    }
}

/// The macOS calls behind the computer_apps, computer_screenshot and
/// computer_inspect tools. Closures so the coordinator can be tested with fakes.
struct ComputerUseSystem: Sendable {
    var runningApps: @Sendable () async -> [(app: ComputerUseAppIdentity, windows: [ComputerUseWindow])]
    var window: @Sendable (UInt32) async -> ComputerUseWindow?
    var screenshot: @Sendable (ComputerUseWindow) async throws -> ComputerUseScreenshot
    /// `complete` is false when the read stopped early (node budget, time limit, stalled app).
    /// `handles` retains the elements behind each node's `handle`.
    var axTree: @Sendable (ComputerUseWindow, _ maxDepth: Int, _ nodeBudget: Int, _ timeLimit: Duration) async throws
        -> (root: ComputerUseAXNode, complete: Bool, handles: ComputerUseAXHandles)
    /// Delivers one input. Throws `CancellationError` when `interrupt` reports
    /// `.cancelled` before the first event, or after the event sequence in flight;
    /// `.userActive` stops long sequences (typed text, drags) between their events.
    var perform: @Sendable (
        ComputerUseInput, ComputerUseWindow, _ direct: Bool,
        _ interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered
    /// The target app's focused element, read before and after an input to tell whether it did anything.
    var focusState: @Sendable (ComputerUseWindow) async -> ComputerUseWindowFingerprint.Focus?
    /// A hash of the element's own state (value, selection, enabled, title); nil when it can't be read.
    var elementState: @Sendable (ComputerUseAXHandles, Int) async -> Int?
    /// Whether the element behind a handle still has the role and title it was read with.
    var elementMatches: @Sendable (ComputerUseAXHandles, Int, _ role: String, _ title: String?) async -> Bool
    /// Seconds since the last hardware input; events Alas posts don't count.
    var secondsSinceUserInput: @Sendable () -> TimeInterval
    var frontmostPID: @Sendable () -> Int32?
    /// Identity without launching: running app (real pid) or installed app (pid 0); nil when not found.
    var resolveApp: @Sendable (_ name: String?, _ bundleID: String?) async -> ComputerUseAppIdentity?
    /// Launches, or unhides and reopens, without activating; returns the running identity.
    var openApp: @Sendable (ComputerUseAppIdentity) async throws -> ComputerUseAppIdentity
    /// Undoes a `keyedInBackground` input once it settled: the app stops treating the window as
    /// its active key window, unless the user brought the app to the front meanwhile.
    var releaseBackgroundFocus: @Sendable (ComputerUseWindow) async -> Void = { _ in }

    static let live = ComputerUseSystem(
        runningApps: { await LiveComputerUseSystem.runningApps() },
        window: { await LiveComputerUseSystem.window($0) },
        screenshot: { try await LiveComputerUseSystem.screenshot($0) },
        axTree: { window, maxDepth, nodeBudget, timeLimit in
            try await ComputerUseAXReader.read(window, maxDepth: maxDepth, nodeBudget: nodeBudget, timeLimit: timeLimit)
        },
        perform: { input, window, direct, interrupt in
            try await LiveComputerUseSystem.perform(input, in: window, direct: direct, interrupt: interrupt)
        },
        focusState: { await ComputerUseAXActions.focusState(of: $0.app) },
        elementState: { await ComputerUseAXActions.stateHash($0, $1) },
        elementMatches: { handles, handle, role, title in
            await ComputerUseAXActions.elementMatches(handles, handle, role: role, title: title)
        },
        secondsSinceUserInput: { LiveComputerUseSystem.secondsSinceUserInput() },
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        resolveApp: { await LiveComputerUseSystem.resolveApp(name: $0, bundleID: $1) },
        openApp: { try await LiveComputerUseSystem.openApp($0) },
        releaseBackgroundFocus: { await LiveComputerUseSystem.releaseBackgroundFocus($0) }
    )
}

private enum LiveComputerUseSystem {
    /// Same cap as preview_capture.
    static let maxPNGBytes = 8 * 1024 * 1024

    private struct CGWindowEntry {
        var id: UInt32
        var pid: Int32
        var ownerName: String?
        var title: String?
        var frame: CGRect
    }

    static func runningApps() async -> [(app: ComputerUseAppIdentity, windows: [ComputerUseWindow])] {
        let apps = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(identity(of:))
        }
        var windowsByPID: [Int32: [CGWindowEntry]] = [:]
        // CG window list order is front to back; grouping keeps it.
        for entry in onScreenWindows() {
            windowsByPID[entry.pid, default: []].append(entry)
        }
        return apps
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { app in
                let windows = (windowsByPID[app.pid] ?? []).map {
                    ComputerUseWindow(windowID: $0.id, title: $0.title, frame: $0.frame, app: app)
                }
                return (app: app, windows: windows)
            }
    }

    static func secondsSinceUserInput() -> TimeInterval {
        // ~0 is kCGAnyInputEventType, which does not import into Swift.
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    static func window(_ id: UInt32) async -> ComputerUseWindow? {
        guard let entry = onScreenWindows().first(where: { $0.id == id }) else { return nil }
        let app = await MainActor.run {
            NSRunningApplication(processIdentifier: entry.pid).map(identity(of:))
        } ?? ComputerUseAppIdentity(name: entry.ownerName ?? "pid \(entry.pid)", bundleID: nil, pid: entry.pid)
        return ComputerUseWindow(windowID: entry.id, title: entry.title, frame: entry.frame, app: app)
    }

    static func screenshot(_ window: ComputerUseWindow) async throws -> ComputerUseScreenshot {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ComputerUseSystemError.captureFailed(error.localizedDescription)
        }
        // A recycled id may now belong to another app, which the grant doesn't cover.
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }),
              scWindow.owningApplication?.processID == window.app.pid
        else {
            throw ComputerUseSystemError.windowNotFound(window.windowID)
        }
        let backingScale = await MainActor.run { screenBackingScale(containing: window.frame) }
        let geometry = ComputerUseScreenshotGeometry.output(pointSize: window.frame.size, backingScale: backingScale)

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(geometry.pixelSize.width)
        configuration.height = Int(geometry.pixelSize.height)
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.captureResolution = .best
        // Shadows would pad the image and break the point-to-pixel mapping.
        configuration.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ComputerUseSystemError.captureFailed(error.localizedDescription)
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ComputerUseSystemError.captureFailed("PNG encoding failed")
        }
        guard png.count <= maxPNGBytes else {
            throw ComputerUseSystemError.captureFailed("PNG exceeds 8 MiB")
        }
        // Derived from the delivered image so the pixel-to-point mapping holds
        // even if ScreenCaptureKit does not honor the requested size exactly.
        let scale = window.frame.width > 0 ? CGFloat(image.width) / window.frame.width : geometry.scale
        return ComputerUseScreenshot(
            png: png,
            pixelSize: CGSize(width: image.width, height: image.height),
            scale: scale
        )
    }

    @MainActor
    private static func identity(of app: NSRunningApplication) -> ComputerUseAppIdentity {
        let pid = app.processIdentifier
        return ComputerUseAppIdentity(
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)",
            bundleID: app.bundleIdentifier,
            pid: pid
        )
    }

    /// The scale of the screen holding the window's center. CG bounds are
    /// top-left origin; NSScreen frames are bottom-left, anchored at the
    /// primary screen.
    @MainActor
    private static func screenBackingScale(containing frame: CGRect) -> CGFloat {
        let fallback = NSScreen.main?.backingScaleFactor ?? 2
        let screens = NSScreen.screens
        guard let primary = screens.first else { return fallback }
        let center = CGPoint(x: frame.midX, y: primary.frame.height - frame.midY)
        return screens.first(where: { $0.frame.contains(center) })?.backingScaleFactor ?? fallback
    }

    private static func onScreenWindows() -> [CGWindowEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CGWindowEntry(
                id: number.uint32Value,
                pid: pid.int32Value,
                ownerName: info[kCGWindowOwnerName as String] as? String,
                title: title,
                frame: frame
            )
        }
    }
}

// MARK: - Input

extension LiveComputerUseSystem {
    /// How long a direct delivery waits for the target to come to the front.
    static let activationWait: Duration = .milliseconds(500)
    /// Lets the target handle direct input before the previous app returns to the front.
    static let activationSettle: Duration = .milliseconds(100)
    /// The longest a paste waits for the target to read the text before the pasteboard is restored.
    static let pasteReadWait: Duration = .seconds(2)
    /// The earliest a paste restores the pasteboard after ⌘V, even once the text was read.
    static let pasteRestoreFloor: Duration = .milliseconds(200)
    /// Lets a click move focus before the focused element is checked.
    static let focusSettle: Duration = .milliseconds(50)
    /// How long typing into an element waits for the focus it set to land.
    static let focusWait: Duration = .milliseconds(300)
    static let focusPoll: Duration = .milliseconds(25)
    /// One direct action at a time: activations and pasteboard swaps must not
    /// interleave, or the pasteboard saved by the second would be the first's text.
    private static let directLock = ComputerUseSerialLock()

    /// How long a background delivery waits for the app to report the window as its key window.
    static let keyConfirmWait: Duration = .milliseconds(200)

    /// Delivery order: an AX action on the element; else events posted to the window once it is
    /// its app's key window, without activating the app (`background`); else, when that window
    /// can't be made key, the app is activated around the events as `direct` does.
    static func perform(
        _ input: ComputerUseInput, in window: ComputerUseWindow, direct: Bool,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        if isCancelled() { throw CancellationError() }
        // The coordinator refuses these first; no delivery path may quit an app either way.
        if case .key(let chord) = input, ComputerUseMenuShortcut.isQuit(chord) {
            throw ComputerUseSystemError.actionFailed(ComputerUseCoordinator.Message.noQuitting)
        }
        if direct {
            // Raising the window moves the app's key window too; not while another input holds it.
            return try await keyLocks.run(window.app.pid) { try await activated(input, in: window, interrupt: interrupt) }
        }
        let app = window.app
        // Each case falls through to events only when the element offers no AX way. Typing without
        // a ref and chords act on the key window, so they wait until it is made key below.
        switch input {
        case .click(.element(let handles, let handle), .right, _):
            do {
                try await ComputerUseAXActions.showMenu(handles, handle, app: app, isCancelled: isCancelled)
                return .ax
            } catch is ComputerUseAXActions.Unsupported {
                // A right click at its centre may still land.
            }
        case .click(.element(let handles, let handle), .left, let count) where count <= 2:
            if count == 1 {
                do {
                    try await ComputerUseAXActions.press(handles, handle, app: app, isCancelled: isCancelled)
                    return .ax
                } catch is ComputerUseAXActions.Unsupported {
                    // Static text and cells have no press; something around them may.
                }
            }
            do {
                try await ComputerUseAXActions.pressOrSelectNearest(
                    handles, handle, count: count, app: app, isCancelled: isCancelled)
                return .ax
            } catch is ComputerUseAXActions.Unsupported {
                // A click at its centre may still land.
            }
        case .type(let text, .element(let handles, let handle), let replace):
            do {
                if replace {
                    try await ComputerUseAXActions.setValue(text, handles, handle, app: app, isCancelled: isCancelled)
                } else {
                    try await ComputerUseAXActions.insertText(text, handles, handle, app: app, interrupt: interrupt)
                }
                return .ax
            } catch is ComputerUseAXActions.Unsupported {
                // The text isn't settable; focus it and type instead.
            }
        case .scroll(let at, let dx, let dy):
            do {
                try await ComputerUseAXActions.scroll(at, dx: dx, dy: dy, in: window, interrupt: interrupt)
                return .ax
            } catch is ComputerUseAXActions.Unsupported {
                // No scroll bar to move; a wheel event at the point may still land.
            }
        default:
            break
        }
        // From making the window key until it is handed back below, no other input may move key
        // status in this app: its events would land in whichever window the other one left key.
        return try await keyLocks.run(app.pid) {
            if isCancelled() { throw CancellationError() }
            var keying = KeyAttempt()
            do {
                try await makeKeyInBackground(window, &keying, interrupt: interrupt)
                var delivered = try await deliverEvents(input, in: window, keyConfirmed: keying.confirmed, interrupt: interrupt)
                await keying.restoreUserKeyWindow(window)
                // Also after an activation fallback: the previous app is back in front by then, so
                // the release still finds the target in the background and defocuses it.
                delivered.keyedInBackground = keying.keyedInBackground
                return delivered
            } catch {
                await keying.restoreUserKeyWindow(window)
                // Nothing settles after a failed input; the coordinator never learns the window was keyed.
                if keying.keyedInBackground { defocusIfInBackground(window) }
                throw error
            }
        }
    }

    /// Events, once AX had no way: to the window made key when that was confirmed, else the AX
    /// ways on the focused window, else with the app activated around them.
    private static func deliverEvents(
        _ input: ComputerUseInput, in window: ComputerUseWindow, keyConfirmed: Bool,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        let app = window.app
        let route = ComputerUseEventRoute.choose(
            skyLightAvailable: ComputerUseSkyLight.isAvailable, keyConfirmed: keyConfirmed,
            idleSeconds: secondsSinceUserInput())
        if route == .background {
            // A key window validates the app's menus, so a chord's menu item is enabled now.
            if let delivered = try await viaKeyWindow(input, app: app, interrupt: interrupt) { return delivered }
            // Making the window key took a few round trips; the user may have come back since.
            if interrupt() == .userActive { throw ComputerUseSystemError.userActive }
            try await postEvents(input, in: window, paste: false, background: true, interrupt: interrupt)
            return .background
        }
        // Not key: the AX ways still work where the target is the app's focused window.
        if actsOnKeyWindow(input) {
            do {
                try await ComputerUseAXActions.makeActiveWindow(window, isCancelled: isCancelled)
                if let delivered = try await viaKeyWindow(input, app: app, interrupt: interrupt) { return delivered }
            } catch ComputerUseSystemError.notActiveWindow {
                // Activation makes it the active window.
            }
        }
        guard route == .activation else { throw ComputerUseSystemError.userActive }
        return try await activated(input, in: window, interrupt: interrupt)
    }

    private static func actsOnKeyWindow(_ input: ComputerUseInput) -> Bool {
        switch input {
        case .type(_, nil, _): true
        case .key(let chord): ComputerUseMenuShortcut.applies(to: chord)
        default: false
        }
    }

    /// The AX ways that act on the key window: typing into its focused element, or pressing the
    /// enabled menu item with a chord's shortcut. Nil when the input has none.
    private static func viaKeyWindow(
        _ input: ComputerUseInput, app: ComputerUseAppIdentity,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered? {
        switch input {
        case .type(let text, nil, let replace):
            do {
                try await ComputerUseAXActions.typeIntoFocused(text, replace: replace, app: app, interrupt: interrupt)
                return .ax
            } catch is ComputerUseAXActions.Unsupported {
                // Nothing focused takes text this way; type it instead.
                return nil
            }
        case .key(let chord) where ComputerUseMenuShortcut.applies(to: chord):
            // The press refuses while a secure field has focus: any menu item may paste into it.
            return try await ComputerUseAXActions.pressMenuShortcut(chord, app: app, interrupt: interrupt)
                .map { ComputerUseDelivered(delivery: .ax, menuItem: $0) }
        default:
            return nil
        }
    }

    /// One input at a time per app from making its window key to handing key status back.
    private static let keyLocks = ComputerUseKeyedLocks()

    /// What making a window key changed, so it can be put back.
    private struct KeyAttempt {
        var confirmed = false
        /// Records went to an app that isn't the user's front app.
        var keyedInBackground = false
        /// The user's front app is the target: its key window before the records, to make key again.
        var userKeyWindow: UInt32?

        /// Makes the user's own key window key again in their front app, with the same records and
        /// no defocus. Skipped once another window is key: the user picked it. An unreadable state
        /// still restores, since the agent's window would otherwise keep the user's keys.
        func restoreUserKeyWindow(_ window: ComputerUseWindow) async {
            guard let userKeyWindow else { return }
            // Keys go to whichever window is key when the app handles them; let it handle the
            // input's events before key status moves back, as an activation waits before leaving.
            try? await Task.sleep(for: LiveComputerUseSystem.activationSettle)
            let state = try? await ComputerUseAXActions.keyWindowState(window, isCancelled: { false })
            if let focused = state?.focusedWindowID, focused != window.windowID { return }
            _ = await ComputerUseSkyLight.makeKeyWithoutActivating(pid: window.app.pid, windowID: userKeyWindow, current: nil)
        }
    }

    /// Makes `window` its app's key window without activating the app or raising the window, and
    /// confirms it. The records go out at most twice, since an app may still be handling the first.
    /// Not confirmed without SkyLight or when the app never reports the window as key.
    /// In the user's front app the records move the user's own key window, so they go out only
    /// while the user is idle there, never with a defocus record, and the key window is restored after.
    private static func makeKeyInBackground(
        _ window: ComputerUseWindow, _ attempt: inout KeyAttempt,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        guard ComputerUseSkyLight.isAvailable else { return }
        var state = try await ComputerUseAXActions.keyWindowState(window, isCancelled: isCancelled)
        if state.isKey {
            attempt.confirmed = true
            return
        }
        let pid = window.app.pid
        let userFront = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier } == pid
        if userFront {
            // The takeover rule once more, right before the user's key window moves: the wait for
            // an idle user ended before the change check and the ref re-check.
            if interrupt() == .userActive { throw ComputerUseSystemError.userActive }
            attempt.userKeyWindow = state.focusedWindowID.flatMap { $0 == window.windowID ? nil : $0 }
        }
        for _ in 0 ..< 2 {
            if isCancelled() { throw CancellationError() }
            let current = userFront ? nil : state.focusedWindowID
            let accepted = await ComputerUseSkyLight.makeKeyWithoutActivating(pid: pid, windowID: window.windowID, current: current)
            if !userFront { attempt.keyedInBackground = true }
            guard accepted else { return }
            let deadline = ContinuousClock.now + keyConfirmWait
            while true {
                state = try await ComputerUseAXActions.keyWindowState(window, isCancelled: isCancelled)
                if state.isKey {
                    attempt.confirmed = true
                    return
                }
                guard ContinuousClock.now < deadline else { break }
                try? await Task.sleep(for: focusPoll)
            }
        }
    }

    /// Hands key status back after a settled background input, under the app's key lock.
    static func releaseBackgroundFocus(_ window: ComputerUseWindow) async {
        _ = try? await keyLocks.run(window.app.pid) { defocusIfInBackground(window) }
    }

    /// The defocus record, only while the app is still not WindowServer's front process: once the
    /// user brought it to the front, the window may be the one they are working in.
    private static func defocusIfInBackground(_ window: ComputerUseWindow) {
        guard ComputerUseSkyLight.isFrontProcess(pid: window.app.pid) == false else { return }
        _ = ComputerUseSkyLight.defocus(pid: window.app.pid, windowID: window.windowID)
    }

    /// Activates the app around the events; one direct action at a time.
    private static func activated(
        _ input: ComputerUseInput, in window: ComputerUseWindow,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        try await directLock.run {
            // A Stop while waiting for another direct action performs nothing.
            if isCancelled() { throw CancellationError() }
            try await withActivation(of: window.app, isCancelled: isCancelled) {
                try await postEvents(input, in: window, paste: true, background: false, interrupt: interrupt)
            }
        }
        return .activation
    }

    /// Resolves every point first, then checks for cancellation once more
    /// before the first event. `background`: the window was made key without activating its app,
    /// so the focused-window checks only confirm it is still key and never raise it.
    private static func postEvents(
        _ input: ComputerUseInput, in window: ComputerUseWindow, paste: Bool, background: Bool,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        let app = window.app
        let target = ComputerUseInputPoster.Target(pid: app.pid, windowID: window.windowID, windowOrigin: window.frame.origin)
        func requireActiveWindow() async throws {
            try await ComputerUseAXActions.makeActiveWindow(window, raise: !background, isCancelled: isCancelled)
        }
        func point(_ input: ComputerUseInputTarget) async throws -> CGPoint {
            switch input {
            case .element(let handles, let handle):
                try await ComputerUseAXActions.center(handles, handle, within: window.frame, app: app, isCancelled: isCancelled)
            case .point(let point):
                point
            }
        }
        func checkCancelled() throws {
            if isCancelled() { throw CancellationError() }
        }
        switch input {
        case .click(let at, let button, let count):
            let location = try await point(at)
            try checkCancelled()
            try await ComputerUseInputPoster.click(at: location, button: button, count: count, target: target)
        case .type(let text, let at, let replace):
            switch at {
            case .element(let handles, let handle):
                try await ComputerUseAXActions.focus(handles, handle, app: app, isCancelled: isCancelled)
                try await requireActiveWindow()
                // Text typed before focus lands goes elsewhere or nowhere.
                guard try await waitForFocus(handles, handle, app: app, isCancelled: isCancelled) else {
                    throw ComputerUseSystemError.actionFailed("\(app.name) didn't move focus to the field; nothing was typed.")
                }
                try await ComputerUseAXActions.refuseSecureFocus(app: app, isCancelled: isCancelled)
            case .point(let location):
                try checkCancelled()
                try await ComputerUseInputPoster.click(at: location, button: .left, count: 1, target: target)
                // Let the click move focus before checking what has it.
                try? await Task.sleep(for: focusSettle)
                try await requireActiveWindow()
                try await ComputerUseAXActions.refuseSecureFocus(app: app, isCancelled: isCancelled)
            case nil:
                try await requireActiveWindow()
                try await ComputerUseAXActions.refuseSecureFocus(app: app, isCancelled: isCancelled)
            }
            try checkCancelled()
            if replace {
                try ComputerUseInputPoster.postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand, pid: app.pid)
            }
            if paste {
                try await self.paste(text, pid: app.pid)
            } else {
                try await ComputerUseInputPoster.type(text, pid: app.pid, interrupt: interrupt)
            }
        case .key(let chord):
            try await requireActiveWindow()
            // A printable key or ⌘V puts text into the focused field, like typing does.
            if chord.mayInsertText {
                try await ComputerUseAXActions.refuseSecureFocus(app: app, isCancelled: isCancelled)
            }
            try checkCancelled()
            try ComputerUseInputPoster.key(chord, pid: app.pid)
        case .scroll(let at, let dx, let dy):
            let location = try await point(at)
            try checkCancelled()
            try ComputerUseInputPoster.scroll(at: location, dx: dx, dy: dy, target: target)
        case .drag(let from, let to):
            // With the app activated, the drag starts in its window brought to the front: the
            // down, every dragged step and the up go there, as a user's drag would.
            if !background { try await requireActiveWindow() }
            let start = try await point(from)
            let end = try await point(to)
            try checkCancelled()
            try await ComputerUseInputPoster.drag(from: start, to: end, target: target) { interrupt() == .userActive }
        }
    }

    /// Whether the element behind `handle` has the app's focus within `focusWait`.
    private static func waitForFocus(
        _ handles: ComputerUseAXHandles, _ handle: Int, app: ComputerUseAppIdentity,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + focusWait
        while true {
            if try await ComputerUseAXActions.isFocused(handles, handle, app: app, isCancelled: isCancelled) { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: focusPoll)
        }
    }

    /// Brings `app` to the front for `body`, then returns the previously
    /// frontmost app to the front, also when `body` throws. Throws without
    /// running `body` when the app does not come to the front in time.
    private static func withActivation(
        of app: ComputerUseAppIdentity, isCancelled: @Sendable () -> Bool, _ body: () async throws -> Void
    ) async throws {
        let previousPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard previousPID != app.pid else {
            try await body()
            return
        }
        await MainActor.run { _ = NSRunningApplication(processIdentifier: app.pid)?.activate() }
        let deadline = ContinuousClock.now + activationWait
        var frontmost = false
        while true {
            // A cancelled task's sleep returns at once, so the loop would spin until the deadline.
            if isCancelled() || Task.isCancelled {
                await restoreActivation(previousPID, from: app.pid)
                throw CancellationError()
            }
            frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier } == app.pid
            guard !frontmost, ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard frontmost else {
            await restoreActivation(previousPID, from: app.pid)
            throw ComputerUseSystemError.actionFailed("\(app.name) could not be brought to the front.")
        }
        do {
            try await body()
        } catch {
            await restoreActivation(previousPID, from: app.pid)
            throw error
        }
        try? await Task.sleep(for: activationSettle)
        await restoreActivation(previousPID, from: app.pid)
    }

    private static func restoreActivation(_ previousPID: Int32?, from pid: Int32) async {
        guard let previousPID else { return }
        await MainActor.run {
            guard let previous = NSRunningApplication(processIdentifier: previousPID) else { return }
            // The target is active now; asking on its behalf passes cooperative activation.
            if let current = NSRunningApplication(processIdentifier: pid), previous.activate(from: current) { return }
            _ = previous.activate()
        }
    }

    /// Pastes `text` with ⌘V, then puts the previous pasteboard items back once the
    /// text was read after ⌘V and `pasteRestoreFloor` passed (at most `pasteReadWait`).
    /// A read before ⌘V (a clipboard manager) doesn't count: restoring then would
    /// let the target paste the user's own clipboard.
    private static func paste(_ text: String, pid: Int32) async throws {
        let provider = PasteProvider(text: text)
        let (saved, changeCount) = await MainActor.run { () -> ([[NSPasteboard.PasteboardType: Data]], Int) in
            let pasteboard = NSPasteboard.general
            let saved = (pasteboard.pasteboardItems ?? []).map { item in
                var types: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    types[type] = item.data(forType: type)
                }
                return types
            }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            // Asks clipboard managers not to record the text.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            pasteboard.writeObjects([item])
            return (saved, pasteboard.changeCount)
        }
        provider.keyPosted.set()
        do {
            try ComputerUseInputPoster.postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, pid: pid)
        } catch {
            await MainActor.run { restorePasteboard(saved, ifUnchangedSince: changeCount) }
            throw error
        }
        let posted = ContinuousClock.now
        let floor = posted + pasteRestoreFloor
        let deadline = posted + pasteReadWait
        while ContinuousClock.now < deadline, ContinuousClock.now < floor || !provider.wasRead.isSet {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await MainActor.run { restorePasteboard(saved, ifUnchangedSince: changeCount) }
        withExtendedLifetime(provider) {}
    }

    /// Skipped when the pasteboard changed after Alas wrote to it: the user copied something.
    @MainActor
    private static func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]], ifUnchangedSince changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        let items = saved.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

/// Serves a paste's text when asked, and records a read that came after ⌘V.
private final class PasteProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let text: String
    /// Set right before ⌘V is posted; earlier reads are someone else's.
    let keyPosted = ComputerUseAXReader.CancelFlag()
    let wasRead = ComputerUseAXReader.CancelFlag()

    init(text: String) {
        self.text = text
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        if keyPosted.isSet { wasRead.set() }
    }
}

// MARK: - Apps

extension LiveComputerUseSystem {
    static let openWait: Duration = .seconds(5)

    static func resolveApp(name: String?, bundleID: String?) async -> ComputerUseAppIdentity? {
        await MainActor.run {
            let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
            if let bundleID {
                if let app = running.first(where: { $0.bundleIdentifier == bundleID }) { return identity(of: app) }
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
                return installedIdentity(at: url, bundleID: bundleID)
            }
            guard let name else { return nil }
            let matches = running.filter { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
            if let app = matches.first(where: { $0.activationPolicy == .regular }) ?? matches.first {
                return identity(of: app)
            }
            // Approval is keyed by bundle id; an installed app without one can't be approved.
            guard let url = installedURL(named: name), let bundleID = Bundle(url: url)?.bundleIdentifier else {
                return nil
            }
            return installedIdentity(at: url, bundleID: bundleID)
        }
    }

    static func openApp(_ app: ComputerUseAppIdentity) async throws -> ComputerUseAppIdentity {
        let running: ComputerUseAppIdentity
        let alreadyRunning = await MainActor.run { () -> (app: ComputerUseAppIdentity, url: URL?)? in
            guard app.pid > 0, let existing = NSRunningApplication(processIdentifier: app.pid),
                  !existing.isTerminated
            else { return nil }
            existing.unhide()
            return (identity(of: existing), existing.bundleURL)
        }
        if let alreadyRunning {
            running = alreadyRunning.app
            // Unhiding shows no window when the app has none; the reopen event an open sends
            // makes apps like TextEdit show one (or their open panel).
            if let url = alreadyRunning.url {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                // It is running either way; a refused reopen only means no new window.
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
            }
        } else {
            running = try await launch(app)
        }
        let deadline = ContinuousClock.now + openWait
        while ContinuousClock.now < deadline, !onScreenWindows().contains(where: { $0.pid == running.pid }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        return running
    }

    private static func launch(_ app: ComputerUseAppIdentity) async throws -> ComputerUseAppIdentity {
        let url = await MainActor.run { () -> URL? in
            if let bundleID = app.bundleID,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
            return installedURL(named: app.name)
        }
        guard let url else { throw ComputerUseSystemError.openFailed("\(app.name) is not installed.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            // Only the pid crosses to the main actor; the app object isn't Sendable on every SDK.
            let pid = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
            return await MainActor.run { NSRunningApplication(processIdentifier: pid).map(identity(of:)) }
                ?? ComputerUseAppIdentity(name: app.name, bundleID: app.bundleID, pid: pid)
        } catch {
            throw ComputerUseSystemError.openFailed(error.localizedDescription)
        }
    }

    @MainActor
    private static func installedURL(named name: String) -> URL? {
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        ]
        return directories
            .map { $0.appendingPathComponent("\(name).app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @MainActor
    private static func installedIdentity(at url: URL, bundleID: String) -> ComputerUseAppIdentity {
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return ComputerUseAppIdentity(name: name, bundleID: bundleID, pid: 0)
    }
}

/// A `ComputerUseSerialLock` per key, created on first use and kept: there is one per app pid.
private actor ComputerUseKeyedLocks {
    private var locks: [Int32: ComputerUseSerialLock] = [:]

    private func lock(for key: Int32) -> ComputerUseSerialLock {
        if let lock = locks[key] { return lock }
        let lock = ComputerUseSerialLock()
        locks[key] = lock
        return lock
    }

    func run<T: Sendable>(_ key: Int32, _ body: @Sendable () async throws -> T) async throws -> T {
        try await lock(for: key).run(body)
    }
}

/// Runs async sections one at a time, in arrival order.
private actor ComputerUseSerialLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
