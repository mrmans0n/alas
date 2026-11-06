import Foundation
import Synchronization
import AlasACP
import AlasCode
import AlasPlatform

/// Explicit fresh stdio or broker installation. The embedding owner controls the lease
/// and transport lifetime and must signal ownership replacement synchronously.
@MainActor
public final class ACPV2SessionRunner {
    public enum Failure: Error, Equatable, Sendable { case notReady, busy, invalidInput, invalidated }
    public enum Status: Equatable, Sendable {
        case idle, starting, ready, replacementRequired, observationLost, stopped, ownershipLost
        case failed(message: String)
    }
    public enum Event: Sendable {
        case interaction(ACPV2RequestDecisionCoordinator.Event)
        case completion(ACPSessionLifecycle.ForegroundCompletion)
    }
    public struct InteractionHandlers {
        public let form: (@MainActor (ACPV2RequestDecisionCoordinator.Handle) -> Void)?
        public let url: (@MainActor (ACPV2RequestDecisionCoordinator.Handle) -> Void)?
        public let validator: ACPV2InteractiveRequest.FormValidator
        public init(form: (@MainActor (ACPV2RequestDecisionCoordinator.Handle) -> Void)? = nil,
            url: (@MainActor (ACPV2RequestDecisionCoordinator.Handle) -> Void)? = nil,
            validator: @escaping ACPV2InteractiveRequest.FormValidator = { ACPV2FormAnswerValidator.validate(schema: $0, content: $1) }) {
            self.form = form
            self.url = url
            self.validator = validator
        }
        var support: ACPV2InteractiveRequest.Support {
            .init(elicitation: form != nil || url != nil, form: form != nil, url: url != nil)
        }
    }
    public private(set) var status: Status = .idle
    public let observations: AsyncStream<Status>
    private let continuation: AsyncStream<Status>.Continuation
    private let session: ACPSession
    private let client: ACPStdioClient?
    private let brokerClient: ACPBrokerClient?
    private let brokerIntake: ACPV2OrderedIntake?
    private var attachment: ACPV2SessionBootstrap.Attachment?
    private let installationID = UUID()
    private var brokerIdentity: ACPBrokerDurableState?
    private var bufferedBrokerStates: [ACPBrokerDurableState] = []
    private var brokerControlTask: Task<Void, Never>?
    private var brokerMirrorTask: Task<Void, Never>?
    private let persistence: ACPSessionPersistence
    private let fence: ACPSessionLeaseFence
    private let info: ACPImplementationInfo
    private let interactions: InteractionHandlers
    private let journals: ACPV2AttachmentRuntime.Journals?
    private let isCurrent: @MainActor () -> Bool
    private let onEvent: @MainActor (Event) -> Void
    private final class Cancellation: Sendable {
        private struct State { var cancelled = false
        var worker: Task<Void, Never>? }
        private let state = Mutex(State())
        var isCancelled: Bool { state.withLock { $0.cancelled } }
        func install(_ worker: Task<Void, Never>) {
            let cancelled = state.withLock { value in value.worker = worker
            return value.cancelled }
            if cancelled { worker.cancel() }
        }
        func cancel() {
            let worker = state.withLock { value in value.cancelled = true
            return value.worker }
            worker?.cancel()
        }
    }
    private struct Operation {
        let token: Cancellation
        let abort: @MainActor (any Error) -> Void
    }
    private var operations: [UUID: Operation] = [:]
    private var submissionIDs = Set<UUID>()
    private var terminating = false
    private var terminalInteractions: [ACPV2RequestDecisionCoordinator.Event] = []
    private var active = true
    private var submitting = false
    private var upstreamID: String?
    private var bootstrap: ACPV2SessionBootstrap?
    private var runtime: ACPV2AttachmentRuntime?
    private var projection: ACPV2SessionProjection?
    private var decisions: ACPV2RequestDecisionCoordinator?

    public convenience init(session: ACPSession, client: ACPStdioClient,
        persistence: ACPSessionPersistence, fence: ACPSessionLeaseFence,
        info: ACPImplementationInfo, interactions: InteractionHandlers = .init(),
        journals: ACPV2AttachmentRuntime.Journals? = nil,
        isCurrent: @escaping @MainActor () -> Bool,
        onEvent: @escaping @MainActor (Event) -> Void) throws {
        try self.init(session: session, client: client, brokerClient: nil, brokerIntake: nil,
            persistence: persistence, fence: fence, info: info, interactions: interactions,
            journals: journals, isCurrent: isCurrent, onEvent: onEvent)
    }

