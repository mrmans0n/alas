import Foundation
import Synchronization
import AlasACP
import AlasPlatform

public protocol ACPV2FreshSessionBindingPersisting: Sendable {
    func bindV2FreshSession(upstreamSessionId: String, source: ACPV2InboundLedgerSource,
        fence: ACPSessionLeaseFence) async throws -> ACPV2FreshSessionBinding
}
extension ACPSessionPersistence: ACPV2FreshSessionBindingPersisting {}

/// Fresh-session setup only. The integration supplies exclusively owned facade
/// streams and remains responsible for stopping on attachment/lease replacement.
@MainActor
public final class ACPV2SessionBootstrap {
    public enum Failure: Error, Equatable, Sendable { case unavailable, invalidated, deadlineExceeded, invalidBinding, observationLost }
    public enum Status: Equatable, Sendable {
        case idle, initializing, initialized, creating, installing, ready, replacementRequired, observationLost, stopped
        case failed(message: String), uncertain(message: String)
    }
    public struct Initialization: Sendable {
        public let value: ACPInitializationResult
        public let response: ACPResponse
    }
    public struct Installed: Sendable {
        public let result: ACPV2SessionNewResult
        public let response: ACPResponse
        public let binding: ACPV2FreshSessionBinding
        public let runtime: ACPV2AttachmentRuntime
    }
    public struct Attachment: Sendable {
        private enum Client: Sendable { case stdio(ACPStdioClient), broker(ACPBrokerClient) }
        private let client: Client
        fileprivate let claim: ACPV2BootstrapClaim
        fileprivate let runtime: ACPV2AttachmentRuntime.Attachment
        fileprivate let source: ACPV2InboundLedgerSource
        fileprivate let localSessionId: String?
        @MainActor
        public init(stdioClient: ACPStdioClient) throws {
            runtime = try .init(stdioClient: stdioClient)
            claim = try stdioClient.claimV2Bootstrap()
            source = .stdio(connectionID: stdioClient.updateConnectionID)
            client = .stdio(stdioClient)
            localSessionId = nil
        }
        @MainActor
        public init(brokerClient: ACPBrokerClient, opened: ACPBrokerOpenResult) async throws {
            runtime = try .init(brokerClient: brokerClient, opened: opened)
            claim = try await brokerClient.claimV2Bootstrap(opened: opened)
            source = .broker(id: opened.snapshot.metadata.brokerId, generation: opened.snapshot.metadata.generation)
            client = .broker(brokerClient)
            localSessionId = opened.snapshot.metadata.alasSessionId
        }
        @MainActor
        fileprivate func send(_ request: ACPV2BootstrapRequest, operationKey: String?,
            token: Cancellation) async throws -> ACPResponse {
            switch client {
            case .stdio(let client):
                return try await client.sendV2Bootstrap(request, claim: claim, operationKey: operationKey, authorize: { !token.isCancelled })
            case .broker(let client):
                return try await client.sendV2Bootstrap(request, claim: claim, operationKey: operationKey, authorize: { !token.isCancelled })
            }
        }
    }
    fileprivate final class Cancellation: Sendable {
        private let cancelled = Mutex(false)
        var isCancelled: Bool { cancelled.withLock { $0 } }
        func cancel() { cancelled.withLock { $0 = true } }
    }

    public private(set) var status: Status = .idle
    public private(set) var initialization: Initialization?
    public private(set) var initializationResponse: ACPResponse?
    public private(set) var setupResponse: ACPResponse?
    public private(set) var lastError: (any Error)?
    public private(set) var runtime: ACPV2AttachmentRuntime?
    public let observations: AsyncStream<Status>
    private let continuation: AsyncStream<Status>.Continuation
    private let attachment: Attachment
    private let fence: ACPSessionLeaseFence
    private let storePath: String
    private let bindingJournal: any ACPV2FreshSessionBindingPersisting
    private let journals: ACPV2AttachmentRuntime.Journals
    private let info: ACPImplementationInfo
    private let deadline: ContinuousClock.Instant
    private let waitUntilDeadline: @Sendable () async throws -> Void
    private let isCurrent: @MainActor () -> Bool
    private let onRequest: @MainActor (ACPV2AttachmentRuntime.Request) -> Void
    private var active = true
    private var operationID: UUID?
    private var operationToken: Cancellation?
    private var abortWaiter: ((any Error) -> Void)?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var runtimeMonitor: Task<Void, Never>?

