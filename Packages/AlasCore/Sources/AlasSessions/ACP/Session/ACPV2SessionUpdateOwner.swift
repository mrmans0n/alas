import Foundation
import AlasACP
import AlasPlatform

/// Journal I/O used by the ordered owner. Implementations must return receipts
/// only after commit and preserve the existing writer-lease checks.
public protocol ACPV2UpdateJournalPersisting: Sendable {
    func registerV2UpdateJournal(sessionId: String, upstreamSessionId: String,
        source: ACPV2UpdateJournalSource, fence: ACPSessionLeaseFence) async throws -> ACPV2UpdateJournalStream
    func appendV2Update(_ delivery: ACPV2SessionUpdateDelivery, to stream: ACPV2UpdateJournalStream,
        fence: ACPSessionLeaseFence) async throws -> ACPV2UpdateJournalReceipt
    func loadV2UpdateJournalPage(stream: ACPV2UpdateJournalStream, after: ACPV2UpdateJournalContinuation?,
        maxRecords: Int, maxBytes: Int) async throws -> ACPV2UpdateJournalPage
}

extension ACPSessionPersistence: ACPV2UpdateJournalPersisting {}

/// One attachment's receive task and canonical model. This component does not
/// project UI rows or advance queues. Prompt dispatch is explicitly opt-in.
@MainActor
public final class ACPV2SessionUpdateOwner {
    public struct Attachment: Sendable {
        public let source: ACPV2UpdateJournalSource
        public let connectionID: UUID
        public let historicalThroughCursor: ACPBrokerEventCursor?
        fileprivate let localSessionId: String?

        /// The caller must create this only for a new direct stdio connection.
        public init(freshStdioConnectionID: UUID) {
            source = .stdio(connectionID: freshStdioConnectionID)
            connectionID = freshStdioConnectionID
            historicalThroughCursor = nil
            localSessionId = nil
        }

        /// Capture the observation boundary from this attachment's validated
        /// open result, before draining its raw delivery stream.
        public init(brokerConnectionID: UUID, opened: ACPBrokerOpenResult) throws {
            let snapshot = opened.snapshot
            guard snapshot.metadata.wireContext == .rawV2,
                  snapshot.metadata.generation.rawValue > 0,
                  Int64(exactly: snapshot.metadata.generation.rawValue) != nil,
                  Int64(exactly: snapshot.journalTail.rawValue) != nil,
                  snapshot.acknowledgedCursor <= snapshot.journalTail,
                  snapshot.turnState == .unknown("unknown"),
                  snapshot.initializeResult == nil, snapshot.remoteSessionResult == nil else {
                throw Failure.invalidAttachment
            }
            source = .broker(id: snapshot.metadata.brokerId, generation: snapshot.metadata.generation)
            connectionID = brokerConnectionID
            historicalThroughCursor = snapshot.journalTail
            localSessionId = snapshot.metadata.alasSessionId
        }
    }

    public struct SubmissionCapability: Sendable {
        public let sender: any ACPV2PromptSending
        public let journal: any ACPV2SubmissionPersisting
        public init(sender: any ACPV2PromptSending, journal: any ACPV2SubmissionPersisting) {
            self.sender = sender
            self.journal = journal
        }
    }

    public enum SubmissionFailure: Error, Equatable, Sendable {
        case unavailable, invalidRequest, duplicate, notLive, conflict, uninterpretable, missingEvidence
        case transport(String), persistence(String)
    }

    public struct SubmissionApplication: Equatable, Sendable {
        public let record: ACPV2SubmissionRecord
        public let effects: [ACPV2SessionState.Effect]
    }

    public enum Operation: Equatable, Sendable { case registration, replay, append }
    public enum Failure: Error, Equatable, Sendable {
        case invalidAttachment
        case submission(SubmissionFailure)
        case ownershipLost
        case deliveryMismatch
        case ordinalGap(expected: Int64, received: Int64)
        case journal(Operation, ACPV2UpdateJournalError)
        case persistence(Operation, message: String)
        case interpretation(ordinal: Int64, message: String)
        case sessionMismatch(ordinal: Int64, expected: String, received: String)
    }

    public enum Status: Equatable, Sendable {
        case idle, restoring, live, observationLost, stopped
        case blocked(Failure)
    }

