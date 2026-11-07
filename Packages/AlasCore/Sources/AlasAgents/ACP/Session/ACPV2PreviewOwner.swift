import Foundation
import Synchronization
import AlasACP
import AlasSessions
import AlasPlatform
import AlasModel

/// One fresh local installation. Saved display never constructs this owner.
@MainActor
public final class ACPV2PreviewOwner {
    public enum Failure: Error, LocalizedError {
        case unavailable, busy, invalidInput, invalidated, cleanupUnavailable, qualifiedModeUnavailable
        public var errorDescription: String? {
            switch self {
            case .unavailable: "This preview is unavailable."
            case .busy: "Wait for the current preview turn to finish."
            case .invalidInput: "This preview requires a fresh local session and a qualified launch configuration."
            case .invalidated: "The preview no longer has current writer authority."
            case .cleanupUnavailable: "Preview cleanup has not confirmed an owned process was closed."
            case .qualifiedModeUnavailable: "The adapter did not confirm the qualified approval mode."
            }
        }
    }
    public typealias DisplayWriter = @Sendable (ACPV2PreviewDisplaySnapshot, ACPSessionLeaseFence, @escaping @Sendable () -> Bool) async throws -> Bool
    public private(set) var status: ACPV2PreviewStatus = .idle
    public private(set) var lastCompletion: ACPSessionLifecycle.ForegroundCompletion?
    public private(set) var awaitingSubmission = false
    public var foreground: ACPForegroundState { session.v2Projection?.foreground ?? .unknown }
    public var presentation: ACPV2PreviewPresentation {
        .init(runtimeKind: session.runtimeKind, status: status, foreground: foreground,
            writerAuthority: active && isCurrent(), pendingDecision: pendingDecisions,
            awaitingSubmission: awaitingSubmission)
    }
    private let session: ACPSession
    private let client: ACPBrokerClient
    private let persistence: ACPSessionPersistence
    private let fence: ACPSessionLeaseFence
    private let qualification: ACPV2PreviewQualifiedAdapter
    public let installationID: UUID
    private let isCurrent: @MainActor () -> Bool
    private let onChange: @MainActor () -> Void
    private let displayWriter: DisplayWriter
    private var active = true
    public private(set) var permissions: [ACPV2PreviewPermissionItem] = []
    private struct PermissionOrigin: Hashable {
        let stream: UUID
        let ordinal: Int64
        init(_ record: ACPV2InboundLedgerRecord) { stream = record.streamID
        ordinal = record.ordinal }
    }
    private var permissionHandles: [UUID: ACPV2RequestDecisionCoordinator.Handle] = [:]
    private var permissionOrigins: [PermissionOrigin: UUID] = [:]
    private var pendingRejections: [PermissionOrigin: ACPV2RequestDecisionCoordinator.Handle] = [:]
    private var rejectionWorkers: [PermissionOrigin: Task<Void, Never>] = [:]
    private var pendingDecisions: Bool { permissions.contains { $0.phase == .awaitingDecision || $0.phase == .sending } }
    private var runner: ACPV2SessionRunner?
    private var upstreamID: String?
    private var monitor: Task<Void, Never>?
    private var startupWorker: Task<Void, Never>?
    private var startupTimeout: Task<Void, Never>?
    private var startupWaiter: CheckedContinuation<Void, any Error>?
    private var cleanup: Task<Bool, Never>?
    private let cleanupAuthority = Authority()
    private var displaySequence: Int64 = 0
    private var displayAuthority = Authority()
    private var displayTask: Task<Void, Never>?
    private var displayScheduled = false
    private var displayScheduler: Task<Void, Never>?
    private final class Authority: Sendable {
        private let current = Mutex(true)
        var valid: Bool { current.withLock { $0 } }
        func withdraw() { current.withLock { $0 = false } }
    }

    public init(session: ACPSession, client: ACPBrokerClient, persistence: ACPSessionPersistence,
        fence: ACPSessionLeaseFence, qualification: ACPV2PreviewQualifiedAdapter, installationID: UUID,
        isCurrent: @escaping @MainActor () -> Bool, onChange: @escaping @MainActor () -> Void,
        displayWriter: DisplayWriter? = nil) {
        self.session = session
        self.client = client
        self.persistence = persistence
        self.fence = fence
        self.qualification = qualification
        self.installationID = installationID
        self.isCurrent = isCurrent
        self.onChange = onChange
        self.displayWriter = displayWriter ?? { snapshot, fence, authorize in
            try await persistence.persistV2PreviewDisplay(snapshot, fence: fence, authorize: authorize)
        }
    }