    public static func makeBroker(session: ACPSession, client: ACPBrokerClient,
        persistence: ACPSessionPersistence, fence: ACPSessionLeaseFence,
        info: ACPImplementationInfo, interactions: InteractionHandlers = .init(),
        journals: ACPV2AttachmentRuntime.Journals? = nil,
        isCurrent: @escaping @MainActor () -> Bool,
        onEvent: @escaping @MainActor (Event) -> Void) async throws -> ACPV2SessionRunner {
        guard session.id.utf8.elementsEqual(fence.sessionId.utf8), info.name == "alas", !info.version.isEmpty else { throw Failure.invalidInput }
        try session.validateFreshV2ProjectionDestination()
        let intake = try await client.claimV2OrderedIntake()
        return try .init(session: session, client: nil, brokerClient: client, brokerIntake: intake,
            persistence: persistence, fence: fence, info: info, interactions: interactions,
            journals: journals, isCurrent: isCurrent, onEvent: onEvent)
    }

    private init(session: ACPSession, client: ACPStdioClient?, brokerClient: ACPBrokerClient?, brokerIntake: ACPV2OrderedIntake?,
        persistence: ACPSessionPersistence, fence: ACPSessionLeaseFence,
        info: ACPImplementationInfo, interactions: InteractionHandlers = .init(),
        journals: ACPV2AttachmentRuntime.Journals? = nil,
        isCurrent: @escaping @MainActor () -> Bool,
        onEvent: @escaping @MainActor (Event) -> Void) throws {
        guard session.id.utf8.elementsEqual(fence.sessionId.utf8), info.name == "alas", !info.version.isEmpty else { throw Failure.invalidInput }
        try session.validateFreshV2ProjectionDestination()
        self.session = session
        self.client = client
        self.brokerClient = brokerClient
        self.brokerIntake = brokerIntake
        self.persistence = persistence
        self.fence = fence
        self.info = info
        self.interactions = interactions
        self.journals = journals
        self.isCurrent = isCurrent
        self.onEvent = onEvent
        let stream = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations = stream.stream
        continuation = stream.continuation
        if let client {
            let intake = try client.claimV2OrderedIntake()
            attachment = try .init(stdioClient: client, orderedIntake: intake)
        }
    }

    public func start(params: ACPV2SessionNewParams, deadline: ContinuousClock.Instant) async throws -> ACPV2SessionNewResult {
        guard status == .idle else { throw Failure.invalidated }
        try requireCurrent()
        setStatus(.starting)
        do { return try await perform { try await self.startBody(params: params, deadline: deadline) } }
        catch { if active { terminate(.failed(message: String(describing: error))) }
        throw error }
    }

    private func startBody(params: ACPV2SessionNewParams, deadline: ContinuousClock.Instant) async throws -> ACPV2SessionNewResult {
        do {
            if let brokerClient, let brokerIntake {
                brokerControlTask = Task { [weak self] in
                    for await control in brokerIntake.controls { self?.brokerControl(control) }
                }
                let opened = try await brokerClient.start()
                try requireCurrent()
                let attachment = try await ACPV2SessionBootstrap.Attachment(brokerClient: brokerClient, opened: opened, orderedIntake: brokerIntake)
                let identity = ACPBrokerDurableState(brokerId: opened.snapshot.metadata.brokerId,
                    generation: opened.snapshot.metadata.generation, acknowledgedCursor: .init(rawValue: 0), wireContext: .rawV2)
                guard try await persistence.bindV2FreshBroker(state: identity, fence: fence) else { throw Failure.invalidated }
                try requireCurrent()
                self.attachment = attachment
                brokerIdentity = identity
                let buffered = bufferedBrokerStates
                bufferedBrokerStates.removeAll()
                for state in buffered { enqueueBrokerMirror(state) }
            }
            guard let attachment else { throw Failure.invalidInput }
            let bootstrap = try ACPV2SessionBootstrap(attachment: attachment, fence: fence, persistence: persistence,
                info: info, deadline: deadline, journals: journals, isCurrent: { [weak self] in self?.current() == true },
                onRequest: { _ in }, onCanonicalChange: { [weak self] in try self?.canonical($0) },
                onInbound: { [weak self] event in
                    guard let self else { throw Failure.invalidated }
                    try self.requireCurrent()
                    try self.decisions?.receive(event)
                    try self.requireCurrent()
                }, onLifecycleChange: { [weak self] in self?.lifecycle($0) },
                interactionSupport: interactions.support, onInstalling: { [weak self] in try self?.install($0) })
            self.bootstrap = bootstrap
            try client?.start()
            let initialized = try await bootstrap.initialize(operationKey: brokerClient == nil ? nil : operationKey("initialize"))
            try requireCurrent()
            guard case .v2 = initialized.value else { terminate(.replacementRequired)
            throw Failure.invalidated }
            let installed = try await bootstrap.createSession(params, operationKey: brokerClient == nil ? nil : operationKey("session-new"))
            try requireCurrent()
            setStatus(.ready)
            return installed.result
        } catch {
            if active { terminate(.failed(message: String(describing: error))) }
            throw error
        }
    }