    public struct Application: Equatable, Sendable {
        public let ordinal: Int64
        public let source: ACPSessionLifecycle.StateSource
        public let disposition: ACPV2SessionState.Reduction.Disposition
        public let effects: [ACPV2SessionState.Effect]
    }

    public struct Observation: Equatable, Sendable {
        public let revision: UInt64
        public let status: Status
        public let lastAppliedOrdinal: Int64
        public let hasKnownMissingPrefix: Bool
        public let latestSubmission: SubmissionApplication?
        public let latestApplication: Application?
    }

    public private(set) var state: ACPV2SessionState
    public private(set) var stream: ACPV2UpdateJournalStream?
    public private(set) var lastAppliedOrdinal: Int64 = 0
    public private(set) var hasKnownMissingPrefix = false
    public private(set) var status: Status = .idle
    public private(set) var latestApplication: Application?
    public private(set) var latestSubmission: SubmissionApplication?
    /// Latest-only invalidations, not a reliable effect queue. Read `state` to
    /// obtain canonical facts; slow readers may skip observation revisions.
    public let observations: AsyncStream<Observation>

    private let sessionId: String
    private let attachment: Attachment
    private let fence: ACPSessionLeaseFence
    private let submissions: SubmissionCapability?
    private var submissionTasks: [UUID: Task<ACPV2SubmissionRecord, Error>] = [:]
    private var submissionGates: [UUID: ACPV2PromptHandoffGate] = [:]
    private var submissionRegistrations: [UUID: ACPV2SubmissionRegistration] = [:]
    private let journal: any ACPV2UpdateJournalPersisting
    private let isCurrent: @MainActor () -> Bool
    private let observationContinuation: AsyncStream<Observation>.Continuation
    private var task: Task<Void, Never>?
    private var started = false
    private var revision: UInt64 = 0

    public init(sessionId: String, upstreamSessionId: String, attachment: Attachment,
        fence: ACPSessionLeaseFence, journal: any ACPV2UpdateJournalPersisting,
        submissions: SubmissionCapability? = nil,
        isCurrent: @escaping @MainActor () -> Bool) {
        self.sessionId = sessionId
        self.attachment = attachment
        self.fence = fence
        self.submissions = submissions
        self.journal = journal
        self.isCurrent = isCurrent
        state = ACPV2SessionState(context: .init(sessionID: upstreamSessionId, connectionID: attachment.connectionID))
        let updates = AsyncStream<Observation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations = updates.stream
        observationContinuation = updates.continuation
    }

    @discardableResult
    public func start(_ deliveries: AsyncStream<ACPV2SessionUpdateDelivery>) -> Bool {
        guard !started, status != .stopped else { return false }
        started = true
        task = Task { await self.run(deliveries) }
        return true
    }

    /// Invalidates synchronously, including a receipt whose COMMIT is in flight.
    public func stop() {
        guard status != .stopped else { return }
        status = .stopped
        task?.cancel()
        invalidateSubmissions()
        publish()
        observationContinuation.finish()
    }

    public func waitUntilFinished() async { await task?.value }

    private func requireCurrent() throws {
        guard !Task.isCancelled, status != .stopped else { throw Failure.ownershipLost }
        if case .blocked = status { throw Failure.ownershipLost }
        guard isCurrent() else {
            block(.ownershipLost)
            throw Failure.ownershipLost
        }
    }

