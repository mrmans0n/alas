import AlasCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import os
import ScreenCaptureKit
import Synchronization

/// An on-screen window of a running app, below the menu bar's layer: a normal window or a panel.
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
    /// `toWindow`: the window the drop end is in, when it isn't the start's; its frame bounds that end.
    /// Always delivered with the app activated.
    case drag(from: ComputerUseInputTarget, to: ComputerUseInputTarget, toWindow: ComputerUseWindow?)
    /// A left click as pointer events at the target, skipping the AX ways: the retry of an AX press
    /// that changed nothing in an app whose AX press only focuses (Electron).
    case pointerClick(ComputerUseInputTarget)

    /// The element a click by ref targets, which must show for the click to go ahead. Typing by
    /// ref may target a field out of view, and scrolling is how one gets there.
    var refusedWhenHidden: (ComputerUseAXHandles, Int)? {
        if case .click(.element(let handles, let handle), _, _) = self { return (handles, handle) }
        return nil
    }

    var isDrag: Bool {
        if case .drag = self { return true }
        return false
    }
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
    /// The title of the sheet or dialog button an Escape or Return pressed.
    var button: String?
    /// Said next to the result: the app didn't confirm an AX press in time.
    var warning: String?
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
    /// On screen, but no AX window of its app answers for it (a sheet's backing window).
    case windowUnreadable(UInt32)
    case captureFailed(String)
    /// The app didn't answer an Accessibility read in time (kAXErrorCannotComplete, a stalled read).
    case appNotResponding(String)
    /// The element a handle points at no longer exists.
    case staleElement
    case actionFailed(String)
    /// The target window isn't its app's key window, so keys could go to another window.
    case notActiveWindow(String)
    case openFailed(String)
    /// The point the input would land on is outside the target window.
    case outOfBounds
    /// A drag's drop element is gone.
    case staleDropElement
    /// A drag's drop point is outside the window it drops into.
    case dropOutOfBounds
    /// The user took over between the input's events.
    case userActive
    /// The user took over while text was being typed.
    case userTookOver(typed: Int, of: Int)
    /// The user took over after a drag's button went down; it was cancelled in place.
    case userTookOverDrag

    /// The user's input stopped the input.
    var isUserTakeover: Bool {
        switch self {
        case .userActive, .userTookOver, .userTookOverDrag: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .windowNotFound(let id): "Window \(id) is no longer on screen"
        case .windowUnreadable(let id): "Window \(id) can't be read"
        case .captureFailed(let reason): "Capture failed: \(reason)"
        case .appNotResponding(let app): "Capture failed: \(app) is not responding"
        case .staleElement, .staleDropElement: "The element is no longer valid"
        case .outOfBounds, .dropOutOfBounds: "The point is outside the window"
        case .userActive: "The user is using the app"
        case .userTookOver(let typed, let total): "The user took over after \(typed) of \(total) characters"
        case .userTookOverDrag: "The user took over during the drag"
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
    /// `cut` says why the read stopped early (node budget, time limit, stalled app); nil when
    /// it read everything. `handles` retains the elements behind each node's `handle`.
    var axTree: @Sendable (ComputerUseWindow, _ maxDepth: Int, _ nodeBudget: Int, _ timeLimit: Duration) async throws
        -> (root: ComputerUseAXNode, cut: ComputerUseReadCut?, handles: ComputerUseAXHandles)
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
    /// Whether a handle from one read and a handle from another retain the same AX element.
    var sameElement: @Sendable (ComputerUseAXHandles, Int, ComputerUseAXHandles, Int) -> Bool = { old, oldHandle, new, newHandle in
        guard let before = old.element(oldHandle), let after = new.element(newHandle) else { return false }
        return CFEqual(before, after)
    }
    /// Seconds since the last hardware input; events Alas posts don't count.
    var secondsSinceUserInput: @Sendable () -> TimeInterval
    /// Whether the app is the user's front app, as WindowServer has it.
    var isFrontmost: @Sendable (Int32) -> Bool
    /// Identity without launching: running app (real pid) or installed app (pid 0); nil when not found.
    var resolveApp: @Sendable (_ name: String?, _ bundleID: String?) async -> ComputerUseAppIdentity?
    /// Launches, or unhides and reopens, without activating; returns the running identity.
    var openApp: @Sendable (ComputerUseAppIdentity) async throws -> ComputerUseAppIdentity
    /// Undoes a `keyedInBackground` input once it settled: the app stops treating the window as
    /// its active key window, unless the user brought the app to the front meanwhile.
    var releaseBackgroundFocus: @Sendable (ComputerUseWindow) async -> Void = { _ in }
    /// Whether the app builds its Accessibility tree on request (Chromium, Electron), where an AX
    /// press may only focus the element.
    var usesManualAccessibility: @Sendable (Int32) -> Bool = { _ in false }
    /// The apps among `pids` a system password prompt is showing in, or may be showing in without
    /// the probe budget having reached them (`ComputerUseCredentialPrompt.listing`), read with one
    /// window list and one process list, within one probe budget. Clear apps have no entry.
    var credentialPrompts: @Sendable (_ pids: [Int32]) async -> [Int32: ComputerUseCredentialPrompt.Listing] = { _ in [:] }
    /// Running menu-bar (accessory) apps, which `runningApps` leaves out.
    var accessoryApps: @Sendable () async -> [ComputerUseAppIdentity] = { [] }
    /// Asks a Chromium or Electron app to build its web content's Accessibility tree by turning
    /// an attribute on; true when Alas turned it on, so `restoreWebContent` turns it off again.
    var wakeWebContent: @Sendable (ComputerUseAppIdentity, _ attribute: String) async -> Bool = { _, _ in false }
    var restoreWebContent: @Sendable (ComputerUseAppIdentity, _ attribute: String) async -> Void = { _, _ in }
    /// When the process started, so a pid the system handed to a new process tells apart from the
    /// old one; nil when it can't be read.
    var processStart: @Sendable (Int32) -> TimeInterval? = { _ in nil }
    /// The online displays' frames, CG global, top-left (`ComputerUseAXReader.displayFrames`).
    var displays: @Sendable () -> [CGRect] = { [.infinite] }
    /// The frames of the AXSheets in each app's windows, read for the apps among `pids`, so the
    /// windows backing them stay out of listings (`ComputerUseInputGeometry.isSheetBacking`).
    var sheetFrames: @Sendable (_ pids: [Int32]) async -> [Int32: [CGRect]] = { _ in [:] }

    /// Whether a system password prompt is showing in the app, or may be: one app alone is probed
    /// first, so an unchecked one is the probe not getting to it, and counts as showing.
    func credentialPrompt(_ pid: Int32) async -> Bool {
        await credentialPrompts([pid])[pid] != nil
    }
    /// The live system. `cursorWindowIDs` names Alas's own overlay windows (the drawn cursor),
    /// which the live drag's hit-tests look through.
    static func live(cursorWindowIDs: @escaping @Sendable () -> Set<UInt32> = { [] }) -> ComputerUseSystem {
        ComputerUseSystem(
            runningApps: { await LiveComputerUseSystem.runningApps() },
            window: { await LiveComputerUseSystem.window($0) },
            screenshot: { try await LiveComputerUseSystem.screenshot($0) },
            axTree: { window, maxDepth, nodeBudget, timeLimit in
                try await ComputerUseAXReader.read(window, maxDepth: maxDepth, nodeBudget: nodeBudget, timeLimit: timeLimit)
            },
            perform: { input, window, direct, interrupt in
                try await LiveComputerUseSystem.perform(
                    input, in: window, direct: direct, ignoring: cursorWindowIDs, interrupt: interrupt)
            },
            focusState: { await ComputerUseAXActions.focusState(of: $0.app) },
            elementState: { await ComputerUseAXActions.stateHash($0, $1) },
            elementMatches: { handles, handle, role, title in
                await ComputerUseAXActions.elementMatches(handles, handle, role: role, title: title)
            },
            secondsSinceUserInput: { LiveComputerUseSystem.secondsSinceUserInput() },
            // Synchronous and called off the main actor between an input's events, so without
            // SkyLight it reads `isActive` directly rather than hopping to the main actor.
            isFrontmost: { ComputerUseSkyLight.isFrontProcess(pid: $0) ?? NSRunningApplication(processIdentifier: $0)?.isActive ?? false },
            resolveApp: { await LiveComputerUseSystem.resolveApp(name: $0, bundleID: $1) },
            openApp: { try await LiveComputerUseSystem.openApp($0) },
            releaseBackgroundFocus: { await LiveComputerUseSystem.releaseBackgroundFocus($0) },
            usesManualAccessibility: { ComputerUseAXReader.acceptsManualAccessibility($0) },
            credentialPrompts: { await LiveComputerUseSystem.credentialPrompts(pids: $0) },
            accessoryApps: { await LiveComputerUseSystem.accessoryApps() },
            wakeWebContent: { await ComputerUseAXReader.wakeWebContent($0, attribute: $1) },
            restoreWebContent: { await ComputerUseAXReader.restoreWebContent($0, attribute: $1) },
            processStart: { LiveComputerUseSystem.processStart($0) },
            displays: { LiveComputerUseSystem.displayFrames() },
            sheetFrames: { await ComputerUseAXReader.sheetFrames(pids: $0) }
        )
    }
}

private enum LiveComputerUseSystem {
    /// Same cap as preview_capture.
    static let maxPNGBytes = 8 * 1024 * 1024

    /// The kernel's start time of the process, in seconds since 1970.
    static func processStart(_ pid: Int32) -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }

    private struct CGWindowEntry {
        var id: UInt32
        var pid: Int32
        var ownerName: String?
        var title: String?
        var frame: CGRect
        var layer: Int
        var alpha: Double
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

    static func accessoryApps() async -> [ComputerUseAppIdentity] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .accessory && !$0.isTerminated }
                .map(identity(of:))
        }
    }

    /// From the input tap; the HID idle time, which counts Alas's own events, only until it runs.
    /// While Secure Event Input is on the tap gets no keys, so the HID idle time for keys counts too.
    static func secondsSinceUserInput() -> TimeInterval {
        ComputerUseTakeover.userIdleSeconds(
            now: ComputerUseUserInput.now(), lastUserInput: ComputerUseUserInput.lastInput(),
            hidIdle: ComputerUseUserInput.hidIdleSeconds(),
            secureInputKeyIdle: IsSecureEventInputEnabled() ? ComputerUseUserInput.hidKeyIdleSeconds() : nil)
    }

    /// How long one call may spend reading sheets over all its apps; past it the rest are
    /// unchecked (`ComputerUseCredentialPrompt.listing`).
    static let promptProbeBudget: Duration = .milliseconds(600)

    /// Nothing is read unless a prompt process runs; then only apps with an untitled window, the
    /// user's front app first, since the prompt is usually in the app they just used.
    static func credentialPrompts(pids: [Int32]) async -> [Int32: ComputerUseCredentialPrompt.Listing] {
        let (running, frontPID) = await MainActor.run {
            (Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier)),
             NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        guard ComputerUseCredentialPrompt.needsSheetRead(runningBundleIDs: running, hasUntitledWindow: true) else { return [:] }
        let untitled = Set(onScreenWindows().filter { $0.title == nil }.map(\.pid))
        let withUntitled = pids.filter(untitled.contains)
        let candidates = withUntitled.filter { $0 == frontPID } + withUntitled.filter { $0 != frontPID }
        let deadline = ContinuousClock.now + promptProbeBudget
        var listings: [Int32: ComputerUseCredentialPrompt.Listing] = [:]
        for pid in candidates {
            let probed = ContinuousClock.now < deadline
            let secure = probed ? await ComputerUseAXReader.secureFieldInSheet(pid: pid, deadline: deadline) : nil
            let listing = ComputerUseCredentialPrompt.listing(
                runningBundleIDs: running, hasUntitledWindow: true, probed: probed, secureFieldInSheet: secure)
            if listing != .clear { listings[pid] = listing }
        }
        return listings
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

    /// The windows apps are driven in: normal ones, and their floating and modal panels below the
    /// menu bar (an open panel sits at layer 8).
    private static func onScreenWindows() -> [CGWindowEntry] {
        allOnScreenWindows().filter { ComputerUseInputGeometry.isAppWindowLayer($0.layer) }
    }

    /// Every on-screen window at every layer, front to back, as a system-wide press or drop is
    /// hit-tested: floating panels, notification banners and the Dock sit above layer 0.
    private static func screenWindows() -> [ComputerUseInputGeometry.ScreenWindow] {
        allOnScreenWindows().map {
            ComputerUseInputGeometry.ScreenWindow(id: $0.id, pid: $0.pid, layer: $0.layer, alpha: $0.alpha, frame: $0.frame)
        }
    }

    private static func allOnScreenWindows() -> [CGWindowEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
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
                frame: frame,
                layer: layer,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
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
    /// After raising a drag's windows, before checking nothing covers its points.
    static let dragRaiseSettle: Duration = .milliseconds(150)
    /// Between looks while a drag's windows come up (`ComputerUseTakeover.dragSettleWait`).
    static let dragRaisePoll: Duration = .milliseconds(50)
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
    /// `ignoring`: windows the drag's hit-tests look through (Alas's drawn cursor).
    /// An AX press the app didn't answer in time counts as delivered, with a warning.
    static func perform(
        _ input: ComputerUseInput, in window: ComputerUseWindow, direct: Bool,
        ignoring: @escaping @Sendable () -> Set<UInt32>,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered {
        do {
            return try await deliver(input, in: window, direct: direct, ignoring: ignoring, interrupt: interrupt)
        } catch let unconfirmed as ComputerUseAXActions.Unconfirmed {
            return ComputerUseDelivered(
                delivery: .ax, menuItem: unconfirmed.menuItem, button: unconfirmed.button,
                warning: ComputerUseAXActions.unconfirmedWarning)
        }
    }

    private static func deliver(
        _ input: ComputerUseInput, in window: ComputerUseWindow, direct: Bool,
        ignoring: @escaping @Sendable () -> Set<UInt32>,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        if isCancelled() { throw CancellationError() }
        // The coordinator refuses these first; no delivery path may quit an app either way.
        if case .key(let chord) = input, ComputerUseMenuShortcut.isQuit(chord) {
            throw ComputerUseSystemError.actionFailed(ComputerUseCoordinator.Message.noQuitting)
        }
        if case .key(let chord) = input {
            try await ComputerUseAXActions.refuseSecureFocus(chord, in: window, isCancelled: isCancelled)
        }
        // A sheet or dialog takes Escape and Return as its cancel and default buttons; pressing the
        // button needs no key window, so nothing is keyed or activated for it, also when direct.
        if case .key(let chord) = input,
           let button = try await ComputerUseAXActions.pressDialogButton(chord, in: window, interrupt: interrupt) {
            return ComputerUseDelivered(delivery: .ax, button: button)
        }
        // Keys and text posted to a window off screen reach nothing: only AX can stand in.
        if let delivered = try await offScreenViaAX(input, in: window, interrupt: interrupt) { return delivered }
        // Content another process draws in the window (a System Settings pane) takes no posted
        // events: an x/y click or scroll there goes as AX on the element at the point, also when
        // direct. Where AX has no way, the events go as they always did.
        if let routed = try await routedToPoint(input, in: window, isCancelled: isCancelled) {
            if let delivered = try await remoteViaAX(routed.input, in: window, interrupt: interrupt) { return delivered }
            // Events at a point off screen reach nothing: reporting them delivered would be wrong.
            if routed.offScreen { throw ComputerUseSystemError.actionFailed(offScreenRefusal(window.app)) }
        }
        // Drags always go with the app in front; the coordinator applies the direct takeover rule to them.
        if direct || input.isDrag {
            // Raising the window moves the app's key window too; not while another input holds it.
            return try await keyLocks.run(window.app.pid) {
                try await activated(input, in: window, ignoring: ignoring, interrupt: interrupt)
            }
        }
        let app = window.app
        // An AX press needs no position, so it would reach an element scrolled out of view.
        if let (handles, handle) = input.refusedWhenHidden,
           try await !ComputerUseAXActions.isShown(handles, handle, within: window.frame, isCancelled: isCancelled) {
            throw ComputerUseAXActions.hiddenRefusal
        }
        if let delivered = try await viaAX(input, in: window, interrupt: interrupt) {
            return await documentEdited(delivered, by: input, in: window, keys: .keyFirst, interrupt: interrupt)
        }
        // From making the window key until it is handed back below, no other input may move key
        // status in this app: its events would land in whichever window the other one left key.
        return try await keyLocks.run(app.pid) {
            if isCancelled() { throw CancellationError() }
            var keying = KeyAttempt()
            do {
                try await makeKeyInBackground(window, &keying, interrupt: interrupt)
                var delivered = try await deliverEvents(
                    input, in: window, keyConfirmed: keying.confirmed, ignoring: ignoring, interrupt: interrupt)
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

    /// The AX ways to deliver an input, nil when the element offers none. Typing without a ref and
    /// chords act on the key window, so they wait until it is made key.
    private static func viaAX(
        _ input: ComputerUseInput, in window: ComputerUseWindow,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered? {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        let app = window.app
        // Each case falls through to events only when the element offers no AX way. Typing without
        // a ref and chords act on the key window, so they wait until it is made key below.
        switch input {
        case .click(.element(let handles, let handle), .right, _):
            do {
                try await ComputerUseAXActions.showMenu(handles, handle, app: app, interrupt: interrupt)
                return ComputerUseDelivered.ax
            } catch is ComputerUseAXActions.Unsupported {
                // A right click at its centre may still land.
            }
        case .click(.element(let handles, let handle), .left, let count) where count <= 2:
            if count == 1, try await ComputerUseAXActions.focusTextEntry(handles, handle, app: app, interrupt: interrupt) {
                // A web field may only read as focused in its page: unless the app's focus moved,
                // the click goes as events at the field, as a user's would.
                if try await waitForFocus(handles, handle, app: app, isCancelled: isCancelled) { return ComputerUseDelivered.ax }
                break
            }
            if count == 1 {
                do {
                    try await ComputerUseAXActions.press(handles, handle, app: app, interrupt: interrupt)
                    return ComputerUseDelivered.ax
                } catch is ComputerUseAXActions.Unsupported {
                    // Static text and cells have no press; something around them may.
                }
            }
            do {
                try await ComputerUseAXActions.pressOrSelectNearest(
                    handles, handle, count: count, app: app, interrupt: interrupt)
                return ComputerUseDelivered.ax
            } catch is ComputerUseAXActions.Unsupported {
                // A click at its centre may still land.
            }
        case .type(let text, .element(let handles, let handle), let replace):
            do {
                if replace {
                    try await ComputerUseAXActions.setValue(text, handles, handle, app: app, keysReach: true, interrupt: interrupt)
                } else {
                    try await ComputerUseAXActions.insertText(text, handles, handle, app: app, keysReach: true, interrupt: interrupt)
                }
                return ComputerUseDelivered.ax
            } catch is ComputerUseAXActions.Unsupported {
                // The text isn't settable; focus it and type instead.
            }
        case .scroll(let at, let dx, let dy):
            do {
                try await ComputerUseAXActions.scroll(at, dx: dx, dy: dy, in: window, interrupt: interrupt)
                return ComputerUseDelivered.ax
            } catch is ComputerUseAXActions.Unsupported {
                // No scroll bar to move; a wheel event at the point may still land.
            }
        default:
            break
        }
        return nil
    }

    /// `viaAX` for an input rewritten onto another process's element (`routedToPoint`): nil, so the
    /// original input goes as events, when AX has no way or fails other than by a stop, the
    /// user's return or a press the app didn't confirm (which most likely took effect).
    private static func remoteViaAX(
        _ input: ComputerUseInput, in window: ComputerUseWindow,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered? {
        do {
            return try await viaAX(input, in: window, interrupt: interrupt)
        } catch let error as CancellationError {
            throw error
        } catch let error as ComputerUseAXActions.Unconfirmed {
            throw error
        } catch ComputerUseSystemError.userActive {
            throw ComputerUseSystemError.userActive
        } catch {
            return nil
        }
    }

    static let dragOverlapRefusal = "The two windows overlap at the drag's points; move one so both show."
    static let coveredPointRefusal =
        "Another app's content is at that point; nothing was sent. Use a ref from computer_inspect."

    /// An x/y click or scroll whose point holds content another process draws in the window, as
    /// the same input on the element there (`ComputerUseInputGeometry.pointRoute`); nil for any
    /// other input. Refuses when another process's element at the point isn't in the window.
    /// Point is off every display: the input goes as AX or not at all.
    private struct Routed {
        var input: ComputerUseInput
        var offScreen = false
    }

    /// A key or typed text for an off-screen window, through AX (`ComputerUseInputGeometry.offScreenInput`):
    /// the menu item with the key's shortcut, or the text into the element (by ref) or the focused
    /// one, which must be in this window. Refuses what AX can't take; nil for any other input, or a
    /// window on screen.
    private static func offScreenViaAX(
        _ input: ComputerUseInput, in window: ComputerUseWindow,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered? {
        switch input {
        case .key, .type: break
        default: return nil
        }
        let displays = displayFrames()
        guard !ComputerUseInputGeometry.frameIsOnScreen(window.frame, displays: displays) else { return nil }
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        let app = window.app
        // As the background path does: nothing moves key status in the app meanwhile.
        let (focused, delivered) = try await keyLocks.run(app.pid) { () -> (Bool, ComputerUseDelivered?) in
            var focused = true
            if case .type(_, .element, _) = input {
                // Typing by ref goes to that element, whichever window is focused.
            } else {
                do {
                    try await ComputerUseAXActions.makeActiveWindow(window, raise: false, isCancelled: isCancelled)
                } catch ComputerUseSystemError.notActiveWindow {
                    focused = false
                }
            }
            guard focused else { return (false, nil) }
            switch input {
            case .key(let chord):
                let item = try await ComputerUseAXActions.pressMenuShortcut(chord, app: app, interrupt: interrupt)
                return (true, item.map { ComputerUseDelivered(delivery: .ax, menuItem: $0) })
            case .type(let text, .element(let handles, let handle), let replace):
                do {
                    if replace {
                        try await ComputerUseAXActions.setValue(text, handles, handle, app: app, keysReach: false, interrupt: interrupt)
                    } else {
                        try await ComputerUseAXActions.insertText(
                            text, handles, handle, app: app, keysReach: false, interrupt: interrupt)
                    }
                    return (true, .ax)
                } catch is ComputerUseAXActions.Unsupported {
                    return (true, nil)
                }
            case .type(let text, _, let replace):
                do {
                    // Refuses a secure focused element, as typing does.
                    try await ComputerUseAXActions.typeIntoFocused(
                        text, replace: replace, app: app, keysReach: false, interrupt: interrupt)
                    return (true, .ax)
                } catch is ComputerUseAXActions.Unsupported {
                    return (true, nil)
                }
            default:
                return (true, nil)
            }
        }
        switch ComputerUseInputGeometry.offScreenInput(
            windowOnScreen: false, targetIsFocusedWindow: focused, deliveredThroughAX: delivered != nil) {
        case .ax:
            if let delivered { return await documentEdited(delivered, by: input, in: window, keys: .none, interrupt: interrupt) }
            fallthrough
        case .refuse, .events:
            if case .type = input { throw ComputerUseSystemError.actionFailed(ComputerUseAXActions.offScreenTypeRefusal(app)) }
            throw ComputerUseSystemError.actionFailed(offScreenKeyRefusal(app))
        }
    }

    static func offScreenKeyRefusal(_ app: ComputerUseAppIdentity) -> String {
        "\(app.name)'s window is off screen (it may be on another Space or workspace), so a key only reaches it as a "
            + "sheet button or menu item, and this one is neither. Use element refs, or ask the user to bring the window on screen."
    }

    static func offScreenRefusal(_ app: ComputerUseAppIdentity) -> String {
        "That point of \(app.name)'s window is off screen (it may be on another Space or workspace). Use element refs, "
            + "or ask the user to bring the window on screen."
    }

    static func displayFrames() -> [CGRect] { ComputerUseAXReader.displayFrames() }

    private static func routedToPoint(
        _ input: ComputerUseInput, in window: ComputerUseWindow, isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> Routed? {
        let point: CGPoint
        switch input {
        case .click(.point(let at), _, _), .scroll(.point(let at), _, _): point = at
        default: return nil
        }
        let kind: ComputerUseRemoteContent.Input = if case .scroll = input { .scroll } else { .click }
        // A window parked off screen (an AeroSpace workspace, another Space) takes no events at
        // all, and System Settings' panes none from posted events: the element is found down the
        // window and driven through AX.
        let displays = displayFrames()
        let offScreen = !ComputerUseInputGeometry.pointIsOnScreen(point, displays: displays)
        if offScreen || ComputerUseRemoteContent.hostsContentRemotely(bundleID: window.app.bundleID) {
            if let handles = try await ComputerUseAXActions.remoteContentElement(
                at: point, in: window, for: kind, isCancelled: isCancelled),
               let routed = converted(input, to: .element(handles, 0)) {
                return Routed(input: routed, offScreen: offScreen)
            }
            if offScreen { throw ComputerUseSystemError.actionFailed(offScreenRefusal(window.app)) }
        }
        let found = try await ComputerUseAXActions.element(at: point, in: window, isCancelled: isCancelled)
        switch ComputerUseInputGeometry.pointRoute(point: point, targetPID: window.app.pid, window: window.frame, appHit: found?.hit) {
        case .events: return nil
        case .covered: throw ComputerUseSystemError.actionFailed(coveredPointRefusal)
        case .ax: break
        }
        guard let element = found, let routed = converted(input, to: .element(element.handles, 0)) else { return nil }
        return Routed(input: routed)
    }

    /// The x/y click or scroll `input`, at `target` instead.
    private static func converted(_ input: ComputerUseInput, to target: ComputerUseInputTarget) -> ComputerUseInput? {
        switch input {
        case .click(_, let button, let count): .click(target, button: button, count: count)
        case .scroll(_, let dx, let dy): .scroll(target, dx: dx, dy: dy)
        default: nil
        }
    }

    /// Events, once AX had no way: to the window made key when that was confirmed, else the AX
    /// ways on the focused window, else with the app activated around them.
    private static func deliverEvents(
        _ input: ComputerUseInput, in window: ComputerUseWindow, keyConfirmed: Bool,
        ignoring: @escaping @Sendable () -> Set<UInt32>,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        let app = window.app
        let route = ComputerUseEventRoute.choose(
            skyLightAvailable: ComputerUseSkyLight.isAvailable, keyConfirmed: keyConfirmed,
            idleSeconds: secondsSinceUserInput())
        if route == .background {
            // A key window validates the app's menus, so a chord's menu item is enabled now.
            if let delivered = try await viaKeyWindow(input, app: app, interrupt: interrupt) {
                return await documentEdited(delivered, by: input, in: window, keys: .keyWindow, interrupt: interrupt)
            }
            // Making the window key took a few round trips; the user may have come back since.
            if interrupt() == .userActive { throw ComputerUseSystemError.userActive }
            try await postEvents(input, in: window, paste: false, background: true, ignoring: ignoring, interrupt: interrupt)
            return .background
        }
        // Not key: the AX ways still work where the target already is the app's focused window.
        // Never raised here: an AXRaise can bring the app to the front, with the user still at work.
        if actsOnKeyWindow(input) {
            do {
                try await ComputerUseAXActions.makeActiveWindow(window, raise: false, isCancelled: isCancelled)
                if let delivered = try await viaKeyWindow(input, app: app, interrupt: interrupt) {
                    // The window isn't key through the records, so keys may not reach it.
                    return await documentEdited(delivered, by: input, in: window, keys: .none, interrupt: interrupt)
                }
            } catch ComputerUseSystemError.notActiveWindow {
                // Activation makes it the active window.
            }
        }
        guard route == .activation else { throw ComputerUseSystemError.userActive }
        return try await activated(input, in: window, ignoring: ignoring, interrupt: interrupt)
    }

    /// How the keys of a document's net-zero edit reach the window.
    private enum EditKeys {
        /// They don't: the window is off screen, or not confirmed key.
        case none
        /// The window is key, under the app's key lock.
        case keyWindow
        /// Made key first, under the app's key lock, as events are.
        case keyFirst
    }

    /// After text went in by AX into a document window: a space and a backspace as key events, so
    /// the app marks the document edited (`ComputerUseTextCheck.documentNudge`), or the warning
    /// where they can't go, or moved the text. Never throws: the text is in either way.
    private static func documentEdited(
        _ delivered: ComputerUseDelivered, by input: ComputerUseInput, in window: ComputerUseWindow, keys: EditKeys,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async -> ComputerUseDelivered {
        guard delivered.delivery == .ax, case .type(let text, let at, let replace) = input, !text.isEmpty else { return delivered }
        if case .point = at { return delivered }
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        let app = window.app
        guard let nudge = try? await ComputerUseAXActions.documentNudge(
            after: at, app: app, keysReach: keys != .none, isCancelled: isCancelled), nudge != .none
        else { return delivered }
        var delivered = delivered
        /// The edit, with the window key; true once the text reads as before it.
        let edit: @Sendable () async -> Bool = {
            guard nudge == .keys,
                  let before = try? await ComputerUseAXActions.prepareKeyEdit(
                      after: at, app: app, caretToEnd: replace, isCancelled: isCancelled),
                  interrupt() == nil,
                  (try? ComputerUseInputPoster.postKey(CGKeyCode(kVK_Space), flags: [], pid: app.pid)) != nil,
                  (try? ComputerUseInputPoster.postKey(CGKeyCode(kVK_Delete), flags: [], pid: app.pid)) != nil
            else { return false }
            return (try? await ComputerUseAXActions.awaitFieldText(before, after: at, app: app, isCancelled: isCancelled)) == true
        }
        let marked: Bool
        switch keys {
        case .none: marked = false
        case .keyWindow: marked = await edit()
        case .keyFirst:
            let result = try? await keyLocks.run(app.pid) { () -> (Bool, Bool) in
                var keying = KeyAttempt()
                do {
                    try await makeKeyInBackground(window, &keying, interrupt: interrupt)
                    let marked = keying.confirmed ? await edit() : false
                    await keying.restoreUserKeyWindow(window)
                    return (marked, keying.keyedInBackground)
                } catch {
                    await keying.restoreUserKeyWindow(window)
                    if keying.keyedInBackground { defocusIfInBackground(window) }
                    return (false, false)
                }
            }
            marked = result?.0 ?? false
            delivered.keyedInBackground = delivered.keyedInBackground || result?.1 == true
        }
        if !marked {
            delivered.warning = [delivered.warning, ComputerUseTextCheck.documentNotMarkedWarning]
                .compactMap { $0 }.joined(separator: " ")
        }
        return delivered
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
                try await ComputerUseAXActions.typeIntoFocused(text, replace: replace, app: app, keysReach: true, interrupt: interrupt)
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
        let userFront = await isFrontmost(pid)
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
    /// user brought it to the front, the window may be the one they are working in. Without
    /// SkyLight's front-process call, the app's active state tells.
    private static func defocusIfInBackground(_ window: ComputerUseWindow) {
        let pid = window.app.pid
        let front = ComputerUseSkyLight.isFrontProcess(pid: pid) ?? NSRunningApplication(processIdentifier: pid)?.isActive
        guard front == false else { return }
        _ = ComputerUseSkyLight.defocus(pid: pid, windowID: window.windowID)
    }

    /// Activates the app around the events; one direct action at a time.
    private static func activated(
        _ input: ComputerUseInput, in window: ComputerUseWindow, ignoring: @escaping @Sendable () -> Set<UInt32>,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws -> ComputerUseDelivered {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        try await directLock.run {
            // A Stop while waiting for another direct action performs nothing.
            if isCancelled() { throw CancellationError() }
            // The takeover rule once more, right before the app comes to the front: the wait for an
            // idle user ended before the ref re-check and the lock waits. As the fallback route
            // does, a user who is back now isn't waited out again.
            if secondsSinceUserInput() < ComputerUseTakeover.idleThreshold { throw ComputerUseSystemError.userActive }
            try await withActivation(of: window.app, isCancelled: isCancelled) {
                try await postEvents(input, in: window, paste: true, background: false, ignoring: ignoring, interrupt: interrupt)
            }
        }
        return .activation
    }

    /// Resolves every point first, then checks for cancellation once more
    /// before the first event. `background`: the window was made key without activating its app,
    /// so the focused-window checks only confirm it is still key and never raise it.
    private static func postEvents(
        _ input: ComputerUseInput, in window: ComputerUseWindow, paste: Bool, background: Bool,
        ignoring: @escaping @Sendable () -> Set<UInt32>,
        interrupt: @escaping @Sendable () -> ComputerUseInputInterrupt?
    ) async throws {
        let isCancelled: @Sendable () -> Bool = { interrupt() == .cancelled }
        let app = window.app
        let target = ComputerUseInputPoster.Target(pid: app.pid, windowID: window.windowID, windowOrigin: window.frame.origin)
        func requireActiveWindow() async throws {
            try await ComputerUseAXActions.makeActiveWindow(window, raise: !background, isCancelled: isCancelled)
        }
        // A ref's point is on the part of it its scroll area shows: an element scrolled under
        // another part of the window (a toolbar) would get the input instead.
        func point(_ input: ComputerUseInputTarget, in bounds: ComputerUseWindow = window) async throws -> CGPoint {
            switch input {
            case .element(let handles, let handle):
                guard let visible = try await ComputerUseAXActions.visibleCenter(
                    handles, handle, within: bounds.frame, app: bounds.app, requireOwnCenter: false, isCancelled: isCancelled)
                else { throw ComputerUseAXActions.hiddenRefusal }
                return try onScreen(visible)
            case .point(let point):
                return try onScreen(point)
            }
        }
        /// Events at a point off every display reach nothing: the AX ways were tried before them.
        func onScreen(_ point: CGPoint) throws -> CGPoint {
            let displays = displayFrames()
            guard ComputerUseInputGeometry.pointIsOnScreen(point, displays: displays) else {
                throw ComputerUseSystemError.actionFailed(offScreenRefusal(app))
            }
            return point
        }
        func checkCancelled() throws {
            if isCancelled() { throw CancellationError() }
        }
        switch input {
        case .click(let at, let button, let count):
            let location = try await point(at)
            try checkCancelled()
            try await ComputerUseInputPoster.click(at: location, button: button, count: count, target: target)
        case .pointerClick(let at):
            let location: CGPoint
            switch at {
            case .element(let handles, let handle):
                guard let visible = try await ComputerUseAXActions.visibleCenter(
                    handles, handle, within: window.frame, app: app, requireOwnCenter: true, isCancelled: isCancelled)
                else { throw ComputerUseSystemError.actionFailed("The element is scrolled out of view; it wasn't clicked again.") }
                location = try onScreen(visible)
            case .point(let point):
                location = try onScreen(point)
            }
            try checkCancelled()
            try await ComputerUseInputPoster.click(at: location, button: .left, count: 1, target: target)
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
                try await ComputerUseInputPoster.click(at: try onScreen(location), button: .left, count: 1, target: target)
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
            // A clipboard holding anything but plain text is left alone, and the text typed instead.
            let pasted = paste ? try await self.paste(text, pid: app.pid) : false
            if !pasted {
                try await ComputerUseInputPoster.type(text, pid: app.pid, interrupt: interrupt)
            }
        case .key(let chord):
            try await requireActiveWindow()
            // A printable key, a delete, a control key or any ⌘V can change the focused field's text, like typing does.
            if chord.mayEditText {
                try await ComputerUseAXActions.refuseSecureFocus(app: app, isCancelled: isCancelled)
            }
            try checkCancelled()
            try ComputerUseInputPoster.key(chord, pid: app.pid)
        case .scroll(let at, let dx, let dy):
            let location = try await point(at)
            try checkCancelled()
            try ComputerUseInputPoster.scroll(at: location, dx: dx, dy: dy, target: target)
        case .drag(let from, let to, let toWindow):
            // Only with the app activated, and posted system-wide: a file drag's session follows
            // the cursor. Telling the user's input from these events needs the input tap.
            precondition(!background, "Drags only go with the app activated")
            guard ComputerUseUserInput.isWatching else {
                throw ComputerUseSystemError.actionFailed(
                    "Drags need input watching (Settings > Computer Use > Input watching), so Alas can tell your input from its own.")
            }
            // The app is in front (`activated`). From here on the points are read again on every
            // look: a parked window comes back (AeroSpace switches to its workspace) and windows come
            // up a moment after the activation (`ComputerUseTakeover.dragStep`).
            func current(_ shown: ComputerUseWindow) async -> ComputerUseWindow {
                await self.window(shown.windowID).flatMap { $0.app.pid == shown.app.pid ? $0 : nil } ?? shown
            }
            func moved(_ point: CGPoint, from shown: ComputerUseWindow, to now: ComputerUseWindow) -> CGPoint {
                CGPoint(x: point.x - shown.frame.minX + now.frame.minX, y: point.y - shown.frame.minY + now.frame.minY)
            }
            let sourceShown = window
            let dropShown = toWindow ?? window
            var startWindow = window
            var dropWindow = dropShown
            /// Where an end of the drag is now; nil while its element doesn't show.
            func resolve(
                _ target: ComputerUseInputTarget, shown: ComputerUseWindow, now: ComputerUseWindow, isDrop: Bool
            ) async throws -> CGPoint? {
                switch target {
                case .element(let handles, let handle):
                    do {
                        // A ref's point is on the part of it its scroll area shows: an element scrolled
                        // under another part of the window (a sidebar) would get the press instead.
                        return try await ComputerUseAXActions.visibleCenter(
                            handles, handle, within: now.frame, app: now.app, requireOwnCenter: false, isCancelled: isCancelled)
                    } catch ComputerUseSystemError.staleElement where isDrop {
                        throw ComputerUseSystemError.staleDropElement
                    }
                case .point(let point):
                    let point = moved(point, from: shown, to: now)
                    guard now.frame.contains(point) else {
                        throw isDrop ? ComputerUseSystemError.dropOutOfBounds : ComputerUseSystemError.outOfBounds
                    }
                    return point
                }
            }
            func state(_ point: CGPoint?, own: UInt32, other: UInt32, displays: [CGRect]) -> ComputerUseTakeover.DragPointState {
                guard let point else { return .hidden }
                if !ComputerUseInputGeometry.pointIsOnScreen(point, displays: displays) { return .offScreen }
                let top = ComputerUseInputGeometry.topmostWindow(at: point, in: screenWindows(), ignoring: ignoring())
                if top == own { return .clear }
                return top == other && own != other ? .byOtherDragWindow : .byOther
            }
            func raiseSource() async {
                try? await ComputerUseAXActions.makeActiveWindow(window, raise: true, isCancelled: isCancelled)
            }
            var start = CGPoint.zero
            var end = CGPoint.zero
            /// Looks until the drag may go, raising windows as `dragStep` says.
            /// Bounded by the clock as well as by its sleeps: each look also reads both windows and,
            /// for elements, the app, which a slow app answers late.
            func settle() async throws {
                let began = ContinuousClock.now
                var slept: TimeInterval = 0
                func elapsed() -> TimeInterval {
                    let parts = (ContinuousClock.now - began).components
                    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
                }
                var raisedDrop = false
                while true {
                    try checkCancelled()
                    startWindow = await current(sourceShown)
                    dropWindow = await current(dropShown)
                    let startPoint = try await resolve(from, shown: sourceShown, now: startWindow, isDrop: false)
                    let endPoint = try await resolve(to, shown: dropShown, now: dropWindow, isDrop: true)
                    let displays = displayFrames()
                    let step = ComputerUseTakeover.dragStep(
                        idleSeconds: secondsSinceUserInput(), activated: true,
                        start: state(startPoint, own: startWindow.windowID, other: dropWindow.windowID, displays: displays),
                        drop: state(endPoint, own: dropWindow.windowID, other: startWindow.windowID, displays: displays),
                        raisedDrop: raisedDrop, waited: max(slept, elapsed()))
                    switch step {
                    case .drag, .activate:
                        if let startPoint, let endPoint { (start, end) = (startPoint, endPoint) }
                        return
                    case .userActive: throw ComputerUseSystemError.userActive
                    case .raiseSource:
                        await raiseSource()
                    case .raiseDrop:
                        try await ComputerUseAXActions.raise(dropWindow, isCancelled: isCancelled)
                        raisedDrop = true
                        // The raise takes a moment to show; judging the overlap sooner would refuse early.
                        try? await Task.sleep(for: dragRaiseSettle)
                    case .hidden(.start):
                        throw ComputerUseSystemError.actionFailed("The drag's start element is scrolled out of view or hidden.")
                    case .hidden(.end):
                        throw ComputerUseSystemError.actionFailed("The drop element is scrolled out of view or hidden.")
                    case .offScreen: throw ComputerUseSystemError.actionFailed(offScreenRefusal(app))
                    case .overlap: throw ComputerUseSystemError.actionFailed(dragOverlapRefusal)
                    case .covered(.start):
                        throw ComputerUseSystemError.actionFailed("The drag's start point is covered by another window.")
                    case .covered(.end):
                        throw ComputerUseSystemError.actionFailed("The drop point is covered by another window.")
                    }
                    try? await Task.sleep(for: dragRaisePoll)
                    slept += 0.05
                }
            }
            await raiseSource()
            try? await Task.sleep(for: dragRaiseSettle)
            try await settle()
            try checkCancelled()
            if case .element(let handles, let handle) = from {
                try await ComputerUseAXActions.selectRow(handles, handle, isCancelled: isCancelled)
                // Selecting may scroll the row.
                try await settle()
                try checkCancelled()
            }
            // Another window over the drop point would take the drop: checked right before the release.
            let dropWindowID = dropWindow.windowID
            let pid = app.pid
            let (dragStart, dragEnd) = (start, end)
            let dragBegan = ComputerUseUserInput.now()
            try await ComputerUseInputPoster.systemDrag(from: dragStart, to: dragEnd, dropIsVisible: {
                ComputerUseInputGeometry.topmostWindow(at: dragEnd, in: screenWindows(), ignoring: ignoring()) == dropWindowID
            }, interrupt: {
                if isCancelled() || Task.isCancelled { return .cancelled }
                // The cursor is shared: any input of the user's since the drag began, in any app,
                // input watching stopping, or the target leaving the front ends it.
                // Keys typed under Secure Input never reach the input tap; the HID key time sees them.
                let secureKeyAt = IsSecureEventInputEnabled()
                    ? ComputerUseUserInput.now() - ComputerUseUserInput.hidKeyIdleSeconds() : nil
                if ComputerUseTakeover.tookOverDrag(
                    lastUserInput: ComputerUseUserInput.lastInput(), dragBegan: dragBegan, secureInputKeyAt: secureKeyAt)
                {
                    return .userActive
                }
                let front = ComputerUseSkyLight.isFrontProcess(pid: pid)
                    ?? NSRunningApplication(processIdentifier: pid)?.isActive ?? false
                return front ? interrupt() : .userActive
            })
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
    /// frontmost app to the front, also when `body` throws, unless `app`
    /// no longer is (the user switched apps meanwhile). Throws without
    /// running `body` when the app does not come to the front in time.
    private static func withActivation(
        of app: ComputerUseAppIdentity, isCancelled: @Sendable () -> Bool, _ body: () async throws -> Void
    ) async throws {
        guard await !isFrontmost(app.pid) else {
            try await body()
            return
        }
        // Only to hand the front back afterwards.
        let previousPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        await MainActor.run { _ = NSRunningApplication(processIdentifier: app.pid)?.activate() }
        let deadline = ContinuousClock.now + activationWait
        var frontmost = false
        while true {
            // A cancelled task's sleep returns at once, so the loop would spin until the deadline.
            if isCancelled() || Task.isCancelled {
                await restoreActivation(previousPID, from: app.pid)
                throw CancellationError()
            }
            frontmost = await isFrontmost(app.pid)
            guard !frontmost, ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard frontmost else {
            await restoreActivation(previousPID, from: app.pid)
            switch ComputerUseTakeover.activationFailure(idleSeconds: secondsSinceUserInput()) {
            case .userActive: throw ComputerUseSystemError.userActive
            case .notFrontmost: throw ComputerUseSystemError.actionFailed("\(app.name) could not be brought to the front.")
            }
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

    /// Whether `pid` is WindowServer's front process. `frontmostApplication` follows it only
    /// once its notification reached the main run loop, so it can still name the previous app.
    private static func isFrontmost(_ pid: Int32) async -> Bool {
        if let front = ComputerUseSkyLight.isFrontProcess(pid: pid) { return front }
        return await MainActor.run { NSRunningApplication(processIdentifier: pid)?.isActive ?? false }
    }

    private static func restoreActivation(_ previousPID: Int32?, from pid: Int32) async {
        guard let previousPID else { return }
        // Once the user picked another app, the front is theirs to keep.
        guard await isFrontmost(pid) else { return }
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
    /// Returns false, without touching the pasteboard, unless it is empty or holds one item of plain text.
    private static func paste(_ text: String, pid: Int32) async throws -> Bool {
        let provider = PasteProvider(text: text)
        let snapshot = await MainActor.run { () -> (SavedPasteboard, Int)? in
            let pasteboard = NSPasteboard.general
            guard let saved = savePasteboard(pasteboard) else { return nil }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            // Asks clipboard managers not to record the text.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            pasteboard.writeObjects([item])
            return (saved, pasteboard.changeCount)
        }
        guard let (saved, changeCount) = snapshot else { return false }
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
        return true
    }

    /// Per item, its types with their data in the item's declaration order (richest first), so the
    /// restore keeps the order readers see.
    private typealias SavedPasteboard = [[(type: NSPasteboard.PasteboardType, data: Data)]]

    /// The clipboard's plain text by type, or nil when `ComputerUsePastePolicy` leaves it alone.
    /// Anything but one plain-text item is refused from the type list before any data is read,
    /// and reading stops once the text passes the cap.
    @MainActor
    private static func savePasteboard(_ pasteboard: NSPasteboard) -> SavedPasteboard? {
        let items = pasteboard.pasteboardItems ?? []
        guard ComputerUsePastePolicy.isPlainText(items.map { $0.types.map(\.rawValue) }) else { return nil }
        var saved: SavedPasteboard = []
        var checked: [[ComputerUsePastePolicy.SavedType]] = []
        var total = 0
        reading: for item in items {
            saved.append([])
            checked.append([])
            for type in item.types {
                let data = item.data(forType: type)
                checked[checked.count - 1].append(.init(type: type.rawValue, size: data?.count))
                guard let data else { break reading }
                saved[saved.count - 1].append((type, data))
                total += data.count
                if total > ComputerUsePastePolicy.sizeCap { break reading }
            }
        }
        return ComputerUsePastePolicy.canPaste(checked) ? saved : nil
    }

    /// Skipped when the pasteboard changed after Alas wrote to it: the user copied something.
    @MainActor
    private static func restorePasteboard(_ saved: SavedPasteboard, ifUnchangedSince changeCount: Int) {
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

/// The user's physical input to any app, Alas included, from a listen-only event tap at the HID
/// level. Events Alas posts to a pid never pass through it. The drags Alas posts system-wide do,
/// and carry `postedEventMarker`, which the tap skips; so does every other event Alas posts. The
/// tap runs on its own thread and run loop, never the main thread, and only stores a timestamp. It needs the Accessibility grant, so it is created on the first idle check
/// in a trusted process; until it runs the takeover check falls back to the HID idle time.
enum ComputerUseUserInput {
    /// "ALAS", in every event Alas posts (`kCGEventSourceUserData`).
    static let postedEventMarker: Int64 = 0x414C_4153
    /// Uptime nanoseconds of the last input; 0 before any.
    private static let lastInputNanoseconds = Atomic<UInt64>(0)
    /// The tap is enabled and its run loop runs: the timestamp covers every app.
    private static let live = Atomic<Bool>(false)
    /// A tap thread exists, starting or running.
    private static let started = Atomic<Bool>(false)
    /// Uptime nanoseconds before which no tap is attempted; throttles the trust check and a
    /// failing `tapCreate`, since the idle check runs every few milliseconds during a drag.
    private static let nextAttempt = Atomic<UInt64>(0)
    private static let attemptInterval: UInt64 = 5_000_000_000
    /// Written and read on the tap thread only: before the tap is enabled, and by its callback.
    private nonisolated(unsafe) static var tap: CFMachPort?
    /// macOS's Input Monitoring prompt was asked for once in this process.
    private static let listenAccessRequested = Atomic<Bool>(false)
    private static let log = Logger(subsystem: "io.nlopez.alas", category: "computer-use")

    /// Whether the tap runs, so the takeover check sees the user's input to every app. Asking
    /// also starts it when it can run and isn't yet (throttled).
    static var isWatching: Bool {
        lastInput() != nil
    }

    /// Asks macOS for Input Monitoring, which the tap needs when Accessibility alone doesn't do.
    static func requestListenAccess() {
        _ = CGRequestListenEventAccess()
    }

    private static let monitored: [CGEventType] = [
        .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved, .scrollWheel,
    ]

    /// Uptime seconds of the user's last input; nil until the tap runs.
    static func lastInput() -> TimeInterval? {
        guard live.load(ordering: .acquiring) else {
            startIfTrusted()
            return nil
        }
        return TimeInterval(lastInputNanoseconds.load(ordering: .relaxed)) / 1e9
    }

    /// Starts the tap thread once the process is trusted, at most once per `attemptInterval`.
    private static func startIfTrusted() {
        let now = DispatchTime.now().uptimeNanoseconds
        let next = nextAttempt.load(ordering: .relaxed)
        guard now >= next, !started.load(ordering: .acquiring),
              nextAttempt.compareExchange(expected: next, desired: now + attemptInterval, ordering: .relaxed).exchanged,
              AXIsProcessTrusted(),
              started.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { return }
        let thread = Thread { runTap() }
        thread.name = "Computer use input tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The tap thread's body: returns, and lets the next idle check try again, when the tap
    /// can't be created or its port is invalidated.
    private static func runTap() {
        defer {
            live.store(false, ordering: .releasing)
            nextAttempt.store(DispatchTime.now().uptimeNanoseconds + attemptInterval, ordering: .relaxed)
            started.store(false, ordering: .releasing)
        }
        let mask = monitored.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, _ in
                ComputerUseUserInput.handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil)
        else {
            log.error("Computer use input tap could not be created")
            // Input Monitoring covers the tap where Accessibility doesn't; the next idle checks retry.
            if !CGPreflightListenEventAccess(),
               listenAccessRequested.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                _ = CGRequestListenEventAccess()
            }
            return
        }
        log.info("Computer use input tap created")
        tap = port
        defer { tap = nil }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CGEvent.tapEnable(tap: port, enable: true)
        // Input from just before the tap started counts too.
        let seed = UInt64(max(0, now() - hidIdleSeconds()) * 1e9)
        let current = lastInputNanoseconds.load(ordering: .relaxed)
        lastInputNanoseconds.store(max(current, seed, 1), ordering: .relaxed)
        live.store(true, ordering: .releasing)
        // Runs until the port is invalidated and its source goes away.
        CFRunLoopRun()
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }

    private static func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log.info("Computer use input tap re-enabled after macOS disabled it")
            }
        default:
            guard event.getIntegerValueField(.eventSourceUserData) != postedEventMarker else { return }
            lastInputNanoseconds.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        }
    }

    static func hidIdleSeconds() -> TimeInterval {
        // ~0 is kCGAnyInputEventType, which does not import into Swift.
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Seconds since the last key press, from the HID system: unlike the tap, it sees keys typed
    /// under Secure Event Input.
    static func hidKeyIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    /// Seconds of uptime.
    static func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9
    }
}
