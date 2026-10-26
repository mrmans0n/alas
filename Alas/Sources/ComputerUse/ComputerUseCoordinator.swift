import AlasCore
import CoreGraphics
import Foundation
import Observation
import os

/// An approval card: one per (session, app), shared by every call that waits on it.
struct ComputerUsePendingApproval: Identifiable, Equatable {
    let id: UUID
    let sessionID: String
    let app: ComputerUseAppIdentity
}

/// The drawn agent cursor the coordinator moves before each pointer input; `.none` draws nothing.
struct ComputerUseCursor: Sendable {
    var present: @MainActor @Sendable (ComputerUseWindow) -> Void
    var perform: @MainActor @Sendable (ComputerUseCursorCue) async -> Void
    var dismiss: @MainActor @Sendable () -> Void
    static let none = ComputerUseCursor(present: { _ in }, perform: { _ in }, dismiss: {})
}

/// Serves `computer_*` calls from ACP sessions: readiness, per-app approval,
/// the machine-wide driver lock, and the stop/turn/session lifecycle.
@MainActor
@Observable
final class ComputerUseCoordinator {
    private(set) var pendingApprovals: [ComputerUsePendingApproval] = []
    /// This process's active driver: published once a call holds the lock, so Stop shows
    /// during the first capture; kept by a successful screenshot or inspect.
    private(set) var driver: (sessionID: String, app: ComputerUseAppIdentity)?
    /// Sessions the user stopped; only a resume clears them, not a session end or reconnect.
    private(set) var stoppedSessions: Set<String> = []

    /// Finds a session's transcript, so a pending approval shows as awaiting permission.
    @ObservationIgnored var transcript: (String) -> ACPTranscript? = { _ in nil }

    /// `expired`: the turn ended with the card still up, so no answer can apply to it.
    private enum ApprovalOutcome { case answered, stopped, timedOut, cancelled, expired }

    private struct Waiter {
        var continuation: CheckedContinuation<ApprovalOutcome, Never>
        var timeout: Task<Void, Never>?
    }

    private let system: ComputerUseSystem
    private let access: ComputerUseAccess
    private let readiness: @MainActor () -> ComputerUseReadiness
    private let sessionLabel: @MainActor (String) -> String
    private let persistAlwaysAllowed: @MainActor (String) -> Void
    private let interrupt: @MainActor (String) async -> Void
    private let lockURL: URL
    private let approvalWait: Duration
    /// Takeover polling, the post-action settle and wait polling; tests drive time through it.
    private let sleep: @Sendable (Duration) async -> Void
    private let cursor: ComputerUseCursor
    /// Asks the user to look at Alas (the Dock icon bounces) for a pending approval card, which
    /// shows in its session and may be out of sight (`ComputerUseApprovalNudge`).
    private let attention: @MainActor () -> Void
    private let appIsActive: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    /// When each card still up last asked for attention.
    @ObservationIgnored private var lastNudges: [UUID: Date] = [:]
    /// The session that last presented the cursor; its stop, turn end or session end dismisses it.
    @ObservationIgnored private var cursorSession: String?

    @ObservationIgnored private var lock: ComputerUseDriverLock?
    /// The session the lock was taken for; set before the system call, like `driver`.
    @ObservationIgnored private var lockSession: String?
    /// Calls per session past the lock and inside their system call, so a failing
    /// call never drops the lock under a sibling that is still capturing.
    @ObservationIgnored private var lockedCalls: [String: Int] = [:]
    /// A release asked for while the holder still had calls capturing: it happens when
    /// the last one exits, so nobody else captures while a stopped call still reads the screen.
    @ObservationIgnored private var deferredRelease: ComputerUseDriverLock?
    /// The app of the lock holder's last successful call; a failed call falls back to it.
    @ObservationIgnored private var confirmedApp: ComputerUseAppIdentity?
    @ObservationIgnored private var waiters: [UUID: [UUID: Waiter]] = [:]
    /// Bumped on stop and session end, so an in-flight call notices it was overtaken.
    @ObservationIgnored private var epochs: [String: Int] = [:]
    /// Streaming states replaced by `.awaitingPermission` while a card is up.
    @ObservationIgnored private var priorStreamingStates: [String: ACPSession.StreamingState] = [:]
    /// Calls the MCP bridge tagged with a call id, so its cancellation can stop them.
    @ObservationIgnored private var calls: [CallKey: Task<AlasCLIResponse, Never>] = [:]

    private struct CallKey: Hashable {
        var sessionID: String
        var callID: String
    }

    /// What the agent last saw of a window in a session: element refs and the screenshot geometry.
    @ObservationIgnored private var snapshots: [SnapshotKey: Snapshot] = [:]
    /// Bumped at turn end, stop and session end: refs and screenshots from before count as missing,
    /// and a call still in flight from then can't write them back.
    @ObservationIgnored private var generations: [String: Int] = [:]
    /// Cancellation flags of the inputs being delivered, set by a stop or session end.
    @ObservationIgnored private var inputFlags: [String: [CancelFlag]] = [:]
    /// Windows of background apps an input made key, per session and window id: each is handed
    /// back once its action settled, or at the stop, turn end or session end that cut it short.
    @ObservationIgnored private var backgroundKeyed: [String: [UInt32: ComputerUseWindow]] = [:]
    /// What the first contact of Chromium and Electron processes came to
    /// (`ComputerUseWebContent.FirstContact`). A relaunched app that got its old pid back is
    /// another process.
    @ObservationIgnored private var wokenWebContent: [WokenProcess: ComputerUseWebContent.FirstContact] = [:]
    /// Per session, the apps whose AXEnhancedUserInterface Alas turned on: turned off again at its
    /// stop, turn end or session end.
    @ObservationIgnored private var enhancedUserInterface: [String: [Int32: ComputerUseAppIdentity]] = [:]

    /// A process by pid and start time (`ComputerUseSystem.processStart`), nil when unreadable.
    private struct WokenProcess: Hashable {
        var pid: Int32
        var start: TimeInterval?
    }

    private struct SnapshotKey: Hashable {
        var sessionID: String
        var windowID: UInt32
    }

    private struct Snapshot {
        var generation: Int
        /// A recycled window id belongs to another app; its old refs don't apply.
        var pid: Int32
        var refs: [String: ElementRef] = [:]
        var handles = ComputerUseAXHandles()
        var lastScreenshot: (frame: CGRect, scale: CGFloat)?
    }

    /// An element as read: an action re-checks it before using the handle, since an app may
    /// reuse a row's element for different content.
    private struct ElementRef {
        var handle: Int
        var role: String
        var title: String?
        /// Where the element was when read, relative to its window's origin, so the cursor finds it
        /// after the window moved.
        var localFrame: CGRect
        /// The frame of its nearest scroll area at read time, window-relative too, which clips
        /// where pointer input lands on it.
        var localScrollArea: CGRect?
        /// Listed to the agent at some point: a later read that doesn't list it must still find
        /// the element the agent saw there, not whatever took its place.
        var shown: Bool

        /// The element's frame in global points, with its window where it is now.
        func frame(in window: ComputerUseWindow) -> CGRect {
            localFrame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        }

        /// What shows of the element, as the event route clips it: the window and its scroll area.
        func clips(in window: ComputerUseWindow) -> [CGRect] {
            [window.frame] + [localScrollArea?.offsetBy(dx: window.frame.minX, dy: window.frame.minY)].compactMap { $0 }
        }
    }

    /// The session state a call started in.
    private struct CallContext {
        var sessionID: String
        var epoch: Int
        var generation: Int
    }

    static let resultLimit = 12 * 1024 * 1024

    init(
        system: ComputerUseSystem,
        access: ComputerUseAccess,
        readiness: @escaping @MainActor () -> ComputerUseReadiness,
        sessionLabel: @escaping @MainActor (String) -> String,
        persistAlwaysAllowed: @escaping @MainActor (String) -> Void,
        interrupt: @escaping @MainActor (String) async -> Void,
        lockURL: URL = ComputerUseDriverLock.defaultURL,
        approvalWait: Duration = .seconds(50),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        cursor: ComputerUseCursor = .none,
        attention: @escaping @MainActor () -> Void = {},
        appIsActive: @escaping @MainActor () -> Bool = { false },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.system = system
        self.access = access
        self.readiness = readiness
        self.sessionLabel = sessionLabel
        self.persistAlwaysAllowed = persistAlwaysAllowed
        self.interrupt = interrupt
        self.lockURL = lockURL
        self.approvalWait = approvalWait
        self.sleep = sleep
        self.cursor = cursor
        self.attention = attention
        self.appIsActive = appIsActive
        self.now = now
    }

    /// A launched Chromium or Electron app's first contact (`wakeWebContent`), when its front
    /// window shows no web content yet; true when it waited.
    private func awaitWebContent(afterOpening window: ComputerUseWindow, context: CallContext) async throws -> Bool {
        try await wakeWebContent(window, shown: nil, context: context)
    }

    /// A small read of the window for its web content, as the wait for it looks
    /// (`ComputerUseWebContent.probeDepth`, `probeNodes`); a read cut short counts for what it holds.
    private func probeWebContent(_ window: ComputerUseWindow) async throws -> ComputerUseAXNode {
        try await system.axTree(
            window, ComputerUseWebContent.probeDepth, ComputerUseWebContent.probeNodes, Self.webContentReadLimit).root
    }