    private func run(_ deliveries: AsyncStream<ACPV2SessionUpdateDelivery>) async {
        defer { observationContinuation.finish() }
        do {
            try requireCurrent()
            guard attachment.localSessionId == nil || attachment.localSessionId == sessionId,
                  fence.sessionId == sessionId else { throw Failure.invalidAttachment }
            status = .restoring
            publish()
            let registered = try await storage(.registration) {
                try await self.journal.registerV2UpdateJournal(sessionId: self.sessionId,
                    upstreamSessionId: self.state.context.sessionID, source: self.attachment.source, fence: self.fence)
            }
            try requireCurrent()
            stream = registered
            try await restoreSubmissions()
            try requireCurrent()
            var after: ACPV2UpdateJournalContinuation?
            repeat {
                let page = try await storage(.replay) {
                    try await self.journal.loadV2UpdateJournalPage(stream: registered, after: after,
                        maxRecords: 128, maxBytes: 1_048_576)
                }
                try requireCurrent()
                hasKnownMissingPrefix = page.hasKnownMissingPrefix
                for record in page.records { try apply(record, source: .snapshot) }
                after = page.next
            } while after != nil
            status = .live
            publish()
            for await delivery in deliveries {
                try requireCurrent()
                try validate(delivery)
                let receipt = try await storage(.append) {
                    try await self.journal.appendV2Update(delivery, to: registered, fence: self.fence)
                }
                try requireCurrent()
                if receipt.record.ordinal > lastAppliedOrdinal {
                    let source: ACPSessionLifecycle.StateSource
                    if let cursor = delivery.brokerProvenance?.cursor,
                       let boundary = attachment.historicalThroughCursor, cursor <= boundary { source = .snapshot }
                    else { source = .live }
                    try apply(receipt.record, source: source)
                }
                // No await or external observer callback can invalidate this
                // attachment between the authority check and explicit consume.
                try requireCurrent()
                delivery.acknowledgeDurableConsumption()
            }
            try requireCurrent()
            _ = state.loseObservation(context: state.context)
            status = .observationLost
            invalidateSubmissions()
            publish()
        } catch {
            guard status != .stopped else { return }
            if case .blocked = status { return }
            block((error as? Failure) ?? .interpretation(ordinal: lastAppliedOrdinal + 1, message: error.localizedDescription))
        }
    }

    private func validate(_ delivery: ACPV2SessionUpdateDelivery) throws {
        guard delivery.connectionID == attachment.connectionID else { throw Failure.deliveryMismatch }
        switch attachment.source {
        case .stdio:
            guard delivery.brokerProvenance == nil else { throw Failure.deliveryMismatch }
        case .broker(let id, let generation):
            guard let origin = delivery.brokerProvenance, origin.brokerID == id, origin.generation == generation,
                  origin.cursor.rawValue > 0 else { throw Failure.deliveryMismatch }
        }
    }

    private func apply(_ record: ACPV2UpdateJournalRecord, source: ACPSessionLifecycle.StateSource) throws {
        try requireCurrent()
        guard record.ordinal == lastAppliedOrdinal + 1 else {
            throw Failure.ordinalGap(expected: lastAppliedOrdinal + 1, received: record.ordinal)
        }
        let event: ACPV2SessionUpdateEnvelope
        do { event = try ACPV2SessionUpdateDelivery(frame: record.frame, connectionID: state.context.connectionID).decode() }
        catch { throw Failure.interpretation(ordinal: record.ordinal, message: error.localizedDescription) }
        guard event.sessionID == state.context.sessionID else {
            throw Failure.sessionMismatch(ordinal: record.ordinal, expected: state.context.sessionID, received: event.sessionID)
        }
        var next = state
        let result = try next.apply(event, source: source, context: state.context)
        state = next
        lastAppliedOrdinal = record.ordinal
        latestApplication = Application(ordinal: record.ordinal, source: source, disposition: result.disposition, effects: result.effects)
        publish()
    }

    private var submissionSource: ACPV2SubmissionSource {
        switch attachment.source {
        case .stdio(let connection): .stdio(connectionID: connection)
        case .broker(let id, let generation): .broker(id: id, generation: generation)
        }
    }

    private var promptEndpoint: ACPV2PromptEndpoint {
        switch attachment.source {
        case .stdio(let connection): .stdio(connectionID: connection)
        case .broker(let id, let generation): .broker(connectionID: attachment.connectionID, id: id, generation: generation)
        }
    }