    public init(attachment: Attachment, fence: ACPSessionLeaseFence, persistence: ACPSessionPersistence,
        info: ACPImplementationInfo = .init(name: "alas", version: "development"),
        deadline: ContinuousClock.Instant, waitUntilDeadline: (@Sendable () async throws -> Void)? = nil,
        bindingJournal: (any ACPV2FreshSessionBindingPersisting)? = nil,
        journals: ACPV2AttachmentRuntime.Journals? = nil,
        isCurrent: @escaping @MainActor () -> Bool,
        onRequest: @escaping @MainActor (ACPV2AttachmentRuntime.Request) -> Void) throws {
        guard !fence.sessionId.isEmpty, info.name == "alas", !info.version.isEmpty,
              attachment.localSessionId.map({ $0.utf8.elementsEqual(fence.sessionId.utf8) }) ?? true else { throw Failure.unavailable }
        self.attachment = attachment
        self.fence = fence
        self.info = info
        self.deadline = deadline
        self.storePath = persistence.path
        self.bindingJournal = bindingJournal ?? persistence
        self.journals = journals ?? .init(persistence: persistence)
        self.waitUntilDeadline = waitUntilDeadline ?? { try await ContinuousClock().sleep(until: deadline) }
        self.isCurrent = isCurrent
        self.onRequest = onRequest
        let stream = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations = stream.stream
        continuation = stream.continuation
    }
    deinit { attachment.claim.invalidate()
    worker?.cancel()
    timer?.cancel()
    runtimeMonitor?.cancel()
    continuation.finish() }

    public func initialize(operationKey: String? = nil) async throws -> Initialization {
        guard status == .idle else { throw Failure.unavailable }
        try requireCurrent()
        setStatus(.initializing)
        return try await perform { token in
            let response = try await self.attachment.send(.initialize(.init(info: self.info)), operationKey: operationKey, token: token)
            self.initializationResponse = response
            try self.requireCurrent(token)
            let value = try ACPInitializationResult.decode(from: response.body, requestedVersion: .v2, supportedVersions: [.v1, .v2])
            let result = Initialization(value: value, response: response)
            self.initialization = result
            try self.requireCurrent(token)
            response.acknowledgeDurableConsumption()
            try self.requireCurrent(token)
            if case .v1 = value { self.attachment.claim.invalidate()
            self.setStatus(.replacementRequired) }
            else { self.setStatus(.initialized) }
            return result
        }
    }

    public func createSession(_ params: ACPV2SessionNewParams, operationKey: String? = nil) async throws -> Installed {
        guard status == .initialized, let initialization, case .v2(let capabilities) = initialization.value else { throw Failure.unavailable }
        try params.validate(capabilities: capabilities)
        try requireCurrent()
        setStatus(.creating)
        return try await perform { token in
            let response = try await self.attachment.send(.newSession(params), operationKey: operationKey, token: token)
            self.setupResponse = response
            try self.requireCurrent(token)
            let result = try ACPV2SessionNewResult.decode(response.body)
            let binding = try await self.bindingJournal.bindV2FreshSession(upstreamSessionId: result.sessionId, source: self.attachment.source, fence: self.fence)
            try self.requireCurrent(token)
            guard binding.storePath.utf8.elementsEqual(self.storePath.utf8),
                  binding.fence.sessionId.utf8.elementsEqual(self.fence.sessionId.utf8),
                  binding.fence.ownerInstance.utf8.elementsEqual(self.fence.ownerInstance.utf8),
                  binding.fence.token.utf8.elementsEqual(self.fence.token.utf8),
                  binding.sessionId.utf8.elementsEqual(self.fence.sessionId.utf8),
                  binding.upstreamSessionId.utf8.elementsEqual(result.sessionId.utf8), binding.source == self.attachment.source else { throw Failure.invalidBinding }
            response.acknowledgeDurableConsumption()
            try self.requireCurrent(token)
            self.setStatus(.installing)
            let runtime = try ACPV2AttachmentRuntime(sessionId: self.fence.sessionId, upstreamSessionId: result.sessionId,
                attachment: self.attachment.runtime, fence: self.fence, journals: self.journals,
                isCurrent: { [weak self] in self?.current() == true }, onRequest: self.onRequest)
            self.runtime = runtime
            try runtime.establishFreshSessionDefault()
            guard runtime.start() else { throw Failure.unavailable }
            if runtime.status != .ready {
                for await _ in runtime.observations {
                    try self.requireCurrent(token)
                    if runtime.status == .ready { break }
                    if runtime.status != .restoring { throw Failure.unavailable }
                }
            }
            try self.requireCurrent(token)
            guard runtime.status == .ready else { throw Failure.unavailable }
            self.setStatus(.ready)
            self.monitor(runtime)
            return Installed(result: result, response: response, binding: binding, runtime: runtime)
        }
    }