    /// A Chromium or Electron app's first contact, when its window (`shown`, as the call read it;
    /// nil to probe it) has no web content and the process is due a try
    /// (`ComputerUseWebContent.needsWake`). A probe that finds content ends it there. Otherwise it
    /// asks for the tree with `AXManualAccessibility`, or, a Chromium browser without that
    /// attribute, with `AXEnhancedUserInterface`, which is turned off again at the turn's end, and
    /// probes every `webContentPoll` until a web area has content, for at most `contentDeadline`,
    /// setting the attribute again halfway and once the content shows, which then gets a moment
    /// to fill in. True when it waited.
    private func wakeWebContent(_ window: ComputerUseWindow, shown: ComputerUseAXNode?, context: CallContext) async throws -> Bool {
        let app = window.app
        let process = WokenProcess(pid: app.pid, start: system.processStart(app.pid))
        func due(_ root: ComputerUseAXNode) -> Bool {
            ComputerUseWebContent.needsWake(
                acceptsManualAccessibility: system.usesManualAccessibility(app.pid), bundleID: app.bundleID,
                wakesAgain: ComputerUseWebContent.wakesAgain(after: wokenWebContent[process], now: now()), root: root)
        }
        if let shown, !due(shown) { return false }
        // The call's own read can stop in the browser's toolbar; the probe looks for the content.
        var root = try await probeWebContent(window)
        guard due(root) else {
            if ComputerUseWebContent.hasWebContent(root) { wokenWebContent[process] = .complete }
            return false
        }
        var attribute = ComputerUseWebContent.manualAccessibility
        let manual = try await setWebContent(attribute, of: app, context: context)
        Self.log.notice("web content wake: pid \(app.pid, privacy: .public) \(app.bundleID ?? "-", privacy: .public) AXManualAccessibility \(String(describing: manual.result), privacy: .public)")
        if manual.result != .set {
            // An app that refused for now (still starting) is asked again at its next read.
            guard ComputerUseWebContent.fallsBackToEnhancedUserInterface(after: manual.result, bundleID: app.bundleID)
            else { return false }
            attribute = ComputerUseWebContent.enhancedUserInterface
            let enhanced = try await setWebContent(attribute, of: app, context: context)
            Self.log.notice("web content wake: pid \(app.pid, privacy: .public) AXEnhancedUserInterface \(String(describing: enhanced.result), privacy: .public) turnedOn \(enhanced.turnedOn, privacy: .public)")
            guard enhanced.result == .set else { return false }
        }
        let clock = ContinuousClock()
        let start = clock.now
        var slept = Duration.zero
        var reasserted = false
        while ComputerUseWebContent.keepsWaiting(root: root, waited: max(slept, clock.now - start)) {
            if ComputerUseWebContent.reasserts(waited: max(slept, clock.now - start), reasserted: reasserted) {
                reasserted = true
                _ = try await setWebContent(attribute, of: app, context: context)
            }
            await sleep(Self.webContentPoll)
            slept += Self.webContentPoll
            try checkStillActive(context)
            root = try await probeWebContent(window)
        }
        let found = ComputerUseWebContent.hasWebContent(root)
        Self.log.notice("web content wait: pid \(app.pid, privacy: .public) content \(found, privacy: .public) after \((clock.now - start).description, privacy: .public)")
        if found {
            // Asked once more as the content shows, and given a moment to fill in.
            _ = try await setWebContent(attribute, of: app, context: context)
            await sleep(ComputerUseWebContent.contentSettle)
            try checkStillActive(context)
            wokenWebContent[process] = .complete
        } else {
            let attempts = if case .timedOut(let attempts, _) = wokenWebContent[process] { attempts } else { 0 }
            wokenWebContent[process] = .timedOut(attempts: attempts + 1, at: now())
        }
        return true
    }

    /// Sets a web content attribute, the first time and every time after: never once the call
    /// was stopped, and an `AXEnhancedUserInterface` Alas turned on is recorded for the turn's
    /// end, or, the call stopped during the set, turned off again at once.
    private func setWebContent(
        _ attribute: String, of app: ComputerUseAppIdentity, context: CallContext
    ) async throws -> ComputerUseWebContent.Wake {
        try checkStillActive(context)
        let wake = await system.wakeWebContent(app, attribute)
        if wake.turnedOn, attribute == ComputerUseWebContent.enhancedUserInterface {
            // A stop, turn end or session end during the set already restored what it found:
            // this one is turned off at once instead of waiting for a lifecycle hook that ran.
            guard (try? checkStillActive(context)) != nil else {
                await system.restoreWebContent(app, attribute)
                try checkStillActive(context)
                throw CancellationError()
            }
            enhancedUserInterface[context.sessionID, default: [:]][app.pid] = app
        }
        try checkStillActive(context)
        return wake
    }

    /// The approval card's reason line: one approval covers seeing and operating the app.
    static func approvalReason(appName: String) -> String {
        "It can see and operate \(appName): read its controls, click, type and press keys."
    }

    // MARK: - Errors

    enum Message {
        static let stopped = "computer_stopped: The user stopped computer use for this session. Ask them to resume it from the session's computer use badge."
        static let cancelled = "computer_cancelled: The call was cancelled."
        static let limit = "computer_limit: The result exceeds the response limit. Inspect with a query or a smaller limit."
        static func blocked(_ app: ComputerUseAppIdentity) -> String { "computer_blocked: \(app.name) can't be used by agents." }
        static func credentialPrompt(_ app: ComputerUseAppIdentity) -> String {
            "computer_blocked: A system password prompt is showing in \(app.name); ask the user to answer it."
        }
        static func credentialPromptAfterInput(_ app: ComputerUseAppIdentity) -> String {
            "The input was delivered, and now a system password prompt is showing in \(app.name), so its elements are "
                + "withheld; ask the user to answer it."
        }
        static func denied(_ app: ComputerUseAppIdentity) -> String { "computer_denied: The user denied access to \(app.name) for this turn." }
        static func approvalPending(_ app: ComputerUseAppIdentity) -> String {
            "computer_approval_pending: Waiting for the user to approve \(app.name). Try again after they answer."
        }
        static func busy(_ label: String) -> String {
            "computer_busy: Another session is using the computer (\(label)). Try again when it finishes."
        }
        static func windowUnreadable(_ id: UInt32) -> String {
            "computer_window_not_found: Window \(id) isn't a window agents can use; it may be a sheet. Inspect its parent "
                + "window, which holds the sheet's elements."
        }
        static func windowNotFound(_ id: UInt32) -> String {
            "computer_window_not_found: No on-screen window \(id). Call computer_apps again."
        }
        static func captureFailed(_ reason: String) -> String { "computer_capture_failed: \(reason)" }
        static func stale(_ ref: String, windowID: UInt32) -> String {
            "computer_stale: The element ref \(ref) is no longer valid. Call computer_inspect on window \(windowID) again."
        }
        static func needsScreenshot(_ windowID: UInt32) -> String {
            "computer_needs_screenshot: x/y are pixels in a screenshot of window \(windowID). Call computer_screenshot first."
        }
        static func outOfBounds(_ windowID: UInt32) -> String { "computer_out_of_bounds: The point is outside window \(windowID)." }
        static func screenshotMoved(_ windowID: UInt32) -> String {
            "computer_out_of_bounds: Window \(windowID) moved or resized since its screenshot. Call computer_screenshot again."
        }
        static func userActive(_ app: ComputerUseAppIdentity) -> String {
            "computer_user_active: The user is using \(app.name) right now. Try again in a moment."
        }
        /// Everything may really be hidden or minimized, so it's a warning, not an error.
        static let noVisibleWindows =
            "No app windows are visible. If macOS is showing a Screen Recording prompt, ask the user to answer it, then retry."
        static let userActiveElsewhere = "computer_user_active: You're using the Mac right now. Try again in a moment."
        static func userTookOver(_ app: ComputerUseAppIdentity, typed: Int, of total: Int) -> String {
            "computer_user_active: The user started using \(app.name); stopped after typing \(typed) of \(total) characters."
        }
        static let userTookOverDrag =
            "computer_user_active: You started using the Mac, so the drag was cancelled mid-way; nothing was dropped."
        static func actionFailed(_ reason: String) -> String { "computer_action_failed: \(reason)" }
        static let noQuitting = "Agents can't quit apps."
        static let noCrossAppDrag = "Dragging between different apps isn't supported yet."
        static func openFailed(_ reason: String) -> String { "computer_open_failed: \(reason)" }
        static func waitTimeout(_ query: String, _ condition: ComputerUseCommand.WaitCondition, windowID: UInt32, ms: Int) -> String {
            let verb = condition == .appear ? "appeared" : "disappeared"
            return "computer_wait_timeout: Nothing matching \"\(query)\" \(verb) in window \(windowID) within \(ms) ms."
        }
        static func waitInconclusive(_ query: String, windowID: UInt32, ms: Int) -> String {
            "computer_wait_timeout: Couldn't confirm that \"\(query)\" disappeared from window \(windowID) within \(ms) ms: "
                + "the window's accessibility tree couldn't be read completely, so it may still be there."
        }
    }

    // MARK: - Calls

    func perform(_ command: ComputerUseCommand, sessionID: String) async -> AlasCLIResponse {
        if command.action == .cancel {
            // Only the session's own calls: another session's call id is ignored.
            if let callID = command.callID { calls[CallKey(sessionID: sessionID, callID: callID)]?.cancel() }
            return .ok
        }
        guard let callID = command.callID else { return await execute(command, sessionID: sessionID) }
        let key = CallKey(sessionID: sessionID, callID: callID)
        let task = Task { await self.execute(command, sessionID: sessionID) }
        calls[key] = task
        let response = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if calls[key] == task { calls[key] = nil }
        return response
    }

    private func execute(_ command: ComputerUseCommand, sessionID: String) async -> AlasCLIResponse {
        if let error = readiness().toolError { return .error(error) }
        if access.isStopped(session: sessionID) { return .error(Message.stopped) }
        if command.action == .apps { return await listApps(sessionID: sessionID) }
        let context = CallContext(
            sessionID: sessionID, epoch: epochs[sessionID, default: 0], generation: generations[sessionID, default: 0])
        if command.action == .openApp { return await openApp(command, context: context) }

        guard let windowID = command.windowID else { return .error(Message.windowNotFound(0)) }
        let epoch = context.epoch
        guard var window = await system.window(windowID) else { return .error(Message.windowNotFound(windowID)) }
        if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
        let input = Self.isInput(command.action)
        // A blocked app is refused as blocked, prompt or not, and costs no probe.
        if access.access(for: window.app, session: sessionID, input: input) == .blocked {
            return .error(Message.blocked(window.app))
        }
        // Before any card: the prompt's text and field show in the app's own windows.
        if await system.credentialPrompt(window.app.pid) { return .error(Message.credentialPrompt(window.app)) }
        // A drop into another window of the same app; another app's window is refused before any card.
        var toWindow: ComputerUseWindow?
        if command.action == .drag, let toID = command.toWindowID, toID != windowID {
            guard let end = await system.window(toID) else { return .error(Message.windowNotFound(toID)) }
            guard end.app.pid == window.app.pid else { return .error(Message.actionFailed(Message.noCrossAppDrag)) }
            toWindow = end
        }

        switch await approval(for: window.app, sessionID: sessionID, epoch: epoch, input: input) {
        case .refused(let response):
            return response
        case .allowed:
            break
        case .answered:
            // The window may have closed or moved while the card was up, or its id gone to another app.
            guard let current = await system.window(windowID), current.app.pid == window.app.pid else {
                return .error(Message.windowNotFound(windowID))
            }
            window = current
            if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
            if let refused = accessAfterAnswer(for: window.app, sessionID: sessionID, input: input) { return refused }
            if await system.credentialPrompt(window.app.pid) { return .error(Message.credentialPrompt(window.app)) }
            if let end = toWindow {
                guard let current = await system.window(end.windowID), current.app.pid == end.app.pid else {
                    return .error(Message.windowNotFound(end.windowID))
                }
                toWindow = current
            }
        }

        return await withDriverLock(sessionID: sessionID, app: window.app, epoch: epoch) { [toWindow] in
            (try await run(command, window: window, toWindow: toWindow, context: context), window.app)
        }
    }