    /// Explicit fresh attempts only. Restored attempts are never resent here.
    public func submit(id: UUID, localRowID: UUID, params: ACPSessionPromptParams,
        operationKey: ACPBrokerOperationKey? = nil) async throws -> ACPV2SubmissionRecord {
        try requireCurrent()
        guard status == .live else { throw Failure.submission(.notLive) }
        guard let submissions else { throw Failure.submission(.unavailable) }
        guard params.sessionId == state.context.sessionID, submissions.sender.v2PromptEndpoint == promptEndpoint else {
            throw Failure.submission(.invalidRequest)
        }
        guard submissionTasks[id] == nil else { throw Failure.submission(.duplicate) }
        let gate = ACPV2PromptHandoffGate()
        submissionGates[id] = gate
        let worker = Task { try await self.performSubmission(id: id, localRowID: localRowID, params: params, operationKey: operationKey, gate: gate, capability: submissions) }
        submissionTasks[id] = worker
        defer {
            submissionTasks.removeValue(forKey: id)
            submissionGates.removeValue(forKey: id)
            submissionRegistrations.removeValue(forKey: id)
        }
        do {
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { gate.invalidate()
            worker.cancel() }
        } catch {
            markAttemptUncertain(id)
            throw error
        }
    }

    private func requireSubmissionCurrent(id: UUID, gate: ACPV2PromptHandoffGate) throws {
        try requireCurrent()
        guard status == .live, gate.isValid, submissionGates[id] === gate else { throw Failure.ownershipLost }
    }

    private func performSubmission(id: UUID, localRowID: UUID, params: ACPSessionPromptParams,
        operationKey: ACPBrokerOperationKey?, gate: ACPV2PromptHandoffGate,
        capability: SubmissionCapability) async throws -> ACPV2SubmissionRecord {
        try requireSubmissionCurrent(id: id, gate: gate)
        let existing = try await submissionStorage { try await capability.journal.loadV2Submission(id: id) }
        try requireSubmissionCurrent(id: id, gate: gate)
        guard existing == nil else { throw Failure.submission(.duplicate) }
        let delivery: ACPRawRPCDelivery
        do {
            let response = try await capability.sender.sendV2Prompt(params, operationKey: operationKey, gate: gate) { prepared in
                try await self.prepareSubmission(id: id, localRowID: localRowID, prepared: prepared, gate: gate, journal: capability.journal)
            }
            guard let raw = response.rawDelivery else { throw terminalSubmissionFailure(.missingEvidence) }
            delivery = raw
        } catch let error as ACPRawRPCError { delivery = error.delivery }
        catch let error as ACPBrokerRawRPCError {
            guard let raw = error.rawDelivery else { throw terminalSubmissionFailure(.missingEvidence) }
            delivery = raw
        } catch let failure as Failure { throw failure }
        catch { throw Failure.submission(.transport(error.localizedDescription)) }
        try requireSubmissionCurrent(id: id, gate: gate)
        guard let registration = submissionRegistrations[id], delivery.connectionID == attachment.connectionID else {
            throw terminalSubmissionFailure(.conflict)
        }
        let receipt = try await submissionStorage {
            try await capability.journal.retainV2SubmissionOutcome(delivery, for: registration, fence: self.fence)
        }
        try requireSubmissionCurrent(id: id, gate: gate)
        try applySubmission(receipt.record)
        try requireSubmissionCurrent(id: id, gate: gate)
        delivery.acknowledgeDurableConsumption()
        return receipt.record
    }

    private func prepareSubmission(id: UUID, localRowID: UUID, prepared: ACPV2PreparedPrompt,
        gate: ACPV2PromptHandoffGate, journal: any ACPV2SubmissionPersisting) async throws {
        try requireSubmissionCurrent(id: id, gate: gate)
        guard prepared.endpoint == promptEndpoint else { throw Failure.submission(.invalidRequest) }
        let binding: ACPV2SubmissionBinding
        switch (prepared.endpoint, prepared.binding) {
        case (.stdio(let connection), .stdio(let request)): binding = .stdio(connectionID: connection, requestID: request)
        case (.broker(_, let broker, let generation), .broker(let key)): binding = .broker(id: broker, generation: generation, operationKey: key)
        default: throw Failure.submission(.invalidRequest)
        }
        let registration = try await submissionStorage {
            try await journal.registerV2Submission(id: id, sessionId: self.sessionId, upstreamSessionId: self.state.context.sessionID,
                localRowID: localRowID, binding: binding, fence: self.fence)
        }
        try requireSubmissionCurrent(id: id, gate: gate)
        var next = state
        let reduction = next.register(requestID: registration.sequence, localRowID: registration.localRowID, context: next.context)
        guard reduction.disposition == .registered || reduction.disposition == .unchanged else { throw terminalSubmissionFailure(.conflict) }
        submissionRegistrations[id] = registration
        state = next
        latestSubmission = .init(record: .init(registration: registration, outcome: nil), effects: reduction.effects)
        publish()
    }

