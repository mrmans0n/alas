import Foundation
import Synchronization
import AlasACP
import AlasCode
import AlasFoundation

/// One explicit choice per current inbound origin. The runtime owns persistence
/// and transport authority; these handles never authorize a direct write.
@MainActor
public final class ACPV2RequestDecisionCoordinator {
    public enum Failure: Error, Equatable, Sendable {
        case invalidated, foreignHandle, notReady, alreadyChosen, invalidDecision
        case unsupportedValidation, unavailable, observationLost
    }
    public struct Handle: Sendable {
        public let request: ACPV2InteractiveRequest
        public let record: ACPV2InboundLedgerRecord
        fileprivate let coordinatorID: UUID
        fileprivate let origin: UUID
    }
    public struct URLWorkflow: Sendable {
        public enum Consent: Sendable { case pending, accepted, declined, cancelled }
        public let elicitationID: String
        public let create: ACPV2InboundLedgerRecord
        public var consent: Consent = .pending
        public var completion: ACPV2InboundLedgerRecord?
        public var response: Result<ACPV2ResponseOwner.Receipt, any Error>?
    }
    public var urlWorkflows: [URLWorkflow] { workflows.values.sorted { $0.create.ordinal < $1.create.ordinal } }
    public enum Event: Sendable {
        case offer(Handle), rejection(Handle), withdrawn(Handle)
        case unavailable(ACPV2InboundLedgerRecord, ACPV2AttachmentRuntime.ResponseAvailability)
        case diagnostic(ACPV2InboundLedgerRecord, String)
        case response(Handle, Result<ACPV2ResponseOwner.Receipt, any Error>)
        case urlChanged(URLWorkflow)
    }
    @MainActor
    private final class Entry {
        let handle: Handle
        let original: ACPV2AttachmentRuntime.Request
        let source: ACPV2InboundDelivery.Source
        var availability: ACPV2AttachmentRuntime.ResponseAvailability?
        var frame: Data?
        let intentID = UUID(), attemptID = UUID()
        let operationKey = ACPV2ReplyOperationKey(rawValue: UUID().uuidString)
        var urlID: Data?
        var rejectionOnly = false
        var finished = false
        var remoteCancellation = false
        var chosen = false
        var withdrawn = false
        var inspection: Task<Void, Never>?
        var worker: Task<Void, Never>?
        var waiter: CheckedContinuation<ACPV2ResponseOwner.Receipt, any Error>?
        init(handle: Handle, original: ACPV2AttachmentRuntime.Request, source: ACPV2InboundDelivery.Source) {
            self.handle = handle
            self.original = original
            self.source = source
        }
    }
    /// Cancellation invalidates the initiating worker synchronously, even when
    /// the caller cancels from inside a MainActor observer.
    private final class Cancellation: Sendable {
        private struct State { var cancelled = false
        var worker: Task<Void, Never>? }
        private let state = Mutex(State())
        func install(_ worker: Task<Void, Never>) {
            let cancelled = state.withLock { value in value.worker = worker
            return value.cancelled }
            if cancelled { worker.cancel() }
        }
        func cancel() { state.withLock { value in value.cancelled = true
        return value.worker }?.cancel() }
        var isCancelled: Bool { state.withLock { $0.cancelled } }
    }
    private let id = UUID()
    private let upstreamSessionId: String
    private let support: ACPV2InteractiveRequest.Support
    private let validator: ACPV2InteractiveRequest.FormValidator
    private let isCurrent: @MainActor () -> Bool
    private let onEvent: @MainActor (Event) -> Void
    private weak var runtime: ACPV2AttachmentRuntime?
    private var attachmentID: UUID?
    private var active = true
    private var entries: [UUID: Entry] = [:]
    private var workflows: [Data: URLWorkflow] = [:]
    private var qualifiedCancellations: [(Data, ACPV2InboundDelivery.Source)] = []

