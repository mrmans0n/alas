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
    /// This process's active driver: set by a successful screenshot or inspect.
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

    @ObservationIgnored private var lock: ComputerUseDriverLock?
    /// The session the lock was taken for; set before the system call, unlike `driver`.
    @ObservationIgnored private var lockSession: String?
    /// Calls per session past the lock and inside their system call, so a failing
    /// call never drops the lock under a sibling that is still capturing.
    @ObservationIgnored private var lockedCalls: [String: Int] = [:]
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

    static let resultLimit = 12 * 1024 * 1024

    init(
        system: ComputerUseSystem,
        access: ComputerUseAccess,
        readiness: @escaping @MainActor () -> ComputerUseReadiness,
        sessionLabel: @escaping @MainActor (String) -> String,
        persistAlwaysAllowed: @escaping @MainActor (String) -> Void,
        interrupt: @escaping @MainActor (String) async -> Void,
        lockURL: URL = ComputerUseDriverLock.defaultURL,
        approvalWait: Duration = .seconds(50)
    ) {
        self.system = system
        self.access = access
        self.readiness = readiness
        self.sessionLabel = sessionLabel
        self.persistAlwaysAllowed = persistAlwaysAllowed
        self.interrupt = interrupt
        self.lockURL = lockURL
        self.approvalWait = approvalWait
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

        guard let windowID = command.windowID else { return .error(Message.windowNotFound(0)) }
        let epoch = epochs[sessionID, default: 0]
        guard var window = await system.window(windowID) else { return .error(Message.windowNotFound(windowID)) }
        if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }

        switch access.access(for: window.app, session: sessionID) {
        case .blocked:
            return .error(Message.blocked(window.app))
        case .denied:
            return .error(Message.denied(window.app))
        case .allowed:
            break
        case .needsApproval:
            let id = access.pendingApproval(session: sessionID, app: window.app)
            syncPending()
            switch await waitForAnswer(id) {
            case .timedOut: return .error(Message.approvalPending(window.app))
            case .stopped: return .error(Message.stopped)
            case .cancelled, .expired: return .error(Message.cancelled)
            case .answered: break
            }
            if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
            // The window may have closed or moved while the card was up.
            guard let current = await system.window(windowID) else { return .error(Message.windowNotFound(windowID)) }
            window = current
            if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
            switch access.access(for: window.app, session: sessionID) {
            case .allowed: break
            case .denied: return .error(Message.denied(window.app))
            case .blocked: return .error(Message.blocked(window.app))
            case .needsApproval: return .error(Message.approvalPending(window.app))
            }
        }

        if case .failure(let failure) = takeDriverLock(for: sessionID) { return .error(failure.message) }
        let heldLock = lock
        lockedCalls[sessionID, default: 0] += 1

        let payload: [String: Any]
        do {
            try Task.checkCancellation()
            payload = try await run(command, window: window)
            // A cancelled call discards what it captured.
            try Task.checkCancellation()
        } catch {
            // The last call out releases, unless one already claimed the role. Only the
            // lock these calls ran under: a later turn may hold a fresh one by now.
            if endLockedCall(of: sessionID) == 0, driver?.sessionID != sessionID,
               let heldLock, lock === heldLock {
                releaseDriver()
            }
            if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
            return .error(Self.message(for: error))
        }
        endLockedCall(of: sessionID)
        // Stopped or ended mid-call: the lock is already released; don't reclaim the role.
        if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
        // A turn end (or a failed sibling call) may have released the lock; the
        // result still stands, but the role is only claimed while the lock is held.
        if lockSession == sessionID { driver = (sessionID, window.app) }
        return Self.serialize(payload)
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
        for entry in access.pending where entry.session == sessionID {
            _ = access.resolvePending(entry.id)
            resumeWaiters(of: entry.id, with: .stopped)
        }
        syncPending()
        await interrupt(sessionID)
    }

    func resume(sessionID: String) {
        access.resume(session: sessionID)
        stoppedSessions.remove(sessionID)
    }

    /// A card still up from this turn expires with it: answering it later would grant the next turn.
    func turnEnded(sessionID: String) {
        access.turnEnded(session: sessionID)
        if lockSession == sessionID { releaseDriver() }
        for entry in access.pending where entry.session == sessionID {
            _ = access.resolvePending(entry.id)
            resumeWaiters(of: entry.id, with: .expired)
        }
        syncPending()
    }

    /// Idempotent: the manager may report a runtime end more than once (detach, reconnect).
    /// A stop outlives it, so a reconnected session stays stopped until the user resumes.
    func sessionEnded(sessionID: String) {
        let ids = access.pending.filter { $0.session == sessionID }.map(\.id)
        access.sessionEnded(session: sessionID)
        endActivity(of: sessionID)
        for id in ids { resumeWaiters(of: id, with: .stopped) }
        syncPending()
    }

    // MARK: - Lifecycle helpers

    private func endActivity(of sessionID: String) {
        epochs[sessionID, default: 0] += 1
        if lockSession == sessionID { releaseDriver() }
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
        return remaining
    }

    private func releaseDriver() {
        lock?.release()
        lock = nil
        lockSession = nil
        driver = nil
    }

    /// The lock this call took, or nil when the session already held it.
    private func takeDriverLock(for sessionID: String) -> Result<ComputerUseDriverLock?, LockFailure> {
        if lockSession == sessionID { return .success(nil) }
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
            let windows: [[String: Any]] = appAccess == .blocked ? [] : entry.windows.map { window in
                var info: [String: Any] = ["window_id": Int(window.windowID), "frame": Self.frame(window.frame)]
                info["title"] = window.title
                return info
            }
            object["windows"] = windows
            return object
        }
        return Self.serialize(["version": 1, "apps": entries])
    }

    private func run(_ command: ComputerUseCommand, window: ComputerUseWindow) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "version": 1,
            "window_id": Int(window.windowID),
            "app": Self.app(window.app),
        ]
        switch command.action {
        case .apps, .cancel:
            preconditionFailure("computer_apps and computer_cancel return before window resolution")
        case .screenshot:
            let shot = try await system.screenshot(window)
            var windowInfo: [String: Any] = ["frame": Self.frame(window.frame)]
            windowInfo["title"] = window.title
            payload["window"] = windowInfo
            payload["image_size"] = ["width": Int(shot.pixelSize.width), "height": Int(shot.pixelSize.height)]
            payload["scale"] = Double(shot.scale)
            payload["captured_at"] = ISO8601DateFormatter().string(from: Date())
            payload["image"] = ["mime_type": "image/png", "data": shot.png.base64EncodedString()]
        case .inspect:
            // Without a query the walk only needs one node past the limit to report truncation.
            let budget = command.query == nil ? command.limit + 1 : Self.queryNodeBudget
            let tree = try await system.axTree(window, command.maxDepth, budget)
            let flat = ComputerUseInspectTree.flatten(
                tree.root, query: command.query, limit: command.limit, maxDepth: command.maxDepth)
            // A partial read may have missed elements even when the limit was not reached.
            payload["truncated"] = flat.truncated || !tree.complete
            payload["elements"] = flat.elements.map(Self.element)
        }
        return payload
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
        object["description"] = element.description
        return object
    }
}