    public func start(params: ACPV2SessionNewParams, deadline: ContinuousClock.Instant) async throws {
        guard status == .idle, active, session.runtimeKind == .v2FreshPreview,
              session.id == fence.sessionId, qualification.agentID == session.agentId,
              (session.agentId == "codex" && qualification.approvalMode == "read-only")
                || (session.agentId == "claude" && qualification.approvalMode == "default"),
              deadline > .now else { throw Failure.invalidInput }
        try requireCurrent()
        status = .starting
        onChange()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                startupWaiter = waiter
                startupTimeout = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    self?.fail("Preview startup deadline expired")
                }
                startupWorker = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.startBody(params: params, deadline: deadline)
                        self.finishStartup(nil)
                    } catch {
                        self.finishStartup(error)
                        if self.active { self.fail(error.localizedDescription) }
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.withdraw() } }
    }

    private func startBody(params: ACPV2SessionNewParams, deadline: ContinuousClock.Instant) async throws {
        guard await currentLease() else { throw Failure.invalidated }
        try requireCurrent()
        try client.validateV2PreviewLaunch(sessionId: session.id, agentId: session.agentId, approvalMode: qualification.approvalMode)
        let runner = try await ACPV2SessionRunner.makeBroker(session: session, client: client, persistence: persistence,
            fence: fence, info: .init(name: "alas", version: "v2-preview"),
            onProjectionChange: { [weak self] _ in self?.scheduleDisplay()
            self?.onChange() },
            isCurrent: { [weak self] in self?.isActive() == true }, onEvent: { [weak self] in self?.event($0) })
        try requireCurrent()
        self.runner = runner
        monitor = Task { [weak self] in
            for await value in runner.observations { self?.observed(value) }
        }
        let result = try await runner.start(params: params, deadline: deadline)
        try requireCurrent()
        upstreamID = result.sessionId
        if session.agentId == "claude" {
            let response = try await client.send(.init(method: "session/set_config_option",
                params: ["sessionId": result.sessionId, "configId": "mode", "type": "id", "value": qualification.approvalMode],
                brokerOperationKey: "alas:v2:preview:\(installationID):mode"))
            try requireCurrent()
            guard let raw = response.rawDelivery, try raw.decode().error == nil,
                  let fields = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let options = fields["configOptions"] as? [[String: Any]],
                  options.filter({ $0["configId"] as? String == "mode" }).count == 1,
                  let mode = options.first(where: { $0["configId"] as? String == "mode" }),
                  mode["type"] as? String == "select",
                  mode["currentValue"] as? String == qualification.approvalMode,
                  let choices = mode["options"] as? [[String: Any]],
                  choices.contains(where: { $0["value"] as? String == qualification.approvalMode }) else { throw Failure.qualifiedModeUnavailable }
            guard await currentLease() else { throw Failure.invalidated }
            try requireCurrent()
            response.acknowledgeDurableConsumption()
        }
        guard await currentLease() else { throw Failure.invalidated }
        try requireCurrent()
        status = .ready
        launchProtocolRejections()
        scheduleDisplay()
        onChange()
    }

    public func send(text: String) async throws -> ACPV2SubmissionRecord {
        try requireCurrent()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidInput }
        guard presentation.canSend, let runner, let upstreamID else { throw Failure.busy }
        awaitingSubmission = true
        lastCompletion = nil
        onChange()
        do {
            guard await currentLease() else { throw Failure.invalidated }
            try requireCurrent()
            let record = try await runner.submit(id: UUID(), row: .user(id: UUID(), text: text, attachments: []),
                params: .init(sessionId: upstreamID, prompt: [.text(text)]))
            try requireCurrent()
            switch record.recovery {
            case .accepted: break // Acceptance does not finish foreground work.
            case .rpcFailure: awaitingSubmission = false
            case .uncertain, .uninterpretable: fail("The prompt handoff could not be confirmed")
            }
            scheduleDisplay()
            onChange()
            return record
        } catch {
            if active { fail("The prompt handoff could not be confirmed") }
            throw error
        }
    }

    private func event(_ event: ACPV2SessionRunner.Event) {
        guard isActive() else { return }
        switch event {
        case .completion(let completion):
            lastCompletion = completion
            awaitingSubmission = false
        case .interaction(let event): permissionEvent(event)
        }
        scheduleDisplay()
        onChange()
    }

    public func decide(itemID: UUID, optionID: String?) async throws -> ACPV2ResponseOwner.Receipt {
        try requireCurrent()
        guard status == .ready, let index = permissions.firstIndex(where: { $0.id == itemID }),
              permissions[index].installationID == installationID,
              permissions[index].phase == .awaitingDecision,
              let handle = permissionHandles[itemID], let runner else { throw Failure.unavailable }
        if let optionID {
            guard permissions[index].permission.options.contains(where: { $0.optionID.utf8.elementsEqual(optionID.utf8) }) else { throw Failure.invalidInput }
        }
        permissions[index].phase = .sending
        onChange()
        do {
            guard await currentLease() else { withdraw()
            throw Failure.invalidated }
            try requireCurrent()
            guard permissionHandles[itemID] != nil,
                  permissions.first(where: { $0.id == itemID })?.phase == .sending else { throw Failure.unavailable }
            let receipt = try await runner.decide(handle, decision: optionID.map { .selectPermission(optionID: $0) } ?? .cancelPermission)
            try requireCurrent()
            retirePermission(handle.record, phase: Self.permissionPhase(receipt))
            onChange()
            return receipt
        } catch {
            if active, permissions.first(where: { $0.id == itemID })?.phase == .sending {
                retirePermission(handle.record, phase: .uncertain)
                onChange()
            }
            throw error
        }
    }

    private static func permissionPhase(_ receipt: ACPV2ResponseOwner.Receipt) -> ACPV2PreviewPermissionItem.Phase {
        if case .uncertain = receipt.value.fact { return .uncertain }
        return .unavailable
    }
    private func retirePermission(_ record: ACPV2InboundLedgerRecord, phase: ACPV2PreviewPermissionItem.Phase) {
        guard let id = permissionOrigins[PermissionOrigin(record)],
              let index = permissions.firstIndex(where: { $0.id == id }) else { return }
        permissionHandles.removeValue(forKey: id)
        permissions[index].phase = phase
    }
    private func permissionEvent(_ event: ACPV2RequestDecisionCoordinator.Event) {
        switch event {
        case .offer(let handle):
            guard case .permission(let permission) = handle.request.classification else { return }
            let origin = PermissionOrigin(handle.record)
            guard permissionOrigins[origin] == nil else { return }
            let id = UUID()
            permissionOrigins[origin] = id
            permissionHandles[id] = handle
            permissions.append(.init(id: id, installationID: installationID, ledgerOrdinal: handle.record.ordinal,
                permission: permission, phase: .awaitingDecision))
            permissions.sort { $0.ledgerOrdinal < $1.ledgerOrdinal }
        case .withdrawn(let handle): retirePermission(handle.record, phase: .unavailable)
        case .unavailable(let record, _): retirePermission(record, phase: .unavailable)
        case .response(let handle, let result):
            let phase: ACPV2PreviewPermissionItem.Phase
            switch result {
            case .success(let receipt): phase = Self.permissionPhase(receipt)
            case .failure: phase = .uncertain
            }
            retirePermission(handle.record, phase: phase)
        case .rejection(let handle):
            pendingRejections[PermissionOrigin(handle.record)] = handle
            launchProtocolRejections()
        case .diagnostic, .urlChanged: break
        }
    }

    private func launchProtocolRejections() {
        guard active, status == .ready, let runner else { return }
        for (origin, handle) in pendingRejections where rejectionWorkers[origin] == nil {
            let code: ACPV2InteractiveRequest.ProtocolError
            switch handle.request.classification {
            case .unsupported(.unknownMethod), .unsupported(.unadvertisedMethod): code = .methodNotFound
            default: code = .invalidParams
            }
            rejectionWorkers[origin] = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.rejectionWorkers.removeValue(forKey: origin)
                    self.pendingRejections.removeValue(forKey: origin)
                }
                guard await self.currentLease(), self.isActive(), !Task.isCancelled else { return }
                _ = try? await runner.decide(handle, decision: .reject(code))
            }
        }
    }

    private func observed(_ value: ACPV2SessionRunner.Status) {
        guard active else { return }
        switch value {
        case .idle, .starting, .ready: return
        case .failed: fail("Preview observation failed")
        default: withdraw()
        }
    }

    public func end(deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(15))) async throws {
        if let cleanup {
            let closed = await waitForCleanup(cleanup, until: deadline)
            guard closed else { throw Failure.cleanupUnavailable }
            return
        }
        status = .ending
        stopActions()
        onChange()
        let authority = cleanupAuthority
        let client = client
        let worker = Task { [weak self] in
            let closed = await client.endFreshV2Preview(authorize: { [weak self] in
                guard let self else { return false }
                return await self.authorizeCleanup()
            }, handoffAuthorized: { authority.valid })
            self?.cleanupFinished(closed)
            return closed
        }
        cleanup = worker
        let closed = await waitForCleanup(worker, until: deadline)
        if !closed, status == .ending { status = .interrupted }
        await flushDisplay()
        onChange()
        guard closed else { throw Failure.cleanupUnavailable }
    }

    private final class CleanupWaiter: Sendable {
        private let continuation: Mutex<CheckedContinuation<Bool, Never>?>
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = Mutex(continuation) }
        func finish(_ result: Bool) {
            let waiter = continuation.withLock { value in defer { value = nil }
            return value }
            waiter?.resume(returning: result)
        }
    }
    private func waitForCleanup(_ worker: Task<Bool, Never>, until deadline: ContinuousClock.Instant) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = CleanupWaiter(continuation)
            let timeout = Task {
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                waiter.finish(false)
            }
            Task {
                waiter.finish(await worker.value)
                timeout.cancel()
            }
        }
    }
    private func cleanupFinished(_ closed: Bool) {
        guard cleanupAuthority.valid, isCurrent() else { return }
        status = closed ? .ended : .interrupted
        scheduleDisplay()
        onChange()
    }

    private func authorizeCleanup() async -> Bool {
        guard cleanupAuthority.valid, isCurrent() else { return false }
        let valid = await currentLease()
        return valid && cleanupAuthority.valid && isCurrent()
    }

    public func withdraw() {
        cleanupAuthority.withdraw()
        guard active else { return }
        status = .interrupted
        stopActions()
        scheduleDisplay()
        onChange()
        Task { await client.detach() }
    }

    private func fail(_ message: String) {
        guard active else { return }
        status = .failed(message)
        stopActions()
        scheduleDisplay()
        onChange()
        Task { await client.detach() }
    }

    private func stopActions() {
        active = false
        for index in permissions.indices {
            if permissions[index].phase == .sending { permissions[index].phase = .uncertain }
            else if permissions[index].phase == .awaitingDecision { permissions[index].phase = .unavailable }
        }
        permissionHandles.removeAll()
        for worker in rejectionWorkers.values { worker.cancel() }
        rejectionWorkers.removeAll()
        pendingRejections.removeAll()
        runner?.stop()
        monitor?.cancel()
        startupWorker?.cancel()
        finishStartup(Failure.invalidated)
        displayAuthority.withdraw()
        displayTask?.cancel()
        displayScheduler?.cancel()
        displayScheduler = nil
        displayScheduled = false
        displayAuthority = Authority()
    }

    private func finishStartup(_ error: (any Error)?) {
        startupTimeout?.cancel()
        startupTimeout = nil
        let waiter = startupWaiter
        startupWaiter = nil
        if let error { waiter?.resume(throwing: error) }
        else { waiter?.resume() }
    }

    private func isActive() -> Bool { active && isCurrent() }
    private func requireCurrent() throws {
        try Task.checkCancellation()
        guard isActive() else { throw Failure.invalidated }
    }
    private func currentLease() async -> Bool {
        guard let lease = try? await persistence.loadLease(sessionId: session.id) else { return false }
        return lease.ownerInstance.utf8.elementsEqual(fence.ownerInstance.utf8) && lease.token.utf8.elementsEqual(fence.token.utf8)
    }

    private func scheduleDisplay() {
        guard !displayScheduled else { return }
        displayScheduled = true
        displayScheduler = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.displayScheduled = false
            self.displayScheduler = nil
            self.captureDisplay()
        }
    }
    private func captureDisplay() {
        guard isCurrent(), displaySequence < Int64.max else { return }
        displaySequence += 1
        let displayStatus: ACPV2PreviewDisplaySnapshot.Status = switch status {
        case .ended: .ended
        case .failed: .failed
        case .ending, .interrupted: .interrupted
        default: .observing
        }
        guard let snapshot = try? ACPV2PreviewDisplaySnapshot(sessionId: session.id, installationID: installationID,
            sequence: displaySequence, status: displayStatus, messages: session.transcript.messages) else { return }
        let authority = displayAuthority
        let writer = displayWriter
        let fence = fence
        displayTask = Task { _ = try? await writer(snapshot, fence, { authority.valid }) }
    }
    public func flushDisplay() async {
        displayScheduler?.cancel()
        displayScheduler = nil
        displayScheduled = false
        captureDisplay()
        await displayTask?.value
    }
}