    public init(upstreamSessionId: String, support: ACPV2InteractiveRequest.Support,
        formValidator: @escaping ACPV2InteractiveRequest.FormValidator = { ACPV2FormAnswerValidator.validate(schema: $0, content: $1) },
        isCurrent: @escaping @MainActor () -> Bool, onEvent: @escaping @MainActor (Event) -> Void) {
        self.upstreamSessionId = upstreamSessionId
        self.support = support
        validator = formValidator
        self.isCurrent = isCurrent
        self.onEvent = onEvent
    }
    public func bind(to runtime: ACPV2AttachmentRuntime) throws {
        guard active, attachmentID == nil, runtime.status == .idle,
              runtime.state.context.sessionID.utf8.elementsEqual(upstreamSessionId.utf8) else { throw Failure.invalidated }
        self.runtime = runtime
        attachmentID = runtime.attachmentID
        try requireCurrent()
    }
    private func current() -> Bool {
        active && runtime?.attachmentID == attachmentID && isCurrent() && active && runtime?.attachmentID == attachmentID
    }
    private func requireCurrent() throws {
        try Task.checkCancellation()
        guard current() else { stop()
        throw Failure.invalidated }
    }
    public func stop() {
        guard active else { return }
        active = false
        // Withdraw physical handoff gates before invoking any external observer.
        runtime?.stop()
        for entry in entries.values {
            entry.inspection?.cancel()
            entry.worker?.cancel()
            let waiter = entry.waiter
            entry.waiter = nil
            waiter?.resume(throwing: Failure.invalidated)
            if !entry.withdrawn { entry.withdrawn = true
            onEvent(.withdrawn(entry.handle)) }
        }
    }
    public func runtimeDidChange(_ event: ACPV2AttachmentRuntime.LifecycleEvent) {
        guard active, event.attachmentID == attachmentID else { return }
        switch event.status {
        case .ready:
            guard current() else { stop()
            return }
            for entry in entries.values where entry.remoteCancellation { launch(entry) }
        case .idle, .restoring: break
        default: stop()
        }
    }
    public func receive(_ event: ACPV2AttachmentRuntime.InboundEvent) throws {
        try requireCurrent()
        guard event.attachmentID == attachmentID, event.record.streamID == runtime?.inboundStream?.id else { throw Failure.invalidated }
        guard !event.isDiagnostic else { onEvent(.diagnostic(event.record, "Diagnostic capture"))
        return }
        let typed: ACPV2InteractiveRequest
        do { typed = try .decode(frame: event.record.frame, upstreamSessionId: upstreamSessionId, support: support) }
        catch { onEvent(.diagnostic(event.record, String(describing: error)))
        return }
        switch typed.classification {
        case .cancelRequest(let requestID):
            cancel(requestID, event: event)
            try requireCurrent()
            return
        case .elicitationComplete(let elicitationID):
            complete(elicitationID, event: event)
            try requireCurrent()
            return
        default: break
        }
        guard let original = event.request else { return }
        guard !entries.values.contains(where: { $0.handle.record.streamID == event.record.streamID && $0.handle.record.ordinal == event.record.ordinal }) else { return }
        let origin = UUID()
        let handle = Handle(request: typed, record: event.record, coordinatorID: id, origin: origin)
        let entry = Entry(handle: handle, original: original, source: event.currentSource)
        entries[origin] = entry
        if case .url(let request) = typed.classification {
            let key = Data(request.elicitationID.utf8)
            if workflows[key] != nil {
                entry.rejectionOnly = true
                onEvent(.diagnostic(event.record, "Elicitation ID already used on this attachment"))
            } else {
                entry.urlID = key
                workflows[key] = .init(elicitationID: request.elicitationID, create: event.record)
                onEvent(.urlChanged(workflows[key]!))
            }
            try requireCurrent()
        }
        let peers = entries.values.filter {
            $0 !== entry && !$0.finished && !$0.withdrawn && Self.idKey($0.handle.request.header.id) == Self.idKey(typed.header.id)
        }
        if !peers.isEmpty {
            entry.withdrawn = true
            for peer in peers { peer.withdrawn = true
            onEvent(.withdrawn(peer.handle)) }
            onEvent(.diagnostic(event.record, "Ambiguous simultaneous inbound request ID"))
            return
        }
        for (key, source) in qualifiedCancellations where key == Self.idKey(typed.header.id) {
            if Self.follows(source, entry.source) { claimCancellation(entry)
            break }
        }
        entry.inspection = Task { [weak self, weak entry] in
            guard let self, let entry, let runtime = self.runtime else { return }
            do {
                let availability = try await runtime.inspectResponse(to: original)
                try self.requireCurrent()
                guard !entry.withdrawn || entry.remoteCancellation else { return }
                entry.availability = availability
                guard availability == .available else {
                    entry.withdrawn = true
                    self.onEvent(.unavailable(entry.handle.record, availability))
                    return
                }
                if entry.remoteCancellation { self.launch(entry)
                return }
                if entry.rejectionOnly { self.onEvent(.rejection(handle))
                try self.requireCurrent()
                return }
                switch typed.classification {
                case .permission, .form, .url: self.onEvent(.offer(handle))
                case .unsupported, .malformed: self.onEvent(.rejection(handle))
                default: self.onEvent(.diagnostic(event.record, "Notification cannot be answered"))
                }
                try self.requireCurrent()
            } catch {
                guard self.active, !entry.withdrawn else { return }
                entry.withdrawn = true
                self.onEvent(.unavailable(entry.handle.record, .observationLost))
            }
        }
    }
    private func launch(_ entry: Entry, cancellation: Cancellation? = nil) {
        guard current() else { stop()
        return }
        guard runtime?.status == .ready, entry.chosen, !entry.finished,
              entry.availability == .available, entry.worker == nil, let frame = entry.frame else { return }
        let worker = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            let result: Result<ACPV2ResponseOwner.Receipt, any Error>
            do {
                try Task.checkCancellation()
                try self.requireCurrent()
                guard let runtime = self.runtime else { throw Failure.invalidated }
                let receipt = try await runtime.respond(to: entry.original, intentID: entry.intentID, attemptID: entry.attemptID,
                    operationKey: entry.operationKey, frame: frame)
                try self.requireCurrent()
                guard cancellation?.isCancelled != true else { throw CancellationError() }
                result = .success(receipt)
            } catch { result = .failure(error) }
            guard self.active else { return }
            entry.finished = true
            let waiter = entry.waiter
            entry.waiter = nil
            waiter?.resume(with: result)
            if let key = entry.urlID {
                self.workflows[key]?.response = result
                if let workflow = self.workflows[key] { self.onEvent(.urlChanged(workflow)) }
            }
            guard self.current() else { self.stop()
            return }
            self.onEvent(.response(entry.handle, result))
        }
        entry.worker = worker
        cancellation?.install(worker)
    }
    private static func idKey(_ id: JSONRPCID?) -> Data? {
        switch id {
        case .number(let value): Data("n\(value)".utf8)
        case .string(let value): Data(("s" + value).utf8)
        case nil: nil
        }
    }
    /// Control provenance follows the request in the same broker generation.
    private static func follows(_ control: ACPV2InboundDelivery.Source, _ origin: ACPV2InboundDelivery.Source) -> Bool {
        guard case .broker(let a, _) = control, case .broker(let b, _) = origin else { return false }
        return a.brokerID.rawValue.utf8.elementsEqual(b.brokerID.rawValue.utf8) && a.generation == b.generation && a.cursor > b.cursor
    }
    private func cancel(_ requestID: JSONRPCID, event: ACPV2AttachmentRuntime.InboundEvent) {
        guard let key = Self.idKey(requestID) else { return }
        if case .broker = event.currentSource { qualifiedCancellations.append((key, event.currentSource)) }
        let matches = entries.values.filter { entry in
            guard !entry.finished, Self.idKey(entry.handle.request.header.id) == key else { return false }
            switch (event.currentSource, entry.source) {
            case (.stdio, .stdio): return event.record.ordinal > entry.handle.record.ordinal
            default: return Self.follows(event.currentSource, entry.source)
            }
        }
        guard matches.count == 1, let entry = matches.first else {
            if matches.count > 1 { onEvent(.diagnostic(event.record, "Ambiguous cancellation target")) }
            return
        }
        if !entry.chosen { claimCancellation(entry) }
        if !entry.withdrawn { entry.withdrawn = true
        onEvent(.withdrawn(entry.handle)) }
        launch(entry)
    }
    private func claimCancellation(_ entry: Entry) {
        guard !entry.chosen, !entry.withdrawn else { return }
        let decision: ACPV2InteractiveRequest.Decision
        switch entry.handle.request.classification {
        case .permission: decision = .cancelPermission
        case .form, .url: decision = .cancelElicitation
        default: return
        }
        guard let frame = try? entry.handle.request.responseFrame(for: decision, formValidator: validator) else { return }
        entry.chosen = true
        entry.remoteCancellation = true
        entry.frame = frame
        updateConsent(entry, decision: decision)
    }
    private func updateConsent(_ entry: Entry, decision: ACPV2InteractiveRequest.Decision) {
        guard let key = entry.urlID else { return }
        switch decision {
        case .acceptElicitation: workflows[key]?.consent = .accepted
        case .declineElicitation: workflows[key]?.consent = .declined
        case .cancelElicitation: workflows[key]?.consent = .cancelled
        default: break
        }
        if let workflow = workflows[key] { onEvent(.urlChanged(workflow)) }
    }
    private func complete(_ elicitationID: String, event: ACPV2AttachmentRuntime.InboundEvent) {
        let key = Data(elicitationID.utf8)
        guard var workflow = workflows[key], workflow.completion == nil,
              let entry = entries.values.first(where: { $0.urlID == key }) else { return }
        switch (event.currentSource, entry.source) {
        case (.stdio, .stdio): guard event.record.ordinal > workflow.create.ordinal else { return }
        default: guard Self.follows(event.currentSource, entry.source) else { return }
        }
        workflow.completion = event.record
        workflows[key] = workflow
        onEvent(.urlChanged(workflow))
    }

    public func decide(_ handle: Handle, decision: ACPV2InteractiveRequest.Decision) async throws -> ACPV2ResponseOwner.Receipt {
        try requireCurrent()
        guard handle.coordinatorID == id, let entry = entries[handle.origin] else { throw Failure.foreignHandle }
        guard !entry.chosen else { throw Failure.alreadyChosen }
        guard !entry.withdrawn, entry.availability == .available else { throw Failure.unavailable }
        guard runtime?.status == .ready else { throw Failure.notReady }
        if entry.rejectionOnly { guard case .reject = decision else { throw Failure.invalidDecision } }
        let frame = try handle.request.responseFrame(for: decision, formValidator: validator)
        try requireCurrent()
        guard !entry.chosen, !entry.withdrawn else { throw Failure.alreadyChosen }
        guard runtime?.status == .ready else { throw Failure.notReady }
        entry.chosen = true
        entry.frame = frame
        updateConsent(entry, decision: decision)
        try requireCurrent()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                entry.waiter = continuation
                self.launch(entry, cancellation: cancellation)
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self, weak entry] in
                guard let self, let entry, let waiter = entry.waiter else { return }
                entry.waiter = nil
                waiter.resume(throwing: CancellationError())
                if self.active { self.onEvent(.withdrawn(handle)) }
            }
        }
    }
}