    public func submit(id: UUID, row: ACPMessage, params: ACPSessionPromptParams) async throws -> ACPV2SubmissionRecord {
        try requireReady()
        guard !submitting else { throw Failure.busy }
        guard let upstreamID, params.sessionId.utf8.elementsEqual(upstreamID.utf8),
              case .user(let rowID, nil, _, _, _, _) = row,
              !submissionIDs.contains(id), !session.transcript.messages.contains(where: { $0.stableId == row.stableId }) else { throw Failure.invalidInput }
        submitting = true
        submissionIDs.insert(id)
        defer { submitting = false }
        guard let projection, let runtime else { throw Failure.invalidated }
        do {
            return try await perform {
                try projection.registerOptimisticRow(row)
                try self.requireCurrent()
                return try await runtime.submit(id: id, localRowID: rowID, params: params,
                    operationKey: self.brokerClient == nil ? nil : .init(rawValue: self.operationKey("prompt:" + id.uuidString)))
            }
        } catch {
            if !current() { terminate(.ownershipLost) }
            throw error
        }
    }

    public func decide(_ handle: ACPV2RequestDecisionCoordinator.Handle,
        decision: ACPV2InteractiveRequest.Decision) async throws -> ACPV2ResponseOwner.Receipt {
        try requireReady()
        guard let decisions else { throw Failure.invalidated }
        return try await perform { try await decisions.decide(handle, decision: decision) }
    }

    public func stop() { terminate(.stopped) }
    public func invalidateOwnership() { terminate(.ownershipLost) }

    private func current() -> Bool {
        guard active, isCurrent(), active else { return false }
        if brokerIntake?.isValid == false { terminate(.observationLost)
        return false }
        return true
    }

    private func operationKey(_ suffix: String) -> String { "alas:v2:" + installationID.uuidString + ":" + suffix }

    private func brokerControl(_ control: ACPV2OrderedIntake.Control) {
        guard active else { return }
        switch control {
        case .invalidated: terminate(.observationLost)
        case .durableState(let state):
            if brokerIdentity == nil { bufferedBrokerStates.append(state) }
            else { enqueueBrokerMirror(state) }
        }
    }

