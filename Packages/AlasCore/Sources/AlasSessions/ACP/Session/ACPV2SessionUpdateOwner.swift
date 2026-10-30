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
/// dispatch prompts, project UI rows, or advance queues.
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

    public enum Operation: Equatable, Sendable { case registration, replay, append }
    public enum Failure: Error, Equatable, Sendable {
        case invalidAttachment
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
        public let latestApplication: Application?
    }

    public private(set) var state: ACPV2SessionState
    public private(set) var stream: ACPV2UpdateJournalStream?
    public private(set) var lastAppliedOrdinal: Int64 = 0
    public private(set) var hasKnownMissingPrefix = false
    public private(set) var status: Status = .idle
    public private(set) var latestApplication: Application?
    /// Latest-only invalidations, not a reliable effect queue. Read `state` to
    /// obtain canonical facts; slow readers may skip observation revisions.
    public let observations: AsyncStream<Observation>

    private let sessionId: String
    private let attachment: Attachment
    private let fence: ACPSessionLeaseFence
    private let journal: any ACPV2UpdateJournalPersisting
    private let isCurrent: @MainActor () -> Bool
    private let observationContinuation: AsyncStream<Observation>.Continuation
    private var task: Task<Void, Never>?
    private var started = false
    private var revision: UInt64 = 0

    public init(sessionId: String, upstreamSessionId: String, attachment: Attachment,
        fence: ACPSessionLeaseFence, journal: any ACPV2UpdateJournalPersisting,
        isCurrent: @escaping @MainActor () -> Bool) {
        self.sessionId = sessionId
        self.attachment = attachment
        self.fence = fence
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
        publish()
        observationContinuation.finish()
    }

    public func waitUntilFinished() async { await task?.value }

    private func requireCurrent() throws {
        guard !Task.isCancelled, status != .stopped, isCurrent() else { throw Failure.ownershipLost }
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
            publish()
        } catch {
            guard status != .stopped else { return }
            status = .blocked((error as? Failure) ?? .interpretation(ordinal: lastAppliedOrdinal + 1, message: error.localizedDescription))
            publish()
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

    private func storage<T: Sendable>(_ operation: Operation, _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as ACPV2UpdateJournalError { throw Failure.journal(operation, error) }
        catch { throw Failure.persistence(operation, message: error.localizedDescription) }
    }

    private func publish() {
        revision &+= 1
        observationContinuation.yield(.init(revision: revision, status: status, lastAppliedOrdinal: lastAppliedOrdinal,
            hasKnownMissingPrefix: hasKnownMissingPrefix, latestApplication: latestApplication))
    }
}
