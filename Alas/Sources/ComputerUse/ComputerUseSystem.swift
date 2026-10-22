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
    case ax, event, activation
}

enum ComputerUseSystemError: Error, LocalizedError {
    case windowNotFound(UInt32)
    case captureFailed(String)
    /// The element a handle points at no longer exists.
    case staleElement
    case actionFailed(String)
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
    /// `complete` is false when the read stopped early (node budget, deadline, stalled app).
    /// `handles` retains the elements behind each node's `handle`.
    var axTree: @Sendable (ComputerUseWindow, _ maxDepth: Int, _ nodeBudget: Int) async throws
        -> (root: ComputerUseAXNode, complete: Bool, handles: ComputerUseAXHandles)
    /// Delivers one input. Throws `CancellationError` when `interrupt` reports
    /// `.cancelled` before the first event, or after the event sequence in flight;
    /// `.userActive` stops long sequences (typed text, drags) between their events.
    var perform: @Sendable (
        ComputerUseInput, ComputerUseWindow, _ direct: Bool,
        _ interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivery
    /// Whether the element behind a handle still has the role and title it was read with.
    var elementMatches: @Sendable (ComputerUseAXHandles, Int, _ role: String, _ title: String?) async -> Bool
    /// Seconds since the last hardware input; events Alas posts don't count.
    var secondsSinceUserInput: @Sendable () -> TimeInterval
    var frontmostPID: @Sendable () -> Int32?
    /// Identity without launching: running app (real pid) or installed app (pid 0); nil when not found.
    var resolveApp: @Sendable (_ name: String?, _ bundleID: String?) async -> ComputerUseAppIdentity?
    /// Launches or unhides without activating; returns the running identity.
    var openApp: @Sendable (ComputerUseAppIdentity) async throws -> ComputerUseAppIdentity

    static let live = ComputerUseSystem(
        runningApps: { await LiveComputerUseSystem.runningApps() },
        window: { await LiveComputerUseSystem.window($0) },
        screenshot: { try await LiveComputerUseSystem.screenshot($0) },
        axTree: { window, maxDepth, nodeBudget in
            try await ComputerUseAXReader.read(window, maxDepth: maxDepth, nodeBudget: nodeBudget)
        },
        perform: { input, window, direct, interrupt in
            try await LiveComputerUseSystem.perform(input, in: window, direct: direct, interrupt: interrupt)
        },
        elementMatches: { handles, handle, role, title in
            await ComputerUseAXActions.elementMatches(handles, handle, role: role, title: title)
        },
        secondsSinceUserInput: {
            // ~0 is kCGAnyInputEventType, which does not import into Swift.
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        },
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        resolveApp: { await LiveComputerUseSystem.resolveApp(name: $0, bundleID: $1) },
        openApp: { try await LiveComputerUseSystem.openApp($0) }
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
    /// One direct action at a time: activations and pasteboard swaps must not
    /// interleave, or the pasteboard saved by the second would be the first's text.
    private static let directLock = ComputerUseSerialLock()

    /// Delivery order: an AX action on the element, else events posted to the
    /// pid; `direct` activates the app around the events instead.
    static func perform(
        _ input: ComputerUseInput, in window: ComputerUseWindow, direct: Bool,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivery {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        if isCancelled() { throw CancellationError() }
        if direct {
            try await directLock.run {
                // A Stop while waiting for another direct action performs nothing.
                if isCancelled() { throw CancellationError() }
                try await withActivation(of: window.app, isCancelled: isCancelled) {
                    try await postEvents(input, in: window, paste: true, interrupt: interrupt)
                }
            }
            return .activation
        }
        let app = window.app
        switch input {
        case .click(.element(let handles, let handle), let button, let count) where button == .right || count == 1:
            do {
                if button == .right {
                    try await ComputerUseAXActions.showMenu(handles, handle, app: app, isCancelled: isCancelled)
                } else {
                    try await ComputerUseAXActions.press(handles, handle, app: app, isCancelled: isCancelled)
                }
                return .ax
            } catch is ComputerUseAXActions.Unsupported {
                // Not every element supports the action; a click at its centre may still land.
            }
        case .type(let text, .element(let handles, let handle), replace: true):
            do {
                try await ComputerUseAXActions.setValue(text, handles, handle, app: app, isCancelled: isCancelled)
                return .ax
            } catch is ComputerUseAXActions.Unsupported {
                // The value isn't settable; focus, select all and type it instead.
            }
        default:
            break
        }
        try await postEvents(input, in: window, paste: false, interrupt: interrupt)
        return .event
    }

    /// Resolves every point first, then checks for cancellation once more
    /// before the first event.
    private static func postEvents(
        _ input: ComputerUseInput, in window: ComputerUseWindow, paste: Bool,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        let app = window.app
        let target = ComputerUseInputPoster.Target(pid: app.pid, windowID: window.windowID)
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
                try await ComputerUseAXActions.makeActiveWindow(window, isCancelled: isCancelled)
            case .point(let location):
                try checkCancelled()
                try await ComputerUseInputPoster.click(at: location, button: .left, count: 1, target: target)
                // Let the click move focus before checking what has it.
                try? await Task.sleep(for: focusSettle)
                try await ComputerUseAXActions.makeActiveWindow(window, isCancelled: isCancelled)
                try await ComputerUseAXActions.refuseSecureFocus(app: app, isCancelled: isCancelled)
            case nil:
                try await ComputerUseAXActions.makeActiveWindow(window, isCancelled: isCancelled)
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
            try await ComputerUseAXActions.makeActiveWindow(window, isCancelled: isCancelled)
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
            let start = try await point(from)
            let end = try await point(to)
            try checkCancelled()
            try await ComputerUseInputPoster.drag(from: start, to: end, target: target) { interrupt() == .userActive }
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
        let alreadyRunning = await MainActor.run { () -> ComputerUseAppIdentity? in
            guard app.pid > 0, let existing = NSRunningApplication(processIdentifier: app.pid),
                  !existing.isTerminated
            else { return nil }
            existing.unhide()
            return identity(of: existing)
        }
        if let alreadyRunning {
            running = alreadyRunning
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