    /// Runs `body` holding the driver lock, with the driver published before the system call.
    /// `body` returns the payload and the app the call ended up driving.
    private func withDriverLock(
        sessionID: String, app: ComputerUseAppIdentity, epoch: Int,
        _ body: () async throws -> (payload: [String: Any], app: ComputerUseAppIdentity)
    ) async -> AlasCLIResponse {
        if case .failure(let failure) = takeDriverLock(for: sessionID) { return .error(failure.message) }
        let heldLock = lock
        lockedCalls[sessionID, default: 0] += 1
        driver = (sessionID, app)

        let result: (payload: [String: Any], app: ComputerUseAppIdentity)
        do {
            try Task.checkCancellation()
            result = try await body()
            // A cancelled call discards what it captured.
            try Task.checkCancellation()
        } catch {
            // The last call out releases, unless one already claimed the role. Only the
            // lock these calls ran under: a later turn may hold a fresh one by now.
            if endLockedCall(of: sessionID) == 0, let heldLock, lock === heldLock {
                if let confirmedApp { driver = (sessionID, confirmedApp) } else { releaseDriver() }
            }
            if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
            return .error(Self.message(for: error))
        }
        endLockedCall(of: sessionID)
        // Stopped or ended mid-call: the lock is released (or about to be); don't reclaim the role.
        if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
        // A turn end (or a failed sibling call) may have released the lock; the
        // result still stands, but the role is only claimed while the lock is held.
        if lockSession == sessionID {
            driver = (sessionID, result.app)
            confirmedApp = result.app
        }
        return Self.serialize(result.payload)
    }

    private enum ApprovalGate {
        case allowed
        /// The user answered a card; the caller re-resolves its target and re-checks access.
        case answered
        case refused(AlasCLIResponse)
    }

    /// Calls that drive the app rather than look at it; other Alas builds refuse them.
    private static func isInput(_ action: ComputerUseCommand.Action) -> Bool {
        switch action {
        case .click, .type, .key, .scroll, .drag, .openApp: true
        case .apps, .screenshot, .inspect, .wait, .cancel: false
        }
    }

    private func approval(
        for app: ComputerUseAppIdentity, sessionID: String, epoch: Int, input: Bool
    ) async -> ApprovalGate {
        switch access.access(for: app, session: sessionID, input: input) {
        case .blocked:
            return .refused(.error(Message.blocked(app)))
        case .denied:
            return .refused(.error(Message.denied(app)))
        case .allowed:
            return .allowed
        case .needsApproval:
            let id = access.pendingApproval(session: sessionID, app: app)
            syncPending()
            // A new card, or one a later call waits on while still up.
            let time = now()
            if ComputerUseApprovalNudge.shouldNudge(lastNudgeAt: lastNudges[id], now: time, appIsActive: appIsActive()) {
                lastNudges[id] = time
                attention()
            }
            switch await waitForAnswer(id) {
            case .timedOut: return .refused(.error(Message.approvalPending(app)))
            case .stopped: return .refused(.error(Message.stopped))
            case .cancelled, .expired: return .refused(.error(Message.cancelled))
            case .answered: break
            }
            if let overtaken = overtaken(sessionID, since: epoch) { return .refused(overtaken) }
            return .answered
        }
    }

    private func accessAfterAnswer(for app: ComputerUseAppIdentity, sessionID: String, input: Bool) -> AlasCLIResponse? {
        switch access.access(for: app, session: sessionID, input: input) {
        case .allowed: nil
        case .denied: .error(Message.denied(app))
        case .blocked: .error(Message.blocked(app))
        case .needsApproval: .error(Message.approvalPending(app))
        }
    }

    /// Approval and the blocklist apply to the resolved app before anything launches.
    private func openApp(_ command: ComputerUseCommand, context: CallContext) async -> AlasCLIResponse {
        let sessionID = context.sessionID
        guard let identity = await system.resolveApp(command.name, command.bundleID) else {
            let reason = command.name.map { "No app named \"\($0)\"." }
                ?? "No app with bundle id \"\(command.bundleID ?? "")\"."
            return .error(Message.openFailed(reason))
        }
        if let overtaken = overtaken(sessionID, since: context.epoch) { return overtaken }
        if identity.pid > 0, await system.credentialPrompt(identity.pid) { return .error(Message.credentialPrompt(identity)) }
        switch await approval(for: identity, sessionID: sessionID, epoch: context.epoch, input: true) {
        case .refused(let response): return response
        case .allowed: break
        case .answered: if let refused = accessAfterAnswer(for: identity, sessionID: sessionID, input: true) { return refused }
        }
        return await withDriverLock(sessionID: sessionID, app: identity, epoch: context.epoch) {
            let running = try await system.openApp(identity)
            // What launched may not be what was approved; a blocked app's windows stay private.
            if access.access(for: running, session: sessionID, input: true) == .blocked {
                throw Refusal(Message.blocked(running))
            }
            var windows = await listedWindows(of: running.pid, otherwise: [])
            // A launched Chromium or Electron app shows its window before its web content: the
            // agent's first read would come back empty. The wait is a courtesy: a window that
            // can't be read doesn't fail an open that succeeded.
            if let front = windows.first {
                let waited: Bool
                do { waited = try await awaitWebContent(afterOpening: front, context: context) } catch is ComputerUseSystemError {
                    waited = false
                }
                if waited { windows = await listedWindows(of: running.pid, otherwise: windows) }
            }
            var payload: [String: Any] = ["version": 1, "app": Self.app(running)]
            // It may have been showing one before it was unhidden.
            if await system.credentialPrompt(running.pid) {
                payload["credential_prompt"] = true
                windows = []
            }
            let displays = system.displays()
            payload["windows"] = windows.map { Self.windowEntry($0, displays: displays) }
            return (payload, running)
        }
    }

    /// The app's windows front to back, less the untitled ones backing a sheet (its parent's
    /// tree holds the sheet, and no AX window answers for them); `otherwise` if it's gone.
    private func listedWindows(of pid: Int32, otherwise: [ComputerUseWindow]) async -> [ComputerUseWindow] {
        let windows = await system.runningApps().first { $0.app.pid == pid }?.windows ?? otherwise
        guard windows.contains(where: { $0.title == nil }) else { return windows }
        let sheets = await system.sheetFrames([pid])[pid] ?? []
        return windows.filter { !ComputerUseInputGeometry.isSheetBacking(title: $0.title, frame: $0.frame, sheetFrames: sheets) }
    }

    func answer(_ id: UUID, _ choice: ComputerUseApprovalChoice) {
        guard let resolved = access.resolvePending(id) else { return }
        let app = resolved.app
        access.record(choice, for: app, session: resolved.session)
        if choice == .alwaysAllow, let bundleID = app.bundleID { persistAlwaysAllowed(bundleID) }
        resumeWaiters(of: id, with: .answered)
        syncPending()
    }

    func isStopped(sessionID: String) -> Bool { stoppedSessions.contains(sessionID) }

    func stop(sessionID: String) async {
        access.stop(session: sessionID)
        stoppedSessions.insert(sessionID)
        endActivity(of: sessionID)
        cancelCalls(of: sessionID)
        for entry in access.pending where entry.session == sessionID {
            _ = access.resolvePending(entry.id)
            resumeWaiters(of: entry.id, with: .stopped)
        }
        syncPending()
        let release = releaseBackgroundFocus(of: sessionID)
        let restore = restoreWebContent(of: sessionID)
        await interrupt(sessionID)
        await release.value
        await restore.value
    }

    func resume(sessionID: String) {
        access.resume(session: sessionID)
        stoppedSessions.remove(sessionID)
    }

    /// A card still up from this turn expires with it: answering it later would grant the next turn.
    func turnEnded(sessionID: String) {
        access.turnEnded(session: sessionID)
        // An input from the ended turn stops between its events.
        for flag in inputFlags[sessionID] ?? [] { flag.set() }
        forgetSnapshots(of: sessionID)
        releaseLock(of: sessionID)
        dismissCursor(of: sessionID)
        for entry in access.pending where entry.session == sessionID {
            _ = access.resolvePending(entry.id)
            resumeWaiters(of: entry.id, with: .expired)
        }
        syncPending()
        releaseBackgroundFocus(of: sessionID)
        restoreWebContent(of: sessionID)
    }

    /// Idempotent: the manager may report a runtime end more than once (detach, reconnect).
    /// A stop outlives it, so a reconnected session stays stopped until the user resumes.
    func sessionEnded(sessionID: String) {
        let ids = access.pending.filter { $0.session == sessionID }.map(\.id)
        access.sessionEnded(session: sessionID)
        endActivity(of: sessionID)
        cancelCalls(of: sessionID)
        for id in ids { resumeWaiters(of: id, with: .stopped) }
        syncPending()
        releaseBackgroundFocus(of: sessionID)
        restoreWebContent(of: sessionID)
    }

    /// Turns AXEnhancedUserInterface off again in the apps the session's reads turned it on in.
    /// Their next first contact may wake them again.
    @discardableResult
    private func restoreWebContent(of sessionID: String) -> Task<Void, Never> {
        let apps = enhancedUserInterface.removeValue(forKey: sessionID).map { Array($0.values) } ?? []
        // Another session may still rely on it.
        let stillUsed = Set(enhancedUserInterface.values.flatMap(\.keys))
        let restored = apps.filter { !stillUsed.contains($0.pid) }
        let restoredPIDs = Set(restored.map(\.pid))
        // Their next first contact may set it again; a timeout's count carries over (`keepsAfterRestore`).
        wokenWebContent = wokenWebContent.filter {
            !restoredPIDs.contains($0.key.pid) || ComputerUseWebContent.keepsAfterRestore($0.value)
        }
        let system = system
        return Task {
            for app in restored {
                await system.restoreWebContent(app, ComputerUseWebContent.enhancedUserInterface)
            }
        }
    }