    private func restoreSubmissions() async throws {
        guard let submissions else { return }
        guard submissions.sender.v2PromptEndpoint == promptEndpoint else { throw Failure.submission(.invalidRequest) }
        var after: ACPV2SubmissionContinuation?
        repeat {
            let page = try await submissionStorage {
                try await submissions.journal.loadV2SubmissionPage(sessionId: self.sessionId, upstreamSessionId: self.state.context.sessionID,
                    source: self.submissionSource, after: after, maxRecords: 128, maxBytes: 1_048_576)
            }
            try requireCurrent()
            for record in page.records { try applySubmission(record) }
            after = page.next
        } while after != nil
    }

    private func applySubmission(_ record: ACPV2SubmissionRecord) throws {
        try requireCurrent()
        let registration = record.registration
        guard registration.sessionId == sessionId, registration.upstreamSessionId == state.context.sessionID,
              registration.binding.source == submissionSource else { throw terminalSubmissionFailure(.conflict) }
        var next = state
        let registered = next.register(requestID: registration.sequence, localRowID: registration.localRowID, context: next.context)
        guard registered.disposition == .registered || registered.disposition == .unchanged else { throw terminalSubmissionFailure(.conflict) }
        var effects = registered.effects
        switch record.recovery {
        case .accepted(let response):
            let accepted = next.accept(requestID: registration.sequence, response: response, context: next.context)
            guard accepted.disposition == .accepted || accepted.disposition == .unchanged else { throw terminalSubmissionFailure(.conflict) }
            effects += accepted.effects
        case .uncertain, .rpcFailure, .uninterpretable:
            effects += next.markSubmissionUncertain(requestID: registration.sequence, context: next.context).effects
        }
        state = next
        latestSubmission = .init(record: record, effects: effects)
        publish()
        if record.recovery == .uninterpretable { throw terminalSubmissionFailure(.uninterpretable) }
    }

    private func markAttemptUncertain(_ id: UUID) {
        guard status == .live, isCurrent(), let registration = submissionRegistrations[id] else { return }
        let reduction = state.markSubmissionUncertain(requestID: registration.sequence, context: state.context)
        guard !reduction.effects.isEmpty else { return }
        latestSubmission = .init(record: .init(registration: registration, outcome: nil), effects: reduction.effects)
        publish()
    }

    private func invalidateSubmissions() {
        for gate in submissionGates.values { gate.invalidate() }
        for worker in submissionTasks.values { worker.cancel() }
    }

    /// Fail closed on the canonical executor before returning through a
    /// transport or task waiter, which may suspend error propagation.
    private func terminalSubmissionFailure(_ reason: SubmissionFailure) -> Failure {
        let failure = Failure.submission(reason)
        block(failure)
        return failure
    }

    private func block(_ failure: Failure) {
        guard status != .stopped else { return }
        if case .blocked = status { return }
        let ownedLiveState = status == .live && isCurrent()
        status = .blocked(failure)
        invalidateSubmissions()
        task?.cancel()
        if ownedLiveState {
            for registration in submissionRegistrations.values {
                let reduction = state.markSubmissionUncertain(requestID: registration.sequence, context: state.context)
                if !reduction.effects.isEmpty {
                    latestSubmission = .init(record: .init(registration: registration, outcome: nil), effects: reduction.effects)
                }
            }
        }
        publish()
        observationContinuation.finish()
    }

    private func submissionStorage<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch is CancellationError { throw CancellationError() }
        catch { throw terminalSubmissionFailure(.persistence(error.localizedDescription)) }
    }

    private func storage<T: Sendable>(_ operation: Operation, _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as ACPV2UpdateJournalError { throw Failure.journal(operation, error) }
        catch { throw Failure.persistence(operation, message: error.localizedDescription) }
    }

    private func publish() {
        revision &+= 1
        observationContinuation.yield(.init(revision: revision, status: status, lastAppliedOrdinal: lastAppliedOrdinal,
            hasKnownMissingPrefix: hasKnownMissingPrefix, latestSubmission: latestSubmission, latestApplication: latestApplication))
    }
}
