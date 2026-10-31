import Foundation
import AlasACP
import AlasPlatform

public protocol ACPV2InboundLedgerPersisting: Sendable {
    func registerV2InboundLedger(sessionId: String, upstreamSessionId: String, source: ACPV2InboundLedgerSource,
        fence: ACPSessionLeaseFence) async throws -> ACPV2InboundLedgerStream
    func retainV2Inbound(_ delivery: ACPV2InboundDelivery, to stream: ACPV2InboundLedgerStream,
        fence: ACPSessionLeaseFence) async throws -> ACPV2InboundLedgerReceipt
    func loadV2InboundLedgerPage(stream: ACPV2InboundLedgerStream, after: ACPV2InboundLedgerContinuation?,
        maxRecords: Int, maxBytes: Int) async throws -> ACPV2InboundLedgerPage
}

extension ACPSessionPersistence: ACPV2InboundLedgerPersisting {}

/// Orders durable receipt retention and consumption for one attachment. It owns
/// neither request liveness nor replies, execution, queues or canonical state.
@MainActor
public final class ACPV2InboundReceiptOwner {
    public struct Attachment: Sendable {
        public let connectionID: UUID
        public let source: ACPV2InboundLedgerSource
        fileprivate let localSessionId: String?

        public init(stdioClient: ACPStdioClient) throws {
            guard stdioClient.sessionUpdateProtocolVersion == .v2 else { throw Failure.invalidAttachment }
            connectionID = stdioClient.updateConnectionID
            source = .stdio(connectionID: connectionID)
            localSessionId = nil
        }

        public init(brokerClient: ACPBrokerClient, opened: ACPBrokerOpenResult) throws {
            let snapshot = opened.snapshot
            guard case .broker(let connection, let id, let generation)? = brokerClient.v2PromptEndpoint,
                  id.rawValue.utf8.elementsEqual(snapshot.metadata.brokerId.rawValue.utf8), generation == snapshot.metadata.generation,
                  Self.validBrokerID(id), generation.rawValue > 0, Int64(exactly: generation.rawValue) != nil,
                  snapshot.metadata.wireContext == .rawV2, !snapshot.metadata.alasSessionId.isEmpty,
                  Int64(exactly: snapshot.journalTail.rawValue) != nil, snapshot.acknowledgedCursor <= snapshot.journalTail,
                  snapshot.turnState == .unknown("unknown"), snapshot.initializeResult == nil, snapshot.remoteSessionResult == nil,
                  snapshot.pendingRequests.allSatisfy({ $0.rawFrame != nil && ($0.originCursor?.rawValue ?? 0) > 0 && ($0.originCursor?.rawValue ?? .max) <= snapshot.journalTail.rawValue }) else {
                throw Failure.invalidAttachment
            }
            connectionID = connection
            source = .broker(id: id, generation: generation)
            localSessionId = snapshot.metadata.alasSessionId
        }

        private static func validBrokerID(_ id: ACPBrokerID) -> Bool {
            !id.rawValue.isEmpty && id.rawValue.utf8.count <= 160 && id.rawValue.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
    }

    public enum Operation: Equatable, Sendable { case registration, replay, retention }
    public enum Failure: Error, Equatable, Sendable {
        case invalidAttachment, ownershipLost, deliveryMismatch, invalidProof
        case ordinalGap(expected: Int64, received: Int64)
        case journal(Operation, ACPV2InboundLedgerError)
        case persistence(Operation, message: String)
        case input(message: String)
    }
    public enum Status: Equatable, Sendable {
        case idle, restoring, receiving, observationLost, stopped
        case blocked(Failure)
    }
    public struct ReceiptObservation: Equatable, Sendable {
        public enum Origin: Equatable, Sendable { case historical, inserted, duplicate }
        public let record: ACPV2InboundLedgerRecord
        public let origin: Origin
    }
    public struct Observation: Equatable, Sendable {
        public let revision: UInt64
        public let status: Status
        public let lastRetainedOrdinal: Int64
        public let hasKnownMissingPrefix: Bool
        public let latestReceipt: ReceiptObservation?
    }

    public private(set) var status: Status = .idle
    public private(set) var stream: ACPV2InboundLedgerStream?
    public private(set) var lastRetainedOrdinal: Int64 = 0
    public private(set) var hasKnownMissingPrefix = false
    public private(set) var latestReceipt: ReceiptObservation?
    /// Latest-only invalidations; inspect the ledger for a reliable history.
    public let observations: AsyncStream<Observation>