    private func enqueueBrokerMirror(_ state: ACPBrokerDurableState) {
        let previous = brokerMirrorTask
        brokerMirrorTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.current() else { return }
            do {
                guard let identity = self.brokerIdentity,
                      state.brokerId.rawValue.utf8.elementsEqual(identity.brokerId.rawValue.utf8),
                      state.generation == identity.generation, state.wireContext == .rawV2 else { throw Failure.invalidated }
                guard try await self.persistence.updateACPBrokerAcknowledgedCursor(sessionId: self.session.id, state: state, fence: self.fence) else { throw Failure.invalidated }
                try self.requireCurrent()
            } catch { self.terminate(.failed(message: String(describing: error))) }
        }
    }
    private func requireCurrent() throws {
        try Task.checkCancellation()
        guard current() else { if active { terminate(.ownershipLost) }
        throw Failure.invalidated }
    }
    private func requireReady() throws {
        try requireCurrent()
        guard status == .ready, runtime?.status == .ready else { throw Failure.notReady }
    }
    private func install(_ context: ACPV2SessionBootstrap.InstallationContext) throws {
        try requireCurrent()
        upstreamID = context.result.sessionId
        runtime = context.runtime
        projection = try ACPV2SessionProjection(session: session, upstreamSessionId: context.result.sessionId,
            connectionID: context.connectionID, isCurrent: { [weak self] in self?.current() == true }, onChange: { [weak self] notification in
                guard let self else { return }
                for completion in notification.liveCompletions {
                    guard self.current() else { return }
                    self.onEvent(.completion(completion))
                }
            })
        try requireCurrent()
        let decisions = ACPV2RequestDecisionCoordinator(upstreamSessionId: context.result.sessionId, support: interactions.support,
            formValidator: interactions.validator, isCurrent: { [weak self] in self?.current() == true },
            onEvent: { [weak self] in self?.interaction($0) })
        self.decisions = decisions
        try decisions.bind(to: context.runtime)
        try requireCurrent()
    }
    private func canonical(_ publication: ACPV2SessionUpdateOwner.CanonicalPublication) throws {
        guard active else { return }
        try requireCurrent()
        guard let projection else { throw Failure.invalidated }
        try projection.apply(publication)
        try requireCurrent()
    }
    private func interaction(_ event: ACPV2RequestDecisionCoordinator.Event) {
        if !active {
            if case .withdrawn = event, terminating { terminalInteractions.append(event) }
            return
        }
        guard current() else { terminate(.ownershipLost)
        return }
        onEvent(.interaction(event))
        guard current() else { if active { terminate(.ownershipLost) }
        return }
        if case .offer(let handle) = event {
            switch handle.request.classification {
            case .form: interactions.form?(handle)
            case .url: interactions.url?(handle)
            default: break
            }
            if !current(), active { terminate(.ownershipLost) }
        }
    }
    private func lifecycle(_ event: ACPV2AttachmentRuntime.LifecycleEvent) {
        guard active else { return }
        decisions?.runtimeDidChange(event)
        guard active else { return }
        switch event.status {
        case .idle, .restoring, .ready: break
        case .observationLost: terminate(.observationLost)
        case .stopped: terminate(.stopped)
        case .blocked(let error): terminate(.failed(message: String(describing: error)))
        }
    }
    private func setStatus(_ status: Status) { self.status = status
    continuation.yield(status) }
    private func terminate(_ status: Status) {
        guard active else { return }
        active = false
        brokerControlTask?.cancel()
        brokerMirrorTask?.cancel()
        bufferedBrokerStates.removeAll()
        terminating = true
        setStatus(status)
        let pending = Array(operations.values)
        operations.removeAll()
        for operation in pending { operation.token.cancel() }
        decisions?.stop()
        bootstrap?.stop()
        runtime?.stop()
        projection?.stop()
        for operation in pending { operation.abort(Failure.invalidated) }
        terminating = false
        let withdrawn = terminalInteractions
        terminalInteractions = []
        for event in withdrawn { onEvent(.interaction(event)) }
        continuation.finish()
    }

    private func cancelOperation(_ id: UUID) {
        guard let operation = operations.removeValue(forKey: id) else { return }
        operation.token.cancel()
        operation.abort(CancellationError())
    }

    private func perform<Value: Sendable>(_ body: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let id = UUID(), token = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try requireCurrent()
            return try await withCheckedThrowingContinuation { continuation in
                guard !token.isCancelled else { continuation.resume(throwing: CancellationError())
                return }
                operations[id] = .init(token: token, abort: { continuation.resume(throwing: $0) })
                let worker = Task {
                    do {
                        try Task.checkCancellation()
                        try self.requireCurrent()
                        let result = try await body()
                        try self.requireCurrent()
                        guard !token.isCancelled else { throw CancellationError() }
                        guard self.operations.removeValue(forKey: id) != nil else { return }
                        continuation.resume(returning: result)
                    } catch {
                        guard self.operations.removeValue(forKey: id) != nil else { return }
                        continuation.resume(throwing: error)
                    }
                }
                token.install(worker)
            }
        } onCancel: {
            // Reach the child's physical handoff gates before the actor hop.
            token.cancel()
            Task { @MainActor [weak self] in self?.cancelOperation(id) }
        }
    }
}
