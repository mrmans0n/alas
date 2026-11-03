import Foundation
import Synchronization
import AlasACP

public protocol ACPV2ResponseLedgerPersisting: Sendable {
    func loadV2ResponseIntentPage(stream: ACPV2InboundLedgerStream, after: ACPV2ResponseLedgerContinuation?,
        maxRecords: Int, maxBytes: Int) async throws -> ACPV2ResponseLedgerPage<ACPV2ResponseIntent>
    func registerV2ResponseIntent(id: UUID, request: ACPV2InboundLedgerRecord, in stream: ACPV2InboundLedgerStream,
        frame: Data, fence: ACPSessionLeaseFence) async throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseIntent>
    func registerV2ResponseAttempt(id: UUID, for intent: ACPV2ResponseIntent, operationKey: ACPV2ReplyOperationKey,
        fence: ACPSessionLeaseFence) async throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseAttempt>
    func retainV2ResponseObservation(id: UUID, for attempt: ACPV2ResponseAttempt, evidence: ACPV2ResponseEvidence,
        fence: ACPSessionLeaseFence) async throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseObservation>
}

extension ACPSessionPersistence: ACPV2ResponseLedgerPersisting {}

/// Orders durable registration and one attachment-bound handoff. This does not
/// atomically arbitrate a cross-process SQLite lease seizure against pipe I/O.
@MainActor
public final class ACPV2ResponseOwner {
    public enum Failure: Error, Equatable, Sendable {
        case invalidated, invalidInput, unavailable, observationLost, conflict, existingAttempt, invalidProof
        case persistence(message: String)
        /// A local transport fact whose observation could not be committed or
        /// verified. This is never a durable receipt or permission to resend.
        case outcomePersistence(attemptID: UUID, fact: ACPV2ResponseFact, message: String)
    }
    public enum ResponseAvailability: Equatable, Sendable {
        case available, unavailable, observationLost
        /// Nil means a local operation claimed the origin before its intent
        /// COMMIT. A nonnil value is historical evidence, never reply authority.
        case alreadyChosen(ACPV2ResponseIntent?)
    }

    public func inspect(request: ACPV2InboundLedgerRecord, delivery: ACPV2InboundDelivery? = nil) async throws -> ResponseAvailability {
        try requireCurrent()
        guard request.streamID == stream.id else { return .unavailable }
        if operations[request.ordinal] != nil { return .alreadyChosen(nil) }
        let reconciled = await attachment.reconcile(request, in: stream, delivery: delivery)
        try requireCurrent()
        switch reconciled {
        case .unavailable: return .unavailable
        case .observationLost: return .observationLost
        case .eligible: break
        }
        var after: ACPV2ResponseLedgerContinuation?
        repeat {
            let page: ACPV2ResponseLedgerPage<ACPV2ResponseIntent>
            do { page = try await journal.loadV2ResponseIntentPage(stream: stream, after: after, maxRecords: 128, maxBytes: 1_048_576) }
            catch { try requireCurrent()
            return .observationLost }
            try requireCurrent()
            guard !page.containsOversizedRecord, page.records.count <= 128, page.isAtEnd == (page.next == nil),
                  page.next == nil || page.next != after else { return .observationLost }
            for intent in page.records {
                guard intent.stream == stream else { return .observationLost }
                if intent.request.ordinal == request.ordinal {
                    guard responseRequestsEqual(intent.request, request) else { return .observationLost }
                    return .alreadyChosen(intent)
                }
            }
            after = page.next
        } while after != nil
        if operations[request.ordinal] != nil { return .alreadyChosen(nil) }
        return .available
    }

    public typealias Receipt = ACPV2ResponseLedgerReceipt<ACPV2ResponseObservation>
    public struct Event: Sendable {
        public let ordinal: Int64
        public let waitingCount: Int
        public let result: Result<Receipt, Failure>?
    }
    public let observations: AsyncStream<Event>
    public private(set) var isStopped = false

    private final class CallerCancellation: Sendable {
        private struct State { var cancelled = false
        var worker: Task<Void, Never>? }
        private let state = Mutex(State())
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
        var isCancelled: Bool { state.withLock { $0.cancelled } }
    }

    private final class Operation {
        let request: ACPV2InboundLedgerRecord
        let delivery: ACPV2InboundDelivery?
        let intentID: UUID
        let attemptID: UUID
        let key: ACPV2ReplyOperationKey
        let frame: Data
        let initiator: UUID
        let observationID = UUID()
        let cancellation: CallerCancellation
        var attemptRegistrationStarted = false
        var attempt: ACPV2ResponseAttempt?
        var worker: Task<Void, Never>?
        var invalidated = false
        var result: Result<Receipt, Failure>?
        var waiters: [UUID: CheckedContinuation<Receipt, Error>] = [:]