    /// Hands back the key windows the session's inputs still hold. They are taken out at once,
    /// so the action that keyed one doesn't release it a second time.
    @discardableResult
    private func releaseBackgroundFocus(of sessionID: String) -> Task<Void, Never> {
        let windows = backgroundKeyed.removeValue(forKey: sessionID).map { Array($0.values) } ?? []
        let system = system
        return Task {
            for window in windows {
                await system.releaseBackgroundFocus(window)
            }
        }
    }

    private func releaseBackgroundFocus(of window: ComputerUseWindow, sessionID: String) async {
        guard backgroundKeyed[sessionID]?.removeValue(forKey: window.windowID) != nil else { return }
        if backgroundKeyed[sessionID]?.isEmpty == true { backgroundKeyed[sessionID] = nil }
        await system.releaseBackgroundFocus(window)
    }

    // MARK: - Lifecycle helpers

    private func endActivity(of sessionID: String) {
        epochs[sessionID, default: 0] += 1
        for flag in inputFlags[sessionID] ?? [] { flag.set() }
        forgetSnapshots(of: sessionID)
        releaseLock(of: sessionID)
        dismissCursor(of: sessionID)
    }

    private func dismissCursor(of sessionID: String) {
        guard cursorSession == sessionID else { return }
        cursorSession = nil
        cursor.dismiss()
    }

    /// Shows the cursor over `window` and plays `cue`; a stop or turn end during it delivers nothing.
    private func moveCursor(_ cue: ComputerUseCursorCue, over window: ComputerUseWindow, context: CallContext) async throws {
        cursorSession = context.sessionID
        cursor.present(window)
        await cursor.perform(cue)
        try checkStillActive(context)
    }

    /// An element's cue goes to the part of it inside its clips in `window`.
    private static func cursorCue(
        for input: ComputerUseInput, element: ElementRef?, in window: ComputerUseWindow
    ) -> ComputerUseCursorCue {
        let kind: ComputerUseCursorInputKind
        let target: ComputerUseInputTarget?
        switch input {
        case .click(let at, _, _), .pointerClick(let at): (kind, target) = (.click, at)
        case .scroll(let at, _, _): (kind, target) = (.scroll, at)
        case .type(_, let at, _): (kind, target) = (.type, at)
        case .key: (kind, target) = (.key, nil)
        case .drag(let from, _, _): (kind, target) = (.drag, from)
        }
        var point: CGPoint?
        if case .point(let at) = target { point = at }
        return ComputerUseCursorCue.cue(
            for: kind, point: point, elementFrame: element?.frame(in: window), clips: element?.clips(in: window) ?? [window.frame])
    }

    private func forgetSnapshots(of sessionID: String) {
        generations[sessionID, default: 0] += 1
        snapshots = snapshots.filter { $0.key.sessionID != sessionID }
    }

    /// Releases the session's lock now, or once its last capturing call exits.
    private func releaseLock(of sessionID: String) {
        guard lockSession == sessionID else { return }
        if lockedCalls[sessionID, default: 0] > 0 {
            deferredRelease = lock
            driver = nil
        } else {
            releaseDriver()
        }
    }

    private func cancelCalls(of sessionID: String) {
        for (key, task) in calls where key.sessionID == sessionID { task.cancel() }
    }

    private func overtaken(_ sessionID: String, since epoch: Int) -> AlasCLIResponse? {
        if epochs[sessionID, default: 0] != epoch || access.isStopped(session: sessionID) {
            return .error(Message.stopped)
        }
        return nil
    }

    @discardableResult
    private func endLockedCall(of sessionID: String) -> Int {
        let remaining = max(lockedCalls[sessionID, default: 0] - 1, 0)
        lockedCalls[sessionID] = remaining == 0 ? nil : remaining
        if remaining == 0, lockSession == sessionID, let deferred = deferredRelease {
            deferredRelease = nil
            // Only the lock the release was asked for.
            if lock === deferred { releaseDriver() }
        }
        return remaining
    }

    private func releaseDriver() {
        lock?.release()
        lock = nil
        lockSession = nil
        driver = nil
        deferredRelease = nil
        confirmedApp = nil
    }

    /// The lock this call took, or nil when the session already held it.
    private func takeDriverLock(for sessionID: String) -> Result<ComputerUseDriverLock?, LockFailure> {
        if lockSession == sessionID {
            // A new call keeps the lock a turn end was about to drop.
            deferredRelease = nil
            return .success(nil)
        }
        if let holder = lockSession { return .failure(LockFailure(Message.busy(sessionLabel(holder)))) }
        do {
            let taken = try ComputerUseDriverLock.acquire(at: lockURL, label: sessionLabel(sessionID))
            lock = taken
            lockSession = sessionID
            return .success(taken)
        } catch {
            switch error {
            case .held(let label):
                return .failure(LockFailure(Message.busy(label ?? "another Alas session")))
            case .unavailable(let reason):
                return .failure(LockFailure(Message.captureFailed("The computer use lock is unavailable: \(reason)")))
            }
        }
    }

    private struct LockFailure: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// A call the coordinator itself refuses, carrying its exact tool error.
    private struct Refusal: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Approvals

    /// Calls currently waiting on an approval card.
    var waitingCallCount: Int { waiters.values.reduce(0) { $0 + $1.count } }

