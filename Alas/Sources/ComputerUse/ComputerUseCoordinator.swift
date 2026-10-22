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

    /// Finds a session's transcript, so a pending approval shows as awaiting permission.
    @ObservationIgnored var transcript: (String) -> ACPTranscript? = { _ in nil }

    private enum ApprovalOutcome { case answered, stopped, timedOut, cancelled }

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
    @ObservationIgnored private var waiters: [UUID: [UUID: Waiter]] = [:]
    /// Bumped on stop and session end, so an in-flight call notices it was overtaken.
    @ObservationIgnored private var epochs: [String: Int] = [:]
    /// Streaming states replaced by `.awaitingPermission` while a card is up.
    @ObservationIgnored private var priorStreamingStates: [String: ACPSession.StreamingState] = [:]

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
        if let error = readiness().toolError { return .error(error) }
        if access.isStopped(session: sessionID) { return .error(Message.stopped) }
        if command.action == .apps { return await listApps(sessionID: sessionID) }

        guard let windowID = command.windowID else { return .error(Message.windowNotFound(0)) }
        let epoch = epochs[sessionID, default: 0]
        guard let window = await system.window(windowID) else { return .error(Message.windowNotFound(windowID)) }
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
            case .cancelled: return .error(Message.cancelled)
            case .answered: break
            }
            if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
            switch access.access(for: window.app, session: sessionID) {
            case .allowed: break
            case .denied: return .error(Message.denied(window.app))
            case .blocked: return .error(Message.blocked(window.app))
            case .needsApproval: return .error(Message.approvalPending(window.app))
            }
        }

        let tookLock: Bool
        switch takeDriverLock(for: sessionID) {
        case .failure(let failure): return .error(failure.message)
        case .success(let fresh): tookLock = fresh
        }

        let payload: [String: Any]
        do {
            payload = try await run(command, window: window)
        } catch {
            if tookLock, lockSession == sessionID { releaseDriver() }
            if let overtaken = overtaken(sessionID, since: epoch) { return overtaken }
            return .error(Self.message(for: error))
        }
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

    func isStopped(sessionID: String) -> Bool { access.isStopped(session: sessionID) }

    func stop(sessionID: String) async {
        access.stop(session: sessionID)
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
    }

    func turnEnded(sessionID: String) {
        access.turnEnded(session: sessionID)
        if lockSession == sessionID { releaseDriver() }
    }

    /// Idempotent: the manager may report a runtime end more than once (detach, reconnect).
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

    private func releaseDriver() {
        lock?.release()
        lock = nil
        lockSession = nil
        driver = nil
    }

    /// `.success(true)` when this call took the lock, `.success(false)` when the session already held it.
    private func takeDriverLock(for sessionID: String) -> Result<Bool, LockFailure> {
        if lockSession == sessionID { return .success(false) }
        if let holder = lockSession { return .failure(LockFailure(Message.busy(sessionLabel(holder)))) }
        do {
            lock = try ComputerUseDriverLock.acquire(at: lockURL, label: sessionLabel(sessionID))
            lockSession = sessionID
            return .success(true)
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
            [
                "name": entry.app.name,
                "bundle_id": entry.app.bundleID.map { $0 as Any } ?? NSNull(),
                "pid": Int(entry.app.pid),
                "approval": Self.approvalName(access.access(for: entry.app, session: sessionID)),
                "windows": entry.windows.map { window -> [String: Any] in
                    [
                        "window_id": Int(window.windowID),
                        "title": window.title.map { $0 as Any } ?? NSNull(),
                        "frame": Self.frame(window.frame),
                    ]
                },
            ]
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
        case .apps:
            preconditionFailure("computer_apps is listed before window resolution")
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
                tree, query: command.query, limit: command.limit, maxDepth: command.maxDepth)
            payload["truncated"] = flat.truncated
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