    private let sessionId: String
    private let upstreamSessionId: String
    private let attachment: Attachment
    private let fence: ACPSessionLeaseFence
    private let journal: any ACPV2InboundLedgerPersisting
    private let isCurrent: @MainActor () -> Bool
    private let continuation: AsyncStream<Observation>.Continuation
    private var task: Task<Void, Never>?
    private var started = false
    private var revision: UInt64 = 0

    public init(sessionId: String, upstreamSessionId: String, attachment: Attachment, fence: ACPSessionLeaseFence,
        journal: any ACPV2InboundLedgerPersisting, isCurrent: @escaping @MainActor () -> Bool) {
        self.sessionId = sessionId
        self.upstreamSessionId = upstreamSessionId
        self.attachment = attachment
        self.fence = fence
        self.journal = journal
        self.isCurrent = isCurrent
        let updates = AsyncStream<Observation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observations = updates.stream
        continuation = updates.continuation
    }

    @discardableResult
    public func start(_ deliveries: AsyncStream<ACPV2InboundDelivery>) -> Bool {
        guard case .stdio = attachment.source else { return false }
        return startSequence(deliveries, transform: { $0 })
    }

    @discardableResult
    public func start(_ deliveries: AsyncStream<ACPBrokerRawFrameDelivery>) -> Bool {
        guard case .broker = attachment.source else { return false }
        return startSequence(deliveries, transform: { $0.inboundDelivery })
    }

    private func startSequence<S: AsyncSequence & Sendable>(_ deliveries: S,
        transform: @escaping @Sendable (S.Element) -> ACPV2InboundDelivery) -> Bool where S.Element: Sendable {
        guard !started, status != .stopped else { return false }
        started = true
        task = Task { await self.run(deliveries, transform: transform) }
        return true
    }

    public func stop() {
        guard status != .stopped else { return }
        status = .stopped
        task?.cancel()
        publish()
        continuation.finish()
    }

    public func waitUntilFinished() async { await task?.value }

    private func requireCurrent() throws {
        guard !Task.isCancelled, status != .stopped else { throw Failure.ownershipLost }
        if case .blocked = status { throw Failure.ownershipLost }
        let current = isCurrent()
        guard current, !Task.isCancelled, status != .stopped else { throw Failure.ownershipLost }
        if case .blocked = status { throw Failure.ownershipLost }
    }

    private func run<S: AsyncSequence>(_ deliveries: S,
        transform: @Sendable (S.Element) -> ACPV2InboundDelivery) async where S.Element: Sendable {
        defer { continuation.finish() }
        do {
            try requireCurrent()
            guard !sessionId.isEmpty, !upstreamSessionId.isEmpty, fence.sessionId.utf8.elementsEqual(sessionId.utf8),
                  attachment.localSessionId.map({ $0.utf8.elementsEqual(sessionId.utf8) }) ?? true else { throw Failure.invalidAttachment }
            status = .restoring
            publish()
            let registered = try await storage(.registration) {
                try await self.journal.registerV2InboundLedger(sessionId: self.sessionId, upstreamSessionId: self.upstreamSessionId,
                    source: self.attachment.source, fence: self.fence)
            }
            try requireCurrent()
            try validate(registered)
            stream = registered
            hasKnownMissingPrefix = (registered.initialBrokerCursor?.rawValue ?? 0) > 0
            var after: ACPV2InboundLedgerContinuation?
            repeat {
                let page = try await storage(.replay) {
                    try await self.journal.loadV2InboundLedgerPage(stream: registered, after: after, maxRecords: 128, maxBytes: 1_048_576)
                }
                try requireCurrent()
                try validate(page, stream: registered)
                for record in page.records { try retainObservation(record, origin: .historical) }
                after = page.next
            } while after != nil
            status = .receiving
            publish()
            for try await value in deliveries {
                try requireCurrent()
                let delivery = transform(value)
                guard delivery.connectionID == attachment.connectionID else { throw Failure.deliveryMismatch }
                try validate(delivery.source)
                let receipt = try await storage(.retention) {
                    try await self.journal.retainV2Inbound(delivery, to: registered, fence: self.fence)
                }
                try requireCurrent()
                try validate(receipt, delivery: delivery)
                try retainObservation(receipt.record, origin: receipt.wasInserted ? .inserted : .duplicate)
                try requireCurrent()
                delivery.acknowledgeDurableConsumption()
            }
            try requireCurrent()
            status = .observationLost
            publish()
        } catch {
            guard status != .stopped else { return }
            status = .blocked((error as? Failure) ?? .input(message: error.localizedDescription))
            publish()
        }
    }

