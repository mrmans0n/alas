import AlasCore
import CoreGraphics
import Foundation
import Observation

/// An approval card: one per (session, app), shared by every call that waits on it.
struct ComputerUsePendingApproval: Identifiable, Equatable {
    let id: UUID
    let sessionID: String
    let app: ComputerUseAppIdentity
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
        /// Listed to the agent at some point: a later read that doesn't list it must still find
        /// the element the agent saw there, not whatever took its place.
        var shown: Bool
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
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
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
        static func denied(_ app: ComputerUseAppIdentity) -> String { "computer_denied: The user denied access to \(app.name) for this turn." }
        static func approvalPending(_ app: ComputerUseAppIdentity) -> String {
            "computer_approval_pending: Waiting for the user to approve \(app.name). Try again after they answer."
        }
        static func busy(_ label: String) -> String {
            "computer_busy: Another session is using the computer (\(label)). Try again when it finishes."
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
        static func userActive(_ app: ComputerUseAppIdentity) -> String {
            "computer_user_active: The user is using \(app.name) right now. Try again in a moment."
        }
        static func userTookOver(_ app: ComputerUseAppIdentity, typed: Int, of total: Int) -> String {
            "computer_user_active: The user started using \(app.name); stopped after typing \(typed) of \(total) characters."
        }
        static func actionFailed(_ reason: String) -> String { "computer_action_failed: \(reason)" }
        static let noQuitting = "Agents can't quit apps."
        static func openFailed(_ reason: String) -> String { "computer_open_failed: \(reason)" }
        static func waitTimeout(_ query: String, _ condition: ComputerUseCommand.WaitCondition, windowID: UInt32, ms: Int) -> String {
            let verb = condition == .appear ? "appeared" : "disappeared"
            return "computer_wait_timeout: Nothing matching \"\(query)\" \(verb) in window \(windowID) within \(ms) ms."
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
        }

        var toWindow: ComputerUseWindow?
        if command.action == .drag, let toID = command.toWindowID, toID != windowID {
            // The drop window's app is operated too: it needs access like the start's, from the same rules.
            guard let end = await system.window(toID) else { return .error(Message.windowNotFound(toID)) }
            switch await approval(for: end.app, sessionID: sessionID, epoch: epoch, input: true) {
            case .refused(let response):
                return response
            case .allowed:
                toWindow = end
            case .answered:
                guard let current = await system.window(toID), current.app.pid == end.app.pid else {
                    return .error(Message.windowNotFound(toID))
                }
                if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
                if let refused = accessAfterAnswer(for: current.app, sessionID: sessionID, input: true) { return refused }
                // The start window's access may have changed while this card was up.
                if let refused = accessAfterAnswer(for: window.app, sessionID: sessionID, input: true) { return refused }
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
            let windows = await system.runningApps().first { $0.app.pid == running.pid }?.windows ?? []
            let payload: [String: Any] = ["version": 1, "app": Self.app(running), "windows": windows.map(Self.windowEntry)]
            return (payload, running)
        }
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
        await interrupt(sessionID)
        await release.value
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
        for entry in access.pending where entry.session == sessionID {
            _ = access.resolvePending(entry.id)
            resumeWaiters(of: entry.id, with: .expired)
        }
        syncPending()
        releaseBackgroundFocus(of: sessionID)
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
        let apps = await system.runningApps()
        let entries: [[String: Any]] = apps.map { entry in
            let appAccess = access.access(for: entry.app, session: sessionID)
            var object = Self.app(entry.app)
            object["approval"] = Self.approvalName(appAccess)
            // A blocked app's window titles and frames stay private.
            object["windows"] = appAccess == .blocked ? [] : entry.windows.map(Self.windowEntry)
            return object
        }
        return Self.serialize(["version": 1, "apps": entries])
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
            payload["elements"] = read.elements.map(Self.element)
        case .wait:
            let read = try await waitFor(command, in: window, context: context)
            payload["truncated"] = read.truncated
            payload["elements"] = read.elements.map(Self.element)
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
        // Events posted to one app never reach another: a drop into another app's window goes
        // with the start app activated, onto a drop window the user can see.
        let direct = command.delivery == .direct || toWindow.map { $0.app.pid != window.app.pid } == true
        // What the window looked like, so an input the app ignored doesn't pass for one that worked.
        // Read first, so the takeover wait and the ref re-check are the last steps before the input.
        var target: (ComputerUseAXHandles, Int)?
        if let ref = command.ref, let snapshot = snapshot(of: window, context: context), let element = snapshot.refs[ref] {
            target = (snapshot.handles, element.handle)
        }
        let before = await fingerprint(of: window, for: command, target: target, context: context)
        try checkStillActive(context)
        if try await waitForUserIdle(in: window, direct: direct, context: context) {
            // The window may have moved or closed while the user had it: map points against where it is now.
            window = try await currentWindow(window)
            if let end = toWindow { toWindow = try await currentWindow(end) }
            input = try self.input(for: command, in: window, toWindow: toWindow, context: context)
        }
        try checkStillActive(context)
        try await recheckRefs(of: command, in: window, toWindow: toWindow, context: context)
        try checkStillActive(context)
        let delivered: ComputerUseDelivered
        do {
            delivered = try await deliver(input, to: window, direct: direct, sessionID: context.sessionID)
        } catch ComputerUseSystemError.staleElement {
            if let ref = command.ref { throw Refusal(Message.stale(ref, windowID: window.windowID)) }
            guard let ref = command.toRef else { throw ComputerUseSystemError.actionFailed("The element is no longer valid.") }
            throw Refusal(Message.stale(ref, windowID: (toWindow ?? window).windowID))
        } catch ComputerUseSystemError.outOfBounds {
            throw Refusal(Message.outOfBounds(window.windowID))
        } catch ComputerUseSystemError.userActive {
            throw Refusal(Message.userActive(window.app))
        } catch ComputerUseSystemError.userTookOver(let typed, let total) {
            throw Refusal(Message.userTookOver(window.app, typed: typed, of: total))
        }
        // A background app whose window the input made key keeps it through the settle and the
        // read below, which see the window as the input left it; it is handed back after them.
        let keyedWindow = delivered.keyedInBackground ? window : nil
        if let keyedWindow { backgroundKeyed[context.sessionID, default: [:]][keyedWindow.windowID] = keyedWindow }
        do {
            try await settleAndRead(after: delivered, of: command, in: &window, target: target, before: before,
                                    context: context, payload: &payload)
        } catch {
            if let keyedWindow { await releaseBackgroundFocus(of: keyedWindow, sessionID: context.sessionID) }
            throw error
        }
        if let keyedWindow { await releaseBackgroundFocus(of: keyedWindow, sessionID: context.sessionID) }
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

    /// Reports the delivered input, waits for the app to handle it and reads the window back.
    private func settleAndRead(
        after delivered: ComputerUseDelivered, of command: ComputerUseCommand, in window: inout ComputerUseWindow,
        target: (ComputerUseAXHandles, Int)?, before: ComputerUseWindowFingerprint, context: CallContext,
        payload: inout [String: Any]
    ) async throws {
        // Stopped mid-sequence: the input finished its events, but nothing more happens.
        try checkStillActive(context)
        payload["action"] = command.action.rawValue
        payload["delivery"] = delivered.delivery.rawValue
        payload["menu_item"] = delivered.menuItem

        await sleep(Self.settleDelay)
        try checkStillActive(context)
        // The input landed; a failed re-read must not report it as failed.
        do {
            // The action may have moved or resized the window; the read matches it by its frame.
            window = try await currentWindow(window)
            let read = try await readElements(
                window, query: command.query, limit: command.limit, maxDepth: Self.postStateDepth, context: context)
            payload["truncated"] = read.truncated
            payload["elements"] = read.elements.map(Self.element)
            let after = await fingerprint(of: window, read: read, target: target)
            payload["warning"] = ComputerUseChangeCheck.warning(
                before: before, after: after, kind: Self.changeKind(command.action),
                deliveredAsEvents: [.event, .background].contains(delivered.delivery))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The action changed the window, so the refs from before it are gone either way.
            updateSnapshot(of: window, context: context) { $0.refs = [:] }
            payload["truncated"] = true
            payload["elements"] = [[String: Any]]()
            payload["post_state_error"] = error.localizedDescription
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
    static let postStateDepth = 12
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
            window, query: command.query, limit: command.limit, maxDepth: Self.postStateDepth, context: context,
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
    private func recheckRefs(
        of command: ComputerUseCommand, in window: ComputerUseWindow, toWindow: ComputerUseWindow?, context: CallContext
    ) async throws {
        for (ref, window) in [(command.ref, window), (command.toRef, toWindow ?? window)] {
            guard let ref else { continue }
            guard let snapshot = snapshot(of: window, context: context), let element = snapshot.refs[ref],
                  await system.elementMatches(snapshot.handles, element.handle, element.role, element.title)
            else { throw Refusal(Message.stale(ref, windowID: window.windowID)) }
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
        guard let point = ComputerUseInputGeometry.globalPoint(
            pixel: CGPoint(x: x, y: y), screenshotFrame: screenshot.frame, scale: screenshot.scale, currentFrame: window.frame)
        else { throw Refusal(Message.outOfBounds(window.windowID)) }
        return .point(point)
    }

    /// Holds input back while the user is typing or clicking in the target app; true when it waited.
    private func waitForUserIdle(in window: ComputerUseWindow, direct: Bool, context: CallContext) async throws -> Bool {
        var waited = Duration.zero
        while true {
            let decision = ComputerUseTakeover.decide(
                targetIsFrontmost: system.frontmostPID() == window.app.pid,
                idleSeconds: system.secondsSinceUserInput(),
                direct: direct,
                waited: Self.seconds(waited)
            )
            switch decision {
            case .proceed: return waited > .zero
            case .refuse: throw Refusal(Message.userActive(window.app))
            case .wait:
                await sleep(Self.takeoverPoll)
                waited += Self.takeoverPoll
                try checkStillActive(context)
            }
        }
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
            let userActive = system.frontmostPID() == pid
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
    ) async throws -> (truncated: Bool, elements: [ComputerUseInspectElement]) {
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
            if read.elements.isEmpty == (command.condition == .disappear) {
                record(refs: read, of: window, context: context)
                return (read.truncated, read.elements)
            }
            // Slow reads count too, so a stalled app can't stretch the wait.
            if slept >= timeout || clock.now - start >= timeout {
                // The window changed while the agent waited; the refs it holds may point elsewhere now.
                updateSnapshot(of: window, context: context) { $0.refs = [:] }
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
        var elements: [ComputerUseInspectElement]
        var handles: ComputerUseAXHandles
        /// Every ref the read named, listed or not, to its handle.
        var refs: [String: Int]
        /// Role and title by handle, before the inspect output clips them.
        var identities: [Int: (role: String, title: String?)]
    }

    /// Reads the window the way computer_inspect does and, unless told not to, replaces its refs.
    /// `nodeBudget` and `timeLimit` only lower the read's own caps.
    private func readElements(
        _ window: ComputerUseWindow, query: String?, limit: Int, maxDepth: Int, context: CallContext, recordRefs: Bool = true,
        nodeBudget: Int = .max, timeLimit: Duration = ComputerUseAXReader.deadline
    ) async throws -> ElementRead {
        // Without a query the walk only needs one node past the limit to report truncation.
        let budget = min(query == nil ? limit + 1 : Self.queryNodeBudget, nodeBudget)
        let tree = try await system.axTree(window, maxDepth, budget, min(timeLimit, ComputerUseAXReader.deadline))
        let flat = ComputerUseInspectTree.flatten(tree.root, query: query, limit: limit, maxDepth: maxDepth)
        // A cancelled read never reaches the agent, so it must not replace the refs it holds.
        try Task.checkCancellation()
        // A partial read may have missed elements even when the limit was not reached.
        var identities: [Int: (role: String, title: String?)] = [:]
        func collect(_ node: ComputerUseAXNode) {
            if let handle = node.handle { identities[handle] = (node.role, node.title) }
            node.children.forEach(collect)
        }
        collect(tree.root)
        let read = ElementRead(
            truncated: flat.truncated || !tree.complete, elements: flat.elements, handles: tree.handles, refs: flat.refs,
            identities: identities)
        if recordRefs { record(refs: read, of: window, context: context) }
        return read
    }

    private func record(refs read: ElementRead, of window: ComputerUseWindow, context: CallContext) {
        // A query or limit only trims what the agent is shown: every element the read named stays
        // usable. One the agent was shown before but this read doesn't list must still be what it
        // saw; otherwise the ref now names something it never saw, and is dropped.
        let previous = snapshot(of: window, context: context)?.refs ?? [:]
        let listed = Set(read.elements.map(\.ref))
        var refs: [String: ElementRef] = [:]
        for (ref, handle) in read.refs {
            guard let identity = read.identities[handle] else { continue }
            if listed.contains(ref) {
                refs[ref] = ElementRef(handle: handle, role: identity.role, title: identity.title, shown: true)
            } else if let seen = previous[ref], seen.shown {
                guard seen.role == identity.role, seen.title == identity.title else { continue }
                refs[ref] = ElementRef(handle: handle, role: seen.role, title: seen.title, shown: true)
            } else {
                refs[ref] = ElementRef(handle: handle, role: identity.role, title: identity.title, shown: false)
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

    /// Nodes an inspect with a query may read before filtering.
    static let queryNodeBudget = 10_000

    private static func serialize(_ payload: [String: Any]) -> AlasCLIResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
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
        case ComputerUseSystemError.captureFailed(let reason): Message.captureFailed(reason)
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

    private static func windowEntry(_ window: ComputerUseWindow) -> [String: Any] {
        var info: [String: Any] = ["window_id": Int(window.windowID), "frame": frame(window.frame)]
        info["title"] = window.title
        return info
    }

    private static func image(_ shot: ComputerUseScreenshot) -> [String: String] {
        ["mime_type": "image/png", "data": shot.png.base64EncodedString()]
    }

    private static func frame(_ rect: CGRect) -> [String: Double] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
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