        init(request: ACPV2InboundLedgerRecord, delivery: ACPV2InboundDelivery?, intentID: UUID,
            attemptID: UUID, key: ACPV2ReplyOperationKey, frame: Data, initiator: UUID, cancellation: CallerCancellation) {
            self.request = request
            self.delivery = delivery
            self.intentID = intentID
            self.attemptID = attemptID
            self.key = key
            self.frame = frame
            self.initiator = initiator
            self.cancellation = cancellation
        }
        func matches(request: ACPV2InboundLedgerRecord, intentID: UUID, attemptID: UUID,
            key: ACPV2ReplyOperationKey, frame: Data) -> Bool {
            responseRequestsEqual(self.request, request) && self.intentID == intentID
                && self.attemptID == attemptID && self.key == key && self.frame == frame
        }
    }
    private let stream: ACPV2InboundLedgerStream
    private let fence: ACPSessionLeaseFence
    private let attachment: ACPV2ResponseAttachment
    private let journal: any ACPV2ResponseLedgerPersisting
    private let isCurrent: @MainActor () -> Bool
    private let continuation: AsyncStream<Event>.Continuation
    private var operations: [Int64: Operation] = [:]

    public init(stream: ACPV2InboundLedgerStream, fence: ACPSessionLeaseFence, attachment: ACPV2ResponseAttachment,
        journal: any ACPV2ResponseLedgerPersisting, isCurrent: @escaping @MainActor () -> Bool) throws {
        guard stream.sessionId.utf8.elementsEqual(fence.sessionId.utf8), attachment.accepts(stream) else { throw Failure.invalidInput }
        self.stream = stream
        self.fence = fence
        self.attachment = attachment
        self.journal = journal
        self.isCurrent = isCurrent
        let events = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations = events.stream
        continuation = events.continuation
    }