    private func validate(_ value: ACPV2InboundLedgerStream) throws {
        guard value.sessionId.utf8.elementsEqual(sessionId.utf8), value.upstreamSessionId.utf8.elementsEqual(upstreamSessionId.utf8),
              value.formatVersion == 1 else { throw Failure.invalidProof }
        switch (attachment.source, value.source) {
        case (.stdio(let expected), .stdio(let actual)):
            guard expected == actual, value.initialBrokerCursor == nil else { throw Failure.invalidProof }
        case (.broker(let expected, let generation), .broker(let actual, let actualGeneration)):
            guard expected.rawValue.utf8.elementsEqual(actual.rawValue.utf8), generation == actualGeneration,
                  let baseline = value.initialBrokerCursor, Int64(exactly: baseline.rawValue) != nil else { throw Failure.invalidProof }
        default: throw Failure.invalidProof
        }
    }

    private func validate(_ source: ACPV2InboundDelivery.Source) throws {
        switch (attachment.source, source) {
        case (.stdio, .stdio): break
        case (.broker(let id, let generation), .broker(let provenance, _)):
            guard id.rawValue.utf8.elementsEqual(provenance.brokerID.rawValue.utf8), generation == provenance.generation,
                  provenance.cursor.rawValue > 0, Int64(exactly: provenance.cursor.rawValue) != nil else { throw Failure.deliveryMismatch }
        default: throw Failure.deliveryMismatch
        }
    }

    private func validate(_ record: ACPV2InboundLedgerRecord) throws {
        guard record.streamID == stream?.id, record.ordinal > 0 else { throw Failure.invalidProof }
        try validate(record.source)
        if case .stdio = attachment.source, record.connectionID != attachment.connectionID { throw Failure.invalidProof }
    }

    private func validate(_ receipt: ACPV2InboundLedgerReceipt, delivery: ACPV2InboundDelivery) throws {
        let record = receipt.record
        try validate(record)
        guard record.frame == delivery.frame else { throw Failure.invalidProof }
        switch (record.source, delivery.source) {
        case (.stdio, .stdio):
            guard record.receiptID == delivery.receiptID, record.connectionID == delivery.connectionID else { throw Failure.invalidProof }
        case (.broker(let original, let pending), .broker(let actual, let actualPending)):
            guard original.cursor == actual.cursor, pending.map({ Data($0.utf8) }) == actualPending.map({ Data($0.utf8) }) else { throw Failure.invalidProof }
            if receipt.wasInserted, original.origin != actual.origin { throw Failure.invalidProof }
        default: throw Failure.invalidProof
        }
        if receipt.wasInserted {
            guard record.receiptID == delivery.receiptID, record.connectionID == delivery.connectionID,
                  record.ordinal > lastRetainedOrdinal else { throw Failure.invalidProof }
        }
    }

    private func validate(_ page: ACPV2InboundLedgerPage, stream: ACPV2InboundLedgerStream) throws {
        guard page.records.count <= 128, page.isAtEnd == (page.next == nil), page.hasKnownMissingPrefix == hasKnownMissingPrefix else { throw Failure.invalidProof }
        if let next = page.next {
            guard next.streamID == stream.id, next.afterOrdinal == page.records.last?.ordinal, next.afterOrdinal > lastRetainedOrdinal else { throw Failure.invalidProof }
        }
        let bytes = page.records.reduce(UInt64(0)) { $0 + UInt64($1.frame.count) }
        guard page.containsOversizedRecord ? (page.records.count == 1 && bytes > 1_048_576) : bytes <= 1_048_576 else { throw Failure.invalidProof }
    }

    private func retainObservation(_ record: ACPV2InboundLedgerRecord, origin: ReceiptObservation.Origin) throws {
        try requireCurrent()
        try validate(record)
        if origin == .historical || record.ordinal > lastRetainedOrdinal {
            guard lastRetainedOrdinal < Int64.max, record.ordinal == lastRetainedOrdinal + 1 else {
                throw Failure.ordinalGap(expected: lastRetainedOrdinal == Int64.max ? Int64.max : lastRetainedOrdinal + 1, received: record.ordinal)
            }
            lastRetainedOrdinal = record.ordinal
        }
        latestReceipt = .init(record: record, origin: origin)
        publish()
    }

    private func storage<T: Sendable>(_ operation: Operation, _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as ACPV2InboundLedgerError { throw Failure.journal(operation, error) }
        catch { throw Failure.persistence(operation, message: error.localizedDescription) }
    }

    private func publish() {
        revision &+= 1
        continuation.yield(.init(revision: revision, status: status, lastRetainedOrdinal: lastRetainedOrdinal,
            hasKnownMissingPrefix: hasKnownMissingPrefix, latestReceipt: latestReceipt))
    }
}