    public func stop() {
        guard active else { return }
        active = false
        attachment.claim.invalidate()
        operationToken?.cancel()
        runtime?.stop()
        runtimeMonitor?.cancel()
        setStatus(.stopped)
        abort(Failure.invalidated)
        continuation.finish()
    }
    private func current() -> Bool {
        active && operationToken?.isCancelled != true && isCurrent() && active && operationToken?.isCancelled != true
    }
    private func requireCurrent(_ token: Cancellation? = nil) throws {
        try Task.checkCancellation()
        guard token?.isCancelled != true, current(), token?.isCancelled != true else { throw Failure.invalidated }
        if status == .ready, runtime?.status != .ready {
            throw runtime?.status == .observationLost ? Failure.observationLost : Failure.invalidated
        }
        guard ContinuousClock.now < deadline || status == .ready else { throw Failure.deadlineExceeded }
    }
    private func setStatus(_ value: Status) { status = value
    continuation.yield(value) }
    private func fail(_ error: any Error) {
        guard active else { return }
        lastError = error
        let uncertain = status == .creating || status == .installing
        active = false
        attachment.claim.invalidate()
        operationToken?.cancel()
        runtime?.stop()
        let lost: Bool
        if case .notRunning? = error as? ACPClientError { lost = true }
        else { lost = (error as? Failure) == .observationLost }
        setStatus(lost ? .observationLost : (uncertain ? .uncertain(message: String(describing: error)) : .failed(message: String(describing: error))))
        continuation.finish()
    }
    private func monitor(_ runtime: ACPV2AttachmentRuntime) {
        runtimeMonitor = Task { [weak self] in
            for await _ in runtime.observations {
                guard let self, self.active else { return }
                if runtime.status != .ready { self.runtimeEnded(runtime)
                return }
            }
            self?.runtimeEnded(runtime)
        }
    }
    private func runtimeEnded(_ runtime: ACPV2AttachmentRuntime) {
        guard active else { return }
        let error: Failure = runtime.status == .observationLost ? .observationLost : .invalidated
        fail(error)
        abort(error)
    }

    private func abort(_ error: any Error) {
        let waiter = abortWaiter
        abortWaiter = nil
        operationID = nil
        worker?.cancel()
        worker = nil
        timer?.cancel()
        timer = nil
        waiter?(error)
    }
    private func perform<Value: Sendable>(_ body: @escaping @MainActor (Cancellation) async throws -> Value) async throws -> Value {
        let id = UUID(), token = Cancellation()
        return try await withTaskCancellationHandler {
            do { try Task.checkCancellation() }
            catch { self.fail(error)
            throw error }
            return try await withCheckedThrowingContinuation { continuation in
                operationID = id
                operationToken = token
                abortWaiter = { continuation.resume(throwing: $0) }
                worker = Task {
                    do {
                        try self.requireCurrent(token)
                        let result = try await body(token)
                        try self.requireCurrent(token)
                        guard self.operationID == id else { return }
                        self.abortWaiter = nil
                        self.operationID = nil
                        self.worker = nil
                        self.timer?.cancel()
                        self.timer = nil
                        continuation.resume(returning: result)
                    } catch {
                        guard self.operationID == id else { return }
                        self.fail(error)
                        self.abort(error)
                    }
                }
                timer = Task {
                    do { try await self.waitUntilDeadline() } catch { return }
                    guard !Task.isCancelled, self.operationID == id else { return }
                    token.cancel()
                    self.fail(Failure.deadlineExceeded)
                    self.abort(Failure.deadlineExceeded)
                }
            }
        } onCancel: {
            token.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id else { return }
                self.fail(CancellationError())
                self.abort(CancellationError())
            }
        }
    }
}