    private func waitForAnswer(_ id: UUID) async -> ApprovalOutcome {
        let token = UUID()
        let wait = approvalWait
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalOutcome, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                let timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                    self?.resumeWaiter(token, of: id, with: .timedOut)
                }
                waiters[id, default: [:]][token] = Waiter(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(token, of: id, with: .cancelled) }
        }
    }

    private func resumeWaiter(_ token: UUID, of id: UUID, with outcome: ApprovalOutcome) {
        guard let waiter = waiters[id]?.removeValue(forKey: token) else { return }
        if waiters[id]?.isEmpty == true { waiters[id] = nil }
        waiter.timeout?.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    private func resumeWaiters(of id: UUID, with outcome: ApprovalOutcome) {
        guard let entries = waiters.removeValue(forKey: id) else { return }
        for waiter in entries.values {
            waiter.timeout?.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func syncPending() {
        let before = Set(pendingApprovals.map(\.sessionID))
        let next = access.pending.map { ComputerUsePendingApproval(id: $0.id, sessionID: $0.session, app: $0.app) }
        if next != pendingApprovals { pendingApprovals = next }
        let ids = Set(next.map(\.id))
        lastNudges = lastNudges.filter { ids.contains($0.key) }
        let after = Set(next.map(\.sessionID))
        for sessionID in after.subtracting(before) {
            guard let transcript = transcript(sessionID),
                  transcript.streamingState == .sending || transcript.streamingState == .streaming
            else { continue }
            priorStreamingStates[sessionID] = transcript.streamingState
            transcript.streamingState = .awaitingPermission
        }
        for sessionID in before.subtracting(after) {
            guard let prior = priorStreamingStates.removeValue(forKey: sessionID),
                  let transcript = transcript(sessionID),
                  transcript.streamingState == .awaitingPermission,
                  transcript.pendingPermission == nil // an agent permission card still needs the user
            else { continue }
            transcript.streamingState = prior
        }
    }

    // MARK: - System calls and results

    private func listApps(sessionID: String) async -> AlasCLIResponse {
        let regular = await system.runningApps()
        let listed = Set(regular.map(\.app.pid))
        // Menu-bar apps stay out, except blocked ones (a password manager): computer_open_app
        // refuses them, and the listing shows why.
        let blockedAccessory = await system.accessoryApps().filter {
            !listed.contains($0.pid) && access.access(for: $0, session: sessionID) == .blocked
        }
        let apps = (regular + blockedAccessory.map { (app: $0, windows: [ComputerUseWindow]()) })
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        let accesses = apps.map { access.access(for: $0.app, session: sessionID) }
        // One read for the whole listing; a blocked app's windows aren't listed either way.
        let withWindows = zip(apps, accesses).filter { $1 != .blocked && !$0.windows.isEmpty }.map(\.0.app.pid)
        let prompts = withWindows.isEmpty ? [:] : await system.credentialPrompts(withWindows)
        // A sheet's backing window is untitled; its sheet shows in its parent's tree.
        let untitled = zip(apps, accesses).filter { $1 != .blocked && $0.windows.contains { $0.title == nil } }.map(\.0.app.pid)
        let sheets = untitled.isEmpty ? [:] : await system.sheetFrames(untitled)
        let displays = system.displays()
        var entries: [[String: Any]] = []
        for (entry, appAccess) in zip(apps, accesses) {
            var object = Self.app(entry.app)
            object["approval"] = Self.approvalName(appAccess)
            // A blocked app's window titles and frames stay private, and so do an app's while a
            // system password prompt shows in it, or may: one the probe budget didn't reach is
            // "unchecked", not claimed to show one.
            var windows = appAccess == .blocked ? [] : entry.windows.filter {
                !ComputerUseInputGeometry.isSheetBacking(title: $0.title, frame: $0.frame, sheetFrames: sheets[entry.app.pid] ?? [])
            }
            switch prompts[entry.app.pid] {
            case .showing?:
                object["credential_prompt"] = true
                windows = []
            case .unchecked?:
                object["credential_prompt"] = ComputerUseCredentialPrompt.Listing.unchecked.rawValue
                windows = []
            case .clear?, nil:
                break
            }
            object["windows"] = windows.map { Self.windowEntry($0, displays: displays) }
            entries.append(object)
        }
        var payload: [String: Any] = ["version": 1, "apps": entries]
        // While macOS shows its Screen Recording prompt, other apps' windows aren't listed; Alas's
        // own may still be, so they don't count.
        let others = regular.filter { !access.isAlas($0.app) }
        if !others.isEmpty, others.allSatisfy({ $0.windows.isEmpty }) { payload["warning"] = Message.noVisibleWindows }
        return Self.serialize(payload)
    }

    private func run(
        _ command: ComputerUseCommand, window: ComputerUseWindow, toWindow: ComputerUseWindow? = nil, context: CallContext
    ) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "version": 1,
            "window_id": Int(window.windowID),
            "app": Self.app(window.app),
        ]
        switch command.action {
        case .apps, .cancel, .openApp:
            preconditionFailure("computer_apps, computer_cancel and computer_open_app return before window resolution")
        case .screenshot:
            let shot = try await system.screenshot(window)
            try record(screenshot: shot, of: window, context: context)
            var windowInfo: [String: Any] = ["frame": Self.frame(window.frame)]
            windowInfo["title"] = window.title
            payload["window"] = windowInfo
            payload["image_size"] = ["width": Int(shot.pixelSize.width), "height": Int(shot.pixelSize.height)]
            payload["scale"] = Double(shot.scale)
            payload["captured_at"] = ISO8601DateFormatter().string(from: Date())
            payload["image"] = Self.image(shot)
        case .inspect:
            let read = try await readElements(
                window, query: command.query, limit: command.limit, maxDepth: command.maxDepth, context: context)
            payload["truncated"] = read.truncated
            payload["truncated_by"] = read.truncatedBy
            payload["elements"] = read.elements.map(Self.element)
            Self.report(depthLimited: read.depthLimited, warning: nil, for: command, into: &payload)
        case .wait:
            let read = try await waitFor(command, in: window, context: context)
            payload["truncated"] = read.truncated
            payload["truncated_by"] = read.truncatedBy
            payload["elements"] = read.elements.map(Self.element)
            Self.report(depthLimited: read.depthLimited, warning: nil, for: command, into: &payload)
        case .click, .type, .key, .scroll, .drag:
            try await act(command, in: window, toWindow: toWindow, context: context, payload: &payload)
        }
        return payload
    }

    private func act(
        _ command: ComputerUseCommand, in window: ComputerUseWindow, toWindow: ComputerUseWindow?, context: CallContext,
        payload: inout [String: Any]
    ) async throws {
        var window = window
        var toWindow = toWindow
        var input = try input(for: command, in: window, toWindow: toWindow, context: context)
        let direct = Self.deliversDirect(command)
        // What the window looked like, so an input the app ignored doesn't pass for one that worked.
        // Read first, so the takeover wait and the ref re-check are the last steps before the input.
        var target: (ComputerUseAXHandles, Int)?
        var targetRef: ElementRef?
        if let ref = command.ref, let snapshot = snapshot(of: window, context: context), let element = snapshot.refs[ref] {
            target = (snapshot.handles, element.handle)
            targetRef = element
        }
        let before = await fingerprint(of: window, for: command, target: target, context: context)
        // A drop into another window may change only that one.
        var beforeEnd: ComputerUseWindowFingerprint?
        if let toWindow { beforeEnd = await fingerprint(of: toWindow, for: command, target: nil, context: context) }
        try checkStillActive(context)
        // The cursor moves before the takeover wait. Its pointer is window-local, so a remap after
        // the wait still lands under it.
        let cue = Self.cursorCue(for: input, element: targetRef, in: window)
        try await moveCursor(cue, over: window, context: context)
        if try await waitForUserIdle(in: window, direct: direct, context: context) {
            // The window may have moved or closed while the user had it: map points against where it is now.
            window = try await currentWindow(window)
            if let end = toWindow { toWindow = try await currentWindow(end) }
            input = try self.input(for: command, in: window, toWindow: toWindow, context: context)
        }
        try checkStillActive(context)
        try await recheckRefs(of: command, in: window, toWindow: toWindow, context: context)
        // The re-check may have taken how the element reads now.
        if let ref = command.ref, let element = snapshot(of: window, context: context)?.refs[ref] { targetRef = element }
        // The prompt may have come up during the takeover wait.
        if await system.credentialPrompt(window.app.pid) { throw Refusal(Message.credentialPrompt(window.app)) }
        try checkStillActive(context)
        let delivered = try await deliver(input, of: command, to: window, toWindow: toWindow, direct: direct, context: context)
        // Parked where the drop landed, over the window it landed in. Cosmetic once the drop is
        // delivered: skipped when the call was stopped meanwhile, and the settle's check decides.
        if case .drag(_, .point(let drop), _) = input, (try? checkStillActive(context)) != nil {
            try? await moveCursor(.jump(to: drop, outline: nil, click: false), over: toWindow ?? window, context: context)
        }
        if command.action == .drag { try await refuseIfDragMovedWindow(window) }
        let changeWarning = try await settle(
            after: delivered, of: command, in: &window, target: target, before: before,
            end: toWindow.map { ($0, beforeEnd) }, context: context, payload: &payload).warning
        // The input may have brought the prompt up (an unlock button): it went through, but what
        // the window shows now is withheld, and nothing is pressed again.
        if await system.credentialPrompt(window.app.pid) {
            withholdElements(of: window, toWindow: toWindow, context: context, payload: &payload)
            return
        }
        // A read that left elements out for depth may have missed the press's effect, and a second press could undo it.
        let unchanged = changeWarning != nil && payload["depth_limited"] == nil
        // A press the app didn't confirm most likely happened: pressing again could undo it.
        var retried = false
        if let target, let targetRef, delivered.warning == nil, Self.retriesWithPointer(
            command, role: targetRef.role, delivered: delivered.delivery, unchanged: unchanged,
            manualAccessibility: system.usesManualAccessibility(window.app.pid)) {
            // The first press was delivered: a retry that fails reports why next to its result.
            retried = true
            let first = (payload: payload, window: window)
            do {
                try await retryWithPointer(
                    command, at: target, ref: targetRef, in: &window, before: before, firstWarning: changeWarning,
                    context: context, payload: &payload)
                payload["retried"] = "pointer"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                payload = first.payload
                window = first.window
                payload["retry_error"] = Self.message(for: error)
            }
        }
        // The retry's click may have brought the prompt up, and it may have come up since the
        // check above: neither the retry's read nor a screenshot shows it.
        if retried || command.includeScreenshot, await system.credentialPrompt(window.app.pid) {
            withholdElements(of: window, toWindow: toWindow, context: context, payload: &payload)
            return
        }
        guard command.includeScreenshot else { return }
        do {
            let current = await system.window(window.windowID).flatMap { $0.app.pid == window.app.pid ? $0 : nil } ?? window
            let shot = try await system.screenshot(current)
            try record(screenshot: shot, of: current, context: context)
            payload["scale"] = Double(shot.scale)
            payload["image"] = Self.image(shot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            payload["screenshot_error"] = error.localizedDescription
        }
    }

    /// The post-action read of a window a system password prompt now shows in: its elements and
    /// refs are dropped, and the warning says why.
    private func withholdElements(
        of window: ComputerUseWindow, toWindow: ComputerUseWindow?, context: CallContext, payload: inout [String: Any]
    ) {
        for shown in [window, toWindow].compactMap({ $0 }) {
            updateSnapshot(of: shown, context: context) { $0.refs = [:] }
        }
        payload["elements"] = [[String: Any]]()
        payload["truncated"] = true
        payload["truncated_by"] = nil
        payload["depth_limited"] = nil
        if toWindow != nil { payload["to_window"] = ["window_id": Int((toWindow ?? window).windowID)] }
        payload["credential_prompt"] = true
        payload["warning"] = Message.credentialPromptAfterInput(window.app)
    }

    /// The pointer click after an AX press that changed nothing, with the same checks as the first
    /// input, at the element that was pressed: it must still read as the one the agent was shown.
    /// Unless the window then visibly changed, the result keeps a no-change warning.
    private func retryWithPointer(
        _ command: ComputerUseCommand, at target: (ComputerUseAXHandles, Int), ref: ElementRef,
        in window: inout ComputerUseWindow, before: ComputerUseWindowFingerprint, firstWarning: String?,
        context: CallContext, payload: inout [String: Any]
    ) async throws {
        try checkStillActive(context)
        let retry = ComputerUseInput.pointerClick(.element(target.0, target.1))
        let retryCue = Self.cursorCue(for: retry, element: ref, in: window)
        try await moveCursor(retryCue, over: window, context: context)
        if try await waitForUserIdle(in: window, direct: false, context: context) { window = try await currentWindow(window) }
        try checkStillActive(context)
        guard await system.elementMatches(target.0, target.1, ref.role, ref.title) else {
            throw Refusal(Message.stale(command.ref ?? "", windowID: window.windowID))
        }
        try checkStillActive(context)
        let retried = try await deliver(retry, of: command, to: window, toWindow: nil, direct: false, context: context)
        let settled = try await settle(after: retried, of: command, in: &window, target: target, before: before,
                                       end: nil, context: context, payload: &payload)
        // A read that failed reports its error instead; one that can't tell is no success either.
        guard let after = settled.after, !ComputerUseChangeCheck.retryChanged(before: before, after: after) else { return }
        Self.report(
            depthLimited: payload["depth_limited"] != nil, warning: settled.warning ?? firstWarning, for: command,
            into: &payload)
    }

    /// A drag that grabbed the window instead of an item moves it; the button is already up then.
    /// A window that was off screen (another workspace) and came back with the activation moved
    /// without being grabbed.
    private func refuseIfDragMovedWindow(_ window: ComputerUseWindow) async throws {
        guard ComputerUseInputGeometry.frameIsOnScreen(window.frame, displays: system.displays()),
              let current = await system.window(window.windowID),
              ComputerUseInputGeometry.windowMoved(from: window.frame, to: current.frame)
        else { return }
        throw Refusal(Message.actionFailed("The drag moved the window instead of an item; nothing was dropped."))
    }

    /// Delivers the input, mapping its failures to the tool errors that name the ref and window.
    private func deliver(
        _ input: ComputerUseInput, of command: ComputerUseCommand, to window: ComputerUseWindow,
        toWindow: ComputerUseWindow?, direct: Bool, context: CallContext
    ) async throws -> ComputerUseDelivered {
        do {
            return try await deliver(input, to: window, direct: direct, sessionID: context.sessionID)
        } catch ComputerUseSystemError.staleElement {
            guard let ref = command.ref else { throw ComputerUseSystemError.actionFailed("The element is no longer valid.") }
            throw Refusal(Message.stale(ref, windowID: window.windowID))
        } catch ComputerUseSystemError.staleDropElement {
            throw Refusal(Message.stale(command.toRef ?? "", windowID: (toWindow ?? window).windowID))
        } catch ComputerUseSystemError.outOfBounds {
            throw Refusal(Message.outOfBounds(window.windowID))
        } catch ComputerUseSystemError.dropOutOfBounds {
            throw Refusal(Message.outOfBounds((toWindow ?? window).windowID))
        } catch ComputerUseSystemError.userActive {
            throw Refusal(userActiveMessage(window))
        } catch ComputerUseSystemError.userTookOver(let typed, let total) {
            throw Refusal(Message.userTookOver(window.app, typed: typed, of: total))
        } catch ComputerUseSystemError.userTookOverDrag {
            throw Refusal(Message.userTookOverDrag)
        }
    }

    /// `settleAndRead`, with a window the input made key in a background app kept through the
    /// settle and the read, which see the window as the input left it, and handed back after them.
    @discardableResult
    private func settle(
        after delivered: ComputerUseDelivered, of command: ComputerUseCommand, in window: inout ComputerUseWindow,
        target: (ComputerUseAXHandles, Int)?, before: ComputerUseWindowFingerprint,
        end: (window: ComputerUseWindow, before: ComputerUseWindowFingerprint?)?, context: CallContext,
        payload: inout [String: Any]
    ) async throws -> Settled {
        let keyedWindow = delivered.keyedInBackground ? window : nil
        if let keyedWindow { backgroundKeyed[context.sessionID, default: [:]][keyedWindow.windowID] = keyedWindow }
        let settled: Settled
        do {
            settled = try await settleAndRead(after: delivered, of: command, in: &window, target: target, before: before,
                                                    end: end, context: context, payload: &payload)
        } catch {
            if let keyedWindow { await releaseBackgroundFocus(of: keyedWindow, sessionID: context.sessionID) }
            throw error
        }
        if let keyedWindow { await releaseBackgroundFocus(of: keyedWindow, sessionID: context.sessionID) }
        return settled
    }

    /// The change check's warning, nil when the input changed something or a read can't tell, and
    /// the window read back after the input, nil when that read failed.
    private struct Settled {
        var warning: String?
        var after: ComputerUseWindowFingerprint?
        /// The start window's own elements changed (`ComputerUseChangeCheck.elementsChanged`).
        var startChanged = true
    }

    private static func joined(_ warnings: String?...) -> String? {
        let present = warnings.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " ")
    }

    /// `depth_limited` when the read left elements out for depth, with the hint appended to the warning.
    private static func report(
        depthLimited: Bool, warning: String?, for command: ComputerUseCommand, into payload: inout [String: Any]
    ) {
        payload["depth_limited"] = depthLimited ? true : nil
        guard depthLimited else {
            payload["warning"] = warning
            return
        }
        let hint = ComputerUseInspectTree.depthHint(
            maxDepth: command.maxDepth, queryGiven: command.query != nil, takesMaxDepth: command.action != .wait)
        payload["warning"] = [warning, hint].compactMap { $0 }.joined(separator: " ")
    }

    /// Drags always go with the app brought to the front, so the direct takeover rule applies to
    /// them: refused while the user is active, rather than waited out.
    static func deliversDirect(_ command: ComputerUseCommand) -> Bool {
        command.delivery == .direct || command.action == .drag
    }

    /// An AX press may only focus an element in an app that builds its tree on request (Electron):
    /// a left single click by ref that went as AX and changed nothing is retried once as a pointer
    /// click. Never in other apps, where an AX press that changed nothing is the app's answer, nor
    /// on a toggle or menu item (`role`, as read), where a second press could undo the first.
    /// A query-filtered read can't tell either: the press may have changed only elements it hides.
    static func retriesWithPointer(
        _ command: ComputerUseCommand, role: String, delivered: ComputerUseDelivery, unchanged: Bool,
        manualAccessibility: Bool
    ) -> Bool {
        command.action == .click && command.ref != nil && command.button == .left && command.count == 1
            && (command.query ?? "").isEmpty && !noPointerRetryRoles.contains(role) && delivered == .ax && unchanged
            && manualAccessibility
    }

    static let noPointerRetryRoles: Set<String> = [
        "AXCheckBox", "AXSwitch", "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXToggle",
    ]

    /// Reports the delivered input, waits for the app to handle it and reads the window back.
    private func settleAndRead(
        after delivered: ComputerUseDelivered, of command: ComputerUseCommand, in window: inout ComputerUseWindow,
        target: (ComputerUseAXHandles, Int)?, before: ComputerUseWindowFingerprint,
        end: (window: ComputerUseWindow, before: ComputerUseWindowFingerprint?)? = nil, context: CallContext,
        payload: inout [String: Any]
    ) async throws -> Settled {
        // Stopped mid-sequence: the input finished its events, but nothing more happens.
        try checkStillActive(context)
        payload["action"] = command.action.rawValue
        payload["delivery"] = delivered.delivery.rawValue
        payload["menu_item"] = delivered.menuItem
        payload["button"] = delivered.button

        await sleep(Self.settleDelay)
        try checkStillActive(context)
        // The input landed; a failed re-read must not report it as failed.
        do {
            var read: ElementRead
            do {
                // The action may have moved or resized the window; the read matches it by its frame.
                window = try await currentWindow(window)
                read = try await readElements(
                    window, query: command.query, limit: command.limit, maxDepth: command.maxDepth, context: context)
            } catch ComputerUseSystemError.appNotResponding {
                // An app still busy with what the input opened (a sheet sliding in) answers a moment later.
                await sleep(Self.postReadRetryDelay)
                try checkStillActive(context)
                window = try await currentWindow(window)
                read = try await readElements(
                    window, query: command.query, limit: command.limit, maxDepth: command.maxDepth, context: context)
            }
            var verdict = try await check(
                read, of: window, after: delivered, of: command, target: target, before: before, end: end,
                context: context, payload: &payload)
            if command.action == .drag {
                // Finder and others show a drop a moment later: a drag that seems to have changed
                // nothing is read again until it shows, or the deadline passes. Slow reads count too.
                let clock = ContinuousClock()
                let start = clock.now
                var slept = Duration.zero
                // A drop into another window may show there first: the start window, which the result
                // lists, is read until it shows the drop too (a moved file leaves it).
                // Once a read showed the drop, a later one that shows nothing new doesn't undo it.
                var dropped = verdict.warning == nil
                while !dropped || (end != nil && !verdict.startChanged), slept < Self.dragConfirmDeadline,
                      clock.now - start < Self.dragConfirmDeadline {
                    await sleep(Self.dragConfirmPoll)
                    slept += Self.dragConfirmPoll
                    try checkStillActive(context)
                    let polled: ElementRead
                    do {
                        window = try await currentWindow(window)
                        polled = try await readElements(
                            window, query: command.query, limit: command.limit, maxDepth: command.maxDepth,
                            context: context)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A re-read that failed says nothing new: the last read's result stands.
                        break
                    }
                    read = polled
                    verdict = try await check(
                        read, of: window, after: delivered, of: command, target: target, before: before, end: end,
                        context: context, payload: &payload)
                    if verdict.warning == nil { dropped = true } else if dropped { verdict.warning = nil }
                }
            }
            Self.report(
                depthLimited: read.depthLimited, warning: Self.joined(delivered.warning, verdict.warning), for: command,
                into: &payload)
            return verdict
        } catch is CancellationError {
            throw CancellationError()
        } catch let refusal as Refusal {
            // The turn ended during the retry's wait.
            throw refusal
        } catch {
            // The action changed the window, so the refs from before it are gone either way.
            updateSnapshot(of: window, context: context) { $0.refs = [:] }
            // An earlier attempt's verdict doesn't describe this read.
            Self.report(depthLimited: false, warning: delivered.warning, for: command, into: &payload)
            payload["truncated"] = true
            payload["truncated_by"] = nil
            payload["elements"] = [[String: Any]]()
            payload["post_state_error"] = error.localizedDescription
            return Settled()
        }
    }

    /// The change check over a post-action read of the start window, with the drop window, if
    /// any, read back too, into the payload: the elements of this read and the verdict over both.
    private func check(
        _ read: ElementRead, of window: ComputerUseWindow, after delivered: ComputerUseDelivered,
        of command: ComputerUseCommand, target: (ComputerUseAXHandles, Int)?, before: ComputerUseWindowFingerprint,
        end: (window: ComputerUseWindow, before: ComputerUseWindowFingerprint?)?, context: CallContext,
        payload: inout [String: Any]
    ) async throws -> Settled {
        payload["truncated"] = read.truncated
        payload["truncated_by"] = read.truncatedBy
        payload["elements"] = read.elements.map(Self.element)
        let after = await fingerprint(of: window, read: read, target: target)
        let kind = Self.changeKind(command.action)
        let asEvents = [.event, .background].contains(delivered.delivery)
        var warning = ComputerUseChangeCheck.warning(before: before, after: after, kind: kind, deliveredAsEvents: asEvents)
        // The start window shows the drop only when its elements change: activation, the raise and
        // the mouse-down move focus and selection first.
        let startChanged = ComputerUseChangeCheck.elementsChanged(before: before, after: after)
        if let end {
            // The drop window read back too: the drop may have changed only that one.
            // An unreadable drop window says nothing either way, so the start window's verdict stands.
            if let endRead = try await readDropWindow(end.window, of: command, context: context, payload: &payload) {
                let endAfter = await fingerprint(of: endRead.window, read: endRead.read, target: nil)
                let endWarning = ComputerUseChangeCheck.warning(
                    before: end.before, after: endAfter, kind: kind, deliveredAsEvents: asEvents)
                if endWarning == nil { warning = nil }
            }
        }
        return Settled(warning: warning, after: after, startChanged: startChanged)
    }

    /// Reads the window a drag dropped into, as the start window is read, into `to_window`.
    /// A failed read reports its error there and leaves the drop window's refs empty.
    private func readDropWindow(
        _ window: ComputerUseWindow, of command: ComputerUseCommand, context: CallContext, payload: inout [String: Any]
    ) async throws -> (window: ComputerUseWindow, read: ElementRead)? {
        var entry: [String: Any] = ["window_id": Int(window.windowID)]
        defer { payload["to_window"] = entry }
        do {
            let current = try await currentWindow(window)
            let read = try await readElements(
                current, query: command.query, limit: command.limit, maxDepth: command.maxDepth, context: context)
            entry["truncated"] = read.truncated
            entry["truncated_by"] = read.truncatedBy
            entry["elements"] = read.elements.map(Self.element)
            if read.depthLimited { entry["depth_limited"] = true }
            return (current, read)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            updateSnapshot(of: window, context: context) { $0.refs = [:] }
            entry["truncated"] = true
            entry["elements"] = [[String: Any]]()
            entry["post_state_error"] = error.localizedDescription
            return nil
        }
    }

    private static func changeKind(_ action: ComputerUseCommand.Action) -> ComputerUseChangeCheck.Kind {
        switch action {
        case .type: .type
        case .key: .key
        case .scroll: .scroll
        case .drag: .drag
        default: .click
        }
    }

    static let settleDelay: Duration = .milliseconds(300)
    /// Before the one retry of a post-action read the app didn't answer.
    static let postReadRetryDelay: Duration = .milliseconds(300)
    /// Between re-reads of a drag that seems to have changed nothing, up to `dragConfirmDeadline`
    /// of them after the first read.
    static let dragConfirmPoll: Duration = .milliseconds(250)
    static let dragConfirmDeadline: Duration = .milliseconds(1500)
    static let takeoverPoll: Duration = .milliseconds(100)
    static let waitPoll: Duration = .milliseconds(250)

    /// Nodes and time the read before an input may take: it delays the input, and a read cut
    /// short only turns the change check off.
    static let fingerprintNodeBudget = 500
    static let fingerprintTimeLimit: Duration = .seconds(1)

    /// The window as the post-action read will see it. A failed or cut-short read leaves the
    /// element list unknown, which never counts as unchanged.
    private func fingerprint(
        of window: ComputerUseWindow, for command: ComputerUseCommand, target: (ComputerUseAXHandles, Int)?,
        context: CallContext
    ) async -> ComputerUseWindowFingerprint {
        let read = try? await readElements(
            window, query: command.query, limit: command.limit, maxDepth: command.maxDepth, context: context,
            recordRefs: false, nodeBudget: Self.fingerprintNodeBudget, timeLimit: Self.fingerprintTimeLimit)
        return await fingerprint(of: window, read: read, target: target)
    }

    /// Built the same way before and after the input, so an unchanged window compares equal.
    private func fingerprint(
        of window: ComputerUseWindow, read: ElementRead?, target: (ComputerUseAXHandles, Int)?
    ) async -> ComputerUseWindowFingerprint {
        let focus = await system.focusState(window)
        var targetHash: Int?
        if let target { targetHash = await system.elementState(target.0, target.1) }
        return ComputerUseWindowFingerprint(
            focus: focus, windowTitle: window.title,
            elementsHash: read.flatMap { $0.truncated ? nil : ComputerUseChangeCheck.elementsHash($0.elements) },
            targetHash: targetHash)
    }

    /// The window as it is now; gone or now another app's → `windowNotFound`.
    private func currentWindow(_ window: ComputerUseWindow) async throws -> ComputerUseWindow {
        guard let current = await system.window(window.windowID), current.app.pid == window.app.pid else {
            throw ComputerUseSystemError.windowNotFound(window.windowID)
        }
        return current
    }

    /// An element behind a ref must still read as what the agent was shown.
    /// `toRef` is in `toWindow`'s snapshot when the drag drops into another window.
    /// One that reads otherwise now (a page turned a search field into a combo box for its
    /// suggestions) is looked for once in the window as it is: the very same element there is
    /// still the one the agent was shown, and the ref takes how it reads now. A lookalike never is.
    private func recheckRefs(
        of command: ComputerUseCommand, in window: ComputerUseWindow, toWindow: ComputerUseWindow?, context: CallContext
    ) async throws {
        for (ref, window) in [(command.ref, window), (command.toRef, toWindow ?? window)] {
            guard let ref else { continue }
            guard let snapshot = snapshot(of: window, context: context), let element = snapshot.refs[ref]
            else { throw Refusal(Message.stale(ref, windowID: window.windowID)) }
            if await system.elementMatches(snapshot.handles, element.handle, element.role, element.title) { continue }
            let tree = try await system.axTree(
                window, ComputerUseCommand.maxDepthLimit, Self.queryNodeBudget, ComputerUseAXReader.deadline)
            try checkStillActive(context)
            func same(_ node: ComputerUseAXNode) -> ComputerUseAXNode? {
                if let handle = node.handle, system.sameElement(snapshot.handles, element.handle, tree.handles, handle) {
                    return node
                }
                return node.children.lazy.compactMap(same).first
            }
            guard let now = same(tree.root) else { throw Refusal(Message.stale(ref, windowID: window.windowID)) }
            updateSnapshot(of: window, context: context) {
                $0.refs[ref]?.role = now.role
                $0.refs[ref]?.title = now.title
            }
        }
    }

    private func input(
        for command: ComputerUseCommand, in window: ComputerUseWindow, toWindow: ComputerUseWindow?, context: CallContext
    ) throws -> ComputerUseInput {
        func target(_ ref: String?, _ x: Double?, _ y: Double?) throws -> ComputerUseInputTarget {
            try self.target(ref: ref, x: x, y: y, in: window, context: context)
        }
        switch command.action {
        case .click:
            return try .click(target(command.ref, command.x, command.y), button: command.button, count: command.count)
        case .type:
            let element = try command.ref.map { try target($0, nil, nil) }
            return .type(command.text ?? "", target: element, replace: command.mode == .replace)
        case .key:
            guard let keys = command.keys, let chord = ComputerUseKeyChord.parse(keys) else {
                throw Refusal(Message.actionFailed("\"\(command.keys ?? "")\" is not a key chord."))
            }
            if ComputerUseMenuShortcut.isQuit(chord) { throw Refusal(Message.actionFailed(Message.noQuitting)) }
            return .key(chord)
        case .scroll:
            return try .scroll(target(command.ref, command.x, command.y), dx: command.dx, dy: command.dy)
        case .drag:
            // The drop end resolves in the window it is in: its refs, its screenshot, its frame.
            let end = try self.target(ref: command.toRef, x: command.toX, y: command.toY, in: toWindow ?? window, context: context)
            return try .drag(from: target(command.ref, command.x, command.y), to: end, toWindow: toWindow)
        case .apps, .screenshot, .inspect, .cancel, .openApp, .wait:
            preconditionFailure("\(command.action.rawValue) is not an input action")
        }
    }

    private func target(
        ref: String?, x: Double?, y: Double?, in window: ComputerUseWindow, context: CallContext
    ) throws -> ComputerUseInputTarget {
        let snapshot = snapshot(of: window, context: context)
        if let ref {
            guard let snapshot, let element = snapshot.refs[ref] else { throw Refusal(Message.stale(ref, windowID: window.windowID)) }
            return .element(snapshot.handles, element.handle)
        }
        guard let x, let y else { throw Refusal(Message.actionFailed("The action needs a ref or x and y.")) }
        guard let screenshot = snapshot?.lastScreenshot else { throw Refusal(Message.needsScreenshot(window.windowID)) }
        if ComputerUseInputGeometry.screenshotStale(screenshotFrame: screenshot.frame, currentFrame: window.frame) {
            throw Refusal(Message.screenshotMoved(window.windowID))
        }
        guard let point = ComputerUseInputGeometry.globalPoint(
            pixel: CGPoint(x: x, y: y), screenshotFrame: screenshot.frame, scale: screenshot.scale, currentFrame: window.frame)
        else { throw Refusal(Message.outOfBounds(window.windowID)) }
        return .point(point)
    }

    /// Holds input back while the user is typing or clicking in the target app; true when it waited.
    private func waitForUserIdle(in window: ComputerUseWindow, direct: Bool, context: CallContext) async throws -> Bool {
        var waited = Duration.zero
        while true {
            let targetIsFrontmost = system.isFrontmost(window.app.pid)
            let decision = ComputerUseTakeover.decide(
                targetIsFrontmost: targetIsFrontmost,
                idleSeconds: system.secondsSinceUserInput(),
                direct: direct,
                waited: Self.seconds(waited)
            )
            switch decision {
            case .proceed: return waited > .zero
            case .refuse: throw Refusal(targetIsFrontmost ? Message.userActive(window.app) : Message.userActiveElsewhere)
            case .wait:
                await sleep(Self.takeoverPoll)
                waited += Self.takeoverPoll
                try checkStillActive(context)
            }
        }
    }

    /// Names the target app when the user is in it, else the Mac.
    private func userActiveMessage(_ window: ComputerUseWindow) -> String {
        system.isFrontmost(window.app.pid) ? Message.userActive(window.app) : Message.userActiveElsewhere
    }

    /// The input sees a stop, session end or cancellation through `isCancelled`, between its events.
    private func deliver(
        _ input: ComputerUseInput, to window: ComputerUseWindow, direct: Bool, sessionID: String
    ) async throws -> ComputerUseDelivered {
        let flag = CancelFlag()
        inputFlags[sessionID, default: []].append(flag)
        defer {
            inputFlags[sessionID]?.removeAll { $0 === flag }
            if inputFlags[sessionID]?.isEmpty == true { inputFlags[sessionID] = nil }
        }
        let system = system
        let pid = window.app.pid
        // The takeover rule between a long input's events: the user is working in the target app.
        let interrupt: @Sendable () -> ComputerUseInputInterrupt? = {
            if flag.isSet { return .cancelled }
            let userActive = system.isFrontmost(pid)
                && system.secondsSinceUserInput() < ComputerUseTakeover.idleThreshold
            return userActive ? .userActive : nil
        }
        return try await withTaskCancellationHandler {
            try await system.perform(input, window, direct, interrupt)
        } onCancel: {
            flag.set()
        }
    }

    private func waitFor(
        _ command: ComputerUseCommand, in window: ComputerUseWindow, context: CallContext
    ) async throws -> ElementRead {
        let query = command.query ?? ""
        let timeout = Duration.milliseconds(command.timeoutMS)
        let clock = ContinuousClock()
        let start = clock.now
        var slept = Duration.zero
        var window = window
        while true {
            // Only the read returned to the agent replaces its refs.
            let read = try await readElements(
                window, query: query, limit: command.limit, maxDepth: command.maxDepth, context: context, recordRefs: false)
            // A partial read can miss the element, so only a complete one confirms it is gone.
            let incomplete = read.truncated || read.depthLimited
            let met = command.condition == .appear ? !read.elements.isEmpty : read.elements.isEmpty && !incomplete
            // A prompt that came up during the wait may be what appeared.
            if met, await system.credentialPrompt(window.app.pid) { throw Refusal(Message.credentialPrompt(window.app)) }
            if met {
                record(refs: read, of: window, context: context)
                return read
            }
            // Slow reads count too, so a stalled app can't stretch the wait.
            if slept >= timeout || clock.now - start >= timeout {
                // The window changed while the agent waited; the refs it holds may point elsewhere now.
                updateSnapshot(of: window, context: context) { $0.refs = [:] }
                if command.condition == .disappear, read.elements.isEmpty {
                    throw Refusal(Message.waitInconclusive(query, windowID: window.windowID, ms: command.timeoutMS))
                }
                throw Refusal(Message.waitTimeout(query, command.condition, windowID: window.windowID, ms: command.timeoutMS))
            }
            await sleep(Self.waitPoll)
            slept += Self.waitPoll
            try checkStillActive(context)
            // A window that moved or resized is still matched; one that closed ends the wait.
            window = try await currentWindow(window)
        }
    }

    private struct ElementRead {
        var truncated: Bool
        /// What cut a truncated read short (`ComputerUseInspectTree.truncation`).
        var truncatedBy: String?
        /// Elements were left out for being deeper than the read's max depth.
        var depthLimited = false
        var elements: [ComputerUseInspectElement]
        var handles: ComputerUseAXHandles
        /// Every ref the read named, listed or not, to its handle.
        var refs: [String: Int]
        /// Role, title, frame and scroll area by handle, before the inspect output clips them.
        var identities: [Int: Identity]
    }

    /// An element as read: `scrollArea` is the frame of the nearest scroll area among the
    /// ancestors the event route searches.
    private struct Identity {
        var role: String
        var title: String?
        var frame: CGRect
        var scrollArea: CGRect?
    }

    /// Reads the window the way computer_inspect does and, unless told not to, replaces its refs.
    /// `nodeBudget` and `timeLimit` only lower the read's own caps.
    private func readElements(
        _ window: ComputerUseWindow, query: String?, limit: Int, maxDepth: Int, context: CallContext, recordRefs: Bool = true,
        nodeBudget: Int = .max, timeLimit: Duration = ComputerUseAXReader.deadline
    ) async throws -> ElementRead {
        // Without a query the walk only needs one node past the limit to report truncation.
        let budget = min(query == nil ? limit + 1 : Self.queryNodeBudget, nodeBudget)
        let readLimit = min(timeLimit, ComputerUseAXReader.deadline)
        var tree = try await system.axTree(window, maxDepth, budget, readLimit)
        // A Chromium or Electron window may show only empty groups, or an empty web area, at first
        // contact: the app is asked for its tree and waited for, then the window is read again with
        // the call's own caps.
        if try await wakeWebContent(window, shown: tree.root, context: context) {
            tree = try await system.axTree(window, maxDepth, budget, readLimit)
        }
        let flat = ComputerUseInspectTree.flatten(tree.root, query: query, limit: limit, maxDepth: maxDepth)
        // A cancelled read never reaches the agent, so it must not replace the refs it holds.
        try Task.checkCancellation()
        // A partial read may have missed elements even when the limit was not reached.
        var identities: [Int: Identity] = [:]
        // Ancestors nearest last, as many as `ComputerUseAXActions.visibleCenter` climbs from the parent.
        func collect(_ node: ComputerUseAXNode, above: [(role: String, frame: CGRect)]) {
            if let handle = node.handle {
                let area = above.last { $0.role == "AXScrollArea" }?.frame
                identities[handle] = Identity(
                    role: node.role, title: node.title, frame: node.frame,
                    scrollArea: area.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil })
            }
            let next = Array((above + [(node.role, node.frame)]).suffix(ComputerUseAXActions.scrollAncestorLevels + 1))
            for child in node.children { collect(child, above: next) }
        }
        collect(tree.root, above: [])
        let read = ElementRead(
            truncated: flat.truncated || tree.cut != nil,
            truncatedBy: ComputerUseInspectTree.truncation(limitReached: flat.truncated, cut: tree.cut),
            depthLimited: flat.depthLimited, elements: flat.elements,
            handles: tree.handles, refs: flat.refs, identities: identities)
        if recordRefs { record(refs: read, of: window, context: context) }
        return read
    }

    private func record(refs read: ElementRead, of window: ComputerUseWindow, context: CallContext) {
        // A query or limit only trims what the agent is shown: every element the read named stays
        // usable. One the agent was shown before but this read doesn't list must still be the very
        // element it saw (a same-role, same-title one may have shifted into its place); otherwise
        // the ref now names something it never saw, and is dropped.
        let before = snapshot(of: window, context: context)
        let previous = before?.refs ?? [:]
        let listed = Set(read.elements.map(\.ref))
        let origin = window.frame.origin
        func local(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: -origin.x, dy: -origin.y) }
        var refs: [String: ElementRef] = [:]
        for (ref, handle) in read.refs {
            guard let identity = read.identities[handle] else { continue }
            if listed.contains(ref) {
                refs[ref] = ElementRef(
                    handle: handle, role: identity.role, title: identity.title, localFrame: local(identity.frame),
                    localScrollArea: identity.scrollArea.map(local), shown: true)
            } else if let seen = previous[ref], seen.shown {
                guard seen.role == identity.role, seen.title == identity.title, let before,
                      system.sameElement(before.handles, seen.handle, read.handles, handle)
                else { continue }
                refs[ref] = ElementRef(
                    handle: handle, role: seen.role, title: seen.title, localFrame: local(identity.frame),
                    localScrollArea: identity.scrollArea.map(local), shown: true)
            } else {
                refs[ref] = ElementRef(
                    handle: handle, role: identity.role, title: identity.title, localFrame: local(identity.frame),
                    localScrollArea: identity.scrollArea.map(local), shown: false)
            }
        }
        updateSnapshot(of: window, context: context) {
            $0.refs = refs
            $0.handles = read.handles
        }
    }

    private func record(screenshot: ComputerUseScreenshot, of window: ComputerUseWindow, context: CallContext) throws {
        try Task.checkCancellation()
        updateSnapshot(of: window, context: context) { $0.lastScreenshot = (window.frame, screenshot.scale) }
    }

    private func snapshot(of window: ComputerUseWindow, context: CallContext) -> Snapshot? {
        guard context.generation == generations[context.sessionID, default: 0],
              let snapshot = snapshots[SnapshotKey(sessionID: context.sessionID, windowID: window.windowID)],
              snapshot.generation == context.generation, snapshot.pid == window.app.pid
        else { return nil }
        return snapshot
    }

    private func updateSnapshot(of window: ComputerUseWindow, context: CallContext, _ change: (inout Snapshot) -> Void) {
        guard context.generation == generations[context.sessionID, default: 0] else { return }
        var snapshot = snapshot(of: window, context: context)
            ?? Snapshot(generation: context.generation, pid: window.app.pid)
        change(&snapshot)
        snapshots[SnapshotKey(sessionID: context.sessionID, windowID: window.windowID)] = snapshot
    }

    /// A stop, session end or cancellation since the call started ends it before its next step.
    private func checkStillActive(_ context: CallContext) throws {
        try Task.checkCancellation()
        if epochs[context.sessionID, default: 0] != context.epoch || access.isStopped(session: context.sessionID) {
            throw CancellationError()
        }
        // The turn this call belongs to ended: its grant and refs are gone.
        if generations[context.sessionID, default: 0] != context.generation { throw Refusal(Message.cancelled) }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private static let log = Logger(subsystem: "io.nlopez.alas", category: "computer-use")

    /// Between reads of a web window waiting for its content (`ComputerUseWebContent.keepsWaiting`).
    static let webContentPoll: Duration = .milliseconds(100)
    /// The time limit of each read during that wait.
    static let webContentReadLimit: Duration = .milliseconds(500)

    /// Nodes an inspect with a query may read before filtering.
    static let queryNodeBudget = 10_000

    private static func serialize(_ payload: [String: Any]) -> AlasCLIResponse {
        // JSONSerialization raises an Objective-C exception, which `try?` doesn't catch and which
        // ends the app, on a value it can't write (a NaN): such a result is refused instead.
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return .error(Message.captureFailed("The result could not be encoded."))
        }
        guard data.count <= resultLimit, let json = String(data: data, encoding: .utf8) else {
            return .error(Message.limit)
        }
        return .text([json])
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case ComputerUseSystemError.windowNotFound(let id): Message.windowNotFound(id)
        case ComputerUseSystemError.windowUnreadable(let id): Message.windowUnreadable(id)
        case ComputerUseSystemError.captureFailed(let reason): Message.captureFailed(reason)
        case ComputerUseSystemError.appNotResponding(let app): Message.captureFailed("\(app) is not responding")
        case ComputerUseSystemError.actionFailed(let reason), ComputerUseSystemError.notActiveWindow(let reason):
            Message.actionFailed(reason)
        case ComputerUseSystemError.openFailed(let reason): Message.openFailed(reason)
        case let refusal as Refusal: refusal.message
        case is CancellationError: Message.cancelled
        default: Message.captureFailed(error.localizedDescription)
        }
    }

    static func approvalName(_ access: ComputerUseAppAccess) -> String {
        switch access {
        case .blocked: "blocked"
        case .allowed(let scope): scope.rawValue
        case .denied: "denied"
        case .needsApproval: "needs_approval"
        }
    }

    private static func app(_ app: ComputerUseAppIdentity) -> [String: Any] {
        var object: [String: Any] = ["name": app.name, "pid": Int(app.pid)]
        object["bundle_id"] = app.bundleID
        return object
    }

    /// `off_screen`: none of the window is on a display (another Space, an AeroSpace workspace).
    private static func windowEntry(_ window: ComputerUseWindow, displays: [CGRect]) -> [String: Any] {
        var info: [String: Any] = ["window_id": Int(window.windowID), "frame": frame(window.frame)]
        if !ComputerUseInputGeometry.frameIsOnScreen(window.frame, displays: displays) { info["off_screen"] = true }
        info["title"] = window.title
        return info
    }

    private static func image(_ shot: ComputerUseScreenshot) -> [String: String] {
        ["mime_type": "image/png", "data": shot.png.base64EncodedString()]
    }

    /// An app may report a NaN or infinite position or size; it reads as 0.
    private static func frame(_ rect: CGRect) -> [String: Double] {
        func finite(_ value: CGFloat) -> Double { value.isFinite ? Double(value) : 0 }
        return ["x": finite(rect.origin.x), "y": finite(rect.origin.y), "width": finite(rect.width), "height": finite(rect.height)]
    }

    private static func element(_ element: ComputerUseInspectElement) -> [String: Any] {
        var object: [String: Any] = [
            "ref": element.ref,
            "depth": element.depth,
            "role": element.role,
            "frame": frame(element.frame),
            "enabled": element.isEnabled,
            "focused": element.isFocused,
        ]
        object["subrole"] = element.subrole
        object["title"] = element.title
        object["value"] = element.value
        if let length = element.valueLength {
            object["value_truncated"] = true
            object["value_length"] = length
        }
        object["description"] = element.description
        if !element.isVisible { object["visible"] = false }
        return object
    }
}

/// Set once by a stop, session end or cancellation; read by the input between its events.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