    public func respond(request: ACPV2InboundLedgerRecord, delivery: ACPV2InboundDelivery? = nil,
        intentID: UUID, attemptID: UUID, operationKey: ACPV2ReplyOperationKey, frame: Data) async throws -> Receipt {
        try requireCurrent()
        guard request.streamID == stream.id, request.ordinal > 0, !operationKey.rawValue.isEmpty else { throw Failure.invalidInput }
        do {
            guard let id = try request.decodeHeader().id, responseIDsEqual(id, try ACPRawReply.validateFrame(frame)) else { throw Failure.invalidInput }
        } catch { throw Failure.invalidInput }
        let caller = UUID()
        let cancellation = CallerCancellation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Receipt, Error>) in
                do {
                    try requireCurrent()
                    if let old = operations[request.ordinal] {
                        if old.matches(request: request, intentID: intentID, attemptID: attemptID, key: operationKey, frame: frame) {
                            if let result = old.result { waiter.resume(with: result.mapError { $0 as Error }) }
                            else { old.waiters[caller] = waiter
                            publish(old) }
                            return
                        }
                        guard case .success(let receipt) = old.result, receipt.value.fact == .stdio(.notWritten),
                              old.intentID == intentID, old.frame == frame, old.key != operationKey,
                              old.attemptID != attemptID, responseRequestsEqual(old.request, request) else { throw Failure.conflict }
                    }
                    let operation = Operation(request: request, delivery: delivery, intentID: intentID, attemptID: attemptID,
                        key: operationKey, frame: frame, initiator: caller, cancellation: cancellation)
                    operation.waiters[caller] = waiter
                    operations[request.ordinal] = operation
                    publish(operation)
                    let worker = Task<Void, Never> { [weak self] in await self?.run(operation) }
                    operation.worker = worker
                    cancellation.install(worker)
                } catch { waiter.resume(throwing: error) }
            }
        } onCancel: {
            // The worker has a different Task. Publish cancellation before the
            // actor hop and propagate it to the handoff worker synchronously.
            // A queued physical writer cannot depend on that actor hop.
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(ordinal: request.ordinal, caller: caller) }
        }
        try Task.checkCancellation()
        return result
    }

    /// Call on attachment or ownership invalidation to settle blocked callers
    /// promptly; a predicate alone is checked only at operation boundaries.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        for operation in operations.values where operation.result == nil {
            operation.invalidated = true
            operation.worker?.cancel()
            settle(operation, .failure(.invalidated))
        }
        continuation.finish()
    }

    private func requireCurrent(_ operation: Operation? = nil) throws {
        guard !isStopped, !Task.isCancelled, operation?.invalidated != true,
              operation?.cancellation.isCancelled != true, isCurrent(), !isStopped,
              operation?.cancellation.isCancelled != true else { throw Failure.invalidated }
    }

    private func requireEligible(_ operation: Operation) async throws {
        try requireCurrent(operation)
        let result = await attachment.reconcile(operation.request, in: stream, delivery: operation.delivery)
        try requireCurrent(operation)
        switch result {
        case .eligible: return
        case .unavailable: throw Failure.unavailable
        case .observationLost: throw Failure.observationLost
        }
    }

    private func run(_ operation: Operation) async {
        var handedOff = false
        do {
            try await requireEligible(operation)
            let intent = try await journal.registerV2ResponseIntent(id: operation.intentID, request: operation.request,
                in: stream, frame: operation.frame, fence: fence).value
            try requireCurrent(operation)
            guard intent.id == operation.intentID, intent.stream == stream, responseRequestsEqual(intent.request, operation.request),
                  intent.frame == operation.frame else { throw Failure.invalidProof }
            operation.attemptRegistrationStarted = true
            let registered = try await journal.registerV2ResponseAttempt(id: operation.attemptID, for: intent,
                operationKey: operation.key, fence: fence)
            try requireCurrent(operation)
            guard registered.value.id == operation.attemptID, registered.value.intentID == intent.id,
                  registered.value.operationKey == operation.key, registered.value.sequence > 0 else { throw Failure.invalidProof }
            guard registered.wasInserted else { throw Failure.existingAttempt }
            operation.attempt = registered.value
            try await requireEligible(operation)
            handedOff = true
            let evidence: ACPV2ResponseEvidence
            do { evidence = try await attachment.handoff(intent: intent, attempt: registered.value, delivery: operation.delivery) }
            catch { evidence = .uncertain(message: String(describing: error)) }
            // A cancelled initiator may still yield a valid late historical fact.
            // Ownership loss must never bypass the persisted lease fence.
            guard !isStopped, isCurrent() else { throw Failure.invalidated }
            let receipt: Receipt
            do {
                receipt = try await journal.retainV2ResponseObservation(id: operation.observationID, for: registered.value,
                    evidence: evidence, fence: fence)
                guard receipt.value.id == operation.observationID, receipt.value.attemptID == registered.value.id,
                      receipt.value.sequence > 0, receipt.value.fact == Self.fact(evidence) else { throw Failure.invalidProof }
            } catch {
                throw Failure.outcomePersistence(attemptID: registered.value.id, fact: Self.fact(evidence), message: String(describing: error))
            }
            try requireCurrent(operation)
            settle(operation, .success(receipt))
        } catch {
            let failure = (error as? Failure) ?? .persistence(message: String(describing: error))
            // Registration already commits a conservative crash window. Do not
            // manufacture notWritten when local cancellation prevented handoff.
            if !handedOff, let attempt = operation.attempt, !isStopped, isCurrent(), failure != .existingAttempt {
                _ = try? await journal.retainV2ResponseObservation(id: operation.observationID, for: attempt,
                    evidence: .uncertain(message: String(describing: failure)), fence: fence)
            }
            settle(operation, .failure(failure))
            withdrawUnregistered(operation)
        }
        operation.worker = nil
    }

    private func cancel(ordinal: Int64, caller: UUID) {
        guard let operation = operations[ordinal], operation.result == nil else { return }
        if operation.initiator == caller {
            operation.invalidated = true
            operation.worker?.cancel()
            settle(operation, .failure(.invalidated))
            withdrawUnregistered(operation)
        } else {
            operation.waiters.removeValue(forKey: caller)?.resume(throwing: CancellationError())
            publish(operation)
        }
    }

    private func withdrawUnregistered(_ operation: Operation) {
        // A failed first reconciliation may be explicitly tried again. Once an
        // attempt call starts, its COMMIT may be unknown; keep that origin fenced.
        guard !operation.attemptRegistrationStarted, operations[operation.request.ordinal] === operation else { return }
        operations.removeValue(forKey: operation.request.ordinal)
    }

    private func settle(_ operation: Operation, _ result: Result<Receipt, Failure>) {
        guard operation.result == nil else { return }
        operation.result = result
        let waiters = operation.waiters.values
        operation.waiters.removeAll()
        for waiter in waiters { waiter.resume(with: result.mapError { $0 as Error }) }
        publish(operation)
    }
    private static func fact(_ evidence: ACPV2ResponseEvidence) -> ACPV2ResponseFact {
        switch evidence {
        case .stdio(let result): .stdio(result.status)
        case .broker(let result): .broker(result.status)
        case .uncertain(let message): .uncertain(message: message)
        }
    }

    private func publish(_ operation: Operation) {
        continuation.yield(.init(ordinal: operation.request.ordinal, waitingCount: operation.waiters.count, result: operation.result))
    }
}
