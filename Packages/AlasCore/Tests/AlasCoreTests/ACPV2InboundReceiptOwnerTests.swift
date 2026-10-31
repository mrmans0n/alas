import Foundation
import Synchronization
import Testing
import AlasCore
@testable import AlasSessions

@MainActor
struct ACPV2InboundReceiptOwnerTests {
    @Test(arguments: [Data(), Data([255, 0]), Data(#"{"jsonrpc":"2.0","id":-7,"method":"fs/write_text_file","params":{"n":1e999,"n":2}}"#.utf8)])
    func exactCapturesCommitInOrderWhileCopiedReceiptsConsumeOnce(bytes: Data) async throws {
        let fixture = try await Fixture()
        let owner = try fixture.owner()
        let input = AsyncStream<ACPV2InboundDelivery>.makeStream()
        let consumed = Mutex<[Int]>([])
        let first = fixture.delivery(bytes, callback: { consumed.withLock { $0.append(1) } })
        let second = fixture.delivery(bytes, callback: { consumed.withLock { $0.append(2) } })
        input.continuation.yield(first)
        input.continuation.yield(first)
        input.continuation.yield(second)
        input.continuation.finish()
        #expect(owner.start(input.stream))
        #expect(!owner.start(input.stream))
        await owner.waitUntilFinished()
        #expect(owner.status == .observationLost)
        #expect(owner.lastRetainedOrdinal == 2)
        #expect(consumed.withLock { $0 } == [1, 2])
        let stream = try #require(owner.stream)
        let page = try await fixture.persistence.loadV2InboundLedgerPage(stream: stream)
        #expect(page.records.map(\.frame) == [bytes, bytes])
        #expect(owner.latestReceipt?.record == page.records.last)
        #expect(owner.latestReceipt?.origin == .inserted)
        #expect(fixture.transport.writes.withLock { $0 }.isEmpty)
    }

    @Test func replayRestoresMultiplePagesWithoutRevivingAnotherSourceOrItsCallbacks() async throws {
        let fixture = try await Fixture()
        let stream = try await fixture.register()
        let count = Mutex(0)
        for _ in 0..<130 {
            _ = try await fixture.persistence.retainV2Inbound(fixture.delivery(Data([255]), callback: { count.withLock { $0 += 1 } }), to: stream, fence: fixture.fence)
        }
        let otherConnection = UUID()
        let other = try await fixture.persistence.registerV2InboundLedger(sessionId: "local", upstreamSessionId: "other",
            source: .stdio(connectionID: otherConnection), fence: fixture.fence)
        _ = try await fixture.persistence.retainV2Inbound(.init(frame: Data(), connectionID: otherConnection, source: .stdio), to: other, fence: fixture.fence)
        let owner = try fixture.owner()
        let input = AsyncStream<ACPV2InboundDelivery>.makeStream()
        input.continuation.finish()
        _ = owner.start(input.stream)
        await owner.waitUntilFinished()
        #expect(owner.lastRetainedOrdinal == 130)
        #expect(owner.latestReceipt?.origin == .historical)
        #expect(owner.latestReceipt?.record.streamID == stream.id)
        #expect(count.withLock { $0 } == 0)
        #expect(!owner.hasKnownMissingPrefix)
        #expect(owner.status == .observationLost)
    }

    @Test func restoredReceiptConfirmsACurrentDuplicateWithoutAdvancingPrefix() async throws {
        let fixture = try await Fixture()
        let stream = try await fixture.register()
        let count = Mutex(0)
        let delivery = fixture.delivery(Data([255]), callback: { count.withLock { $0 += 1 } })
        let committed = try await fixture.persistence.retainV2Inbound(delivery, to: stream, fence: fixture.fence)
        let owner = try fixture.owner()
        let input = AsyncStream<ACPV2InboundDelivery>.makeStream()
        input.continuation.yield(delivery)
        input.continuation.finish()
        _ = owner.start(input.stream)
        await owner.waitUntilFinished()
        #expect(owner.lastRetainedOrdinal == 1)
        #expect(owner.latestReceipt?.origin == .duplicate)
        #expect(owner.latestReceipt?.record == committed.record)
        #expect(count.withLock { $0 } == 1)
    }

    @Test func v1ClientCannotCreateAnInboundOwnerAttachment() throws {
        let client = ACPStdioClient(transport: ReceiptTransport())
        #expect(throws: ACPV2InboundReceiptOwner.Failure.invalidAttachment) {
            try ACPV2InboundReceiptOwner.Attachment(stdioClient: client)
        }
    }

    @Test(arguments: ["registration", "replay", "retention"].flatMap { phase in [false, true].flatMap { after in ["stop", "replacement"].map { (phase, after, $0) } } })
    func invalidatedOwnershipCannotPublishOrConsumePersistenceReturns(phase: String, after: Bool, loss: String) async throws {
        let fixture = try await Fixture()
        let operation: InboundJournalGate.Operation = phase == "registration" ? .registration : (phase == "replay" ? .replay : .retention)
        if operation == .replay {
            let stream = try await fixture.register()
            _ = try await fixture.persistence.retainV2Inbound(fixture.delivery(Data([1])), to: stream, fence: fixture.fence)
        }
        let gate = InboundJournalGate(base: fixture.persistence, operation: operation, after: after)
        let current = OwnerReference()
        let owner = try fixture.owner(journal: gate, isCurrent: { current.isCurrent })
        let input = AsyncStream<ACPV2InboundDelivery>.makeStream()
        let consumed = Mutex(0)
        let delivery = fixture.delivery(Data([255]), callback: { consumed.withLock { $0 += 1 } })
        input.continuation.yield(delivery)
        input.continuation.finish()
        _ = owner.start(input.stream)
        try await eventually { await gate.reached }
        if loss == "stop" { owner.stop() } else { current.isCurrent = false }
        await gate.release()
        await owner.waitUntilFinished()
        #expect(owner.lastRetainedOrdinal == 0 && owner.latestReceipt == nil)
        #expect(consumed.withLock { $0 } == 0)
        #expect(owner.status == (loss == "stop" ? .stopped : .blocked(.ownershipLost)))
        if operation == .retention, after, loss == "stop" {
            let successor = try fixture.owner()
            let redelivery = AsyncStream<ACPV2InboundDelivery>.makeStream()
            redelivery.continuation.yield(delivery)
            redelivery.continuation.finish()
            _ = successor.start(redelivery.stream)
            await successor.waitUntilFinished()
            #expect(successor.lastRetainedOrdinal == 1)
            #expect(successor.latestReceipt?.origin == .duplicate)
            #expect(consumed.withLock { $0 } == 1)
        }
    }

    @Test(arguments: [InboundJournalGate.Fault.frame, .identity, .gap, .source, .insertedDuplicate, .pageGap, .registration])
    func inconsistentProofBlocksWithoutConsumingTheCurrentHandle(fault: InboundJournalGate.Fault) async throws {
        let fixture = try await Fixture()
        let consumed = Mutex(0)
        let original = fixture.delivery(Data([255]), callback: { consumed.withLock { $0 += 1 } })
        if fault == .insertedDuplicate || fault == .pageGap {
            let stream = try await fixture.register()
            _ = try await fixture.persistence.retainV2Inbound(original, to: stream, fence: fixture.fence)
        }
        let journal = InboundJournalGate(base: fixture.persistence, fault: fault)
        let owner = try fixture.owner(journal: journal)
        let live = fault == .insertedDuplicate ? original : fixture.delivery(Data([255]), callback: { consumed.withLock { $0 += 1 } })
        let input = AsyncStream<ACPV2InboundDelivery>.makeStream()
        input.continuation.yield(live)
        input.continuation.finish()
        _ = owner.start(input.stream)
        await owner.waitUntilFinished()
        if case .blocked = owner.status {} else { Issue.record("Inconsistent persisted proof remained usable") }
        #expect(owner.lastRetainedOrdinal == (fault == .insertedDuplicate ? 1 : 0))
        #expect(consumed.withLock { $0 } == 0)
    }

    @Test(arguments: ["lease", "sql", "connection", "source", "format"])
    func failedAuthorityOrStorageStopsBeforeTheNextDelivery(reason: String) async throws {
        let fixture = try await Fixture()
        let journal = InboundJournalGate(base: fixture.persistence)
        let database = try SQLiteDatabase(path: fixture.persistence.path)
        if reason == "lease" { _ = try await fixture.persistence.seizeLease(sessionId: "local", instanceId: "B", pid: 2, now: 2, leaseToken: "new") }
        if reason == "sql" { try database.exec("CREATE TRIGGER fail_inbound_owner AFTER INSERT ON acp_v2_inbound_records BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        if reason == "format" {
            _ = try await fixture.register()
            try database.exec("UPDATE acp_v2_inbound_streams SET format_version = 99")
        }
        let consumed = Mutex(0)
        let source: ACPV2InboundDelivery.Source = reason == "source" ? .broker(provenance: .init(brokerID: .init(rawValue: "broker"), generation: .init(rawValue: 7), cursor: .init(rawValue: 1), origin: .journal), pendingRequestID: "p") : .stdio
        let bad = ACPV2InboundDelivery(frame: Data(), connectionID: reason == "connection" ? UUID() : fixture.client.updateConnectionID,
            source: source, durableConsumptionAcknowledgement: { consumed.withLock { $0 += 1 } })
        let input = AsyncStream<ACPV2InboundDelivery>.makeStream()
        input.continuation.yield(bad)
        input.continuation.yield(fixture.delivery(Data([1]), callback: { consumed.withLock { $0 += 1 } }))
        input.continuation.finish()
        let owner = try fixture.owner(journal: journal)
        _ = owner.start(input.stream)
        await owner.waitUntilFinished()
        if case .blocked = owner.status {} else { Issue.record("Failed input continued receiving") }
        #expect(owner.lastRetainedOrdinal == 0 && consumed.withLock { $0 } == 0)
        #expect(await journal.retentions == (reason == "sql" ? 1 : 0))
        #expect(try database.query("SELECT ordinal FROM acp_v2_inbound_records").isEmpty)
    }

    @Test(arguments: [false, true])
    func synchronousPredicateOrConsumptionReentryCannotReviveStoppedOwnership(stopInPredicate: Bool) async throws {
        let fixture = try await Fixture()
        let reference = OwnerReference()
        let owner = try fixture.owner(isCurrent: {
            if stopInPredicate, reference.owner?.latestReceipt != nil { reference.owner?.stop() }
            return true
        })
        reference.owner = owner
        defer { reference.owner = nil }
        let consumed = Mutex(0)
        let input = AsyncStream<ACPV2InboundDelivery>.makeStream()
        input.continuation.yield(fixture.delivery(Data(), callback: {
            consumed.withLock { $0 += 1 }
            MainActor.assumeIsolated { reference.owner?.stop() }
        }))
        input.continuation.yield(fixture.delivery(Data([1]), callback: { consumed.withLock { $0 += 1 } }))
        input.continuation.finish()
        _ = owner.start(input.stream)
        await owner.waitUntilFinished()
        #expect(owner.status == .stopped)
        #expect(owner.lastRetainedOrdinal == 1)
        #expect(consumed.withLock { $0 } == (stopInPredicate ? 0 : 1))
    }

    private struct Fixture {
        let transport = ReceiptTransport()
        let client: ACPStdioClient
        let persistence: ACPSessionPersistence
        let fence = ACPSessionLeaseFence(sessionId: "local", ownerInstance: "A", token: "owner")

        init() async throws {
            client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
            persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("alas-inbound-owner-\(UUID()).sqlite").path)
            try await persistence.upsertSession(.init(id: "local", agentId: "fixture", title: "Inbound", autoRun: false,
                createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
            _ = try await persistence.seizeLease(sessionId: "local", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        }

        func register() async throws -> ACPV2InboundLedgerStream {
            try await persistence.registerV2InboundLedger(sessionId: "local", upstreamSessionId: "upstream",
                source: .stdio(connectionID: client.updateConnectionID), fence: fence)
        }

        @MainActor
        func owner(journal: (any ACPV2InboundLedgerPersisting)? = nil,
            isCurrent: @escaping @MainActor () -> Bool = { true }) throws -> ACPV2InboundReceiptOwner {
            .init(sessionId: "local", upstreamSessionId: "upstream", attachment: try .init(stdioClient: client),
                fence: fence, journal: journal ?? persistence, isCurrent: isCurrent)
        }

        func delivery(_ frame: Data, callback: ACPDurableConsumptionAcknowledgement? = nil) -> ACPV2InboundDelivery {
            .init(frame: frame, connectionID: client.updateConnectionID, source: .stdio, durableConsumptionAcknowledgement: callback)
        }
    }
}

private final class ReceiptTransport: JSONRPCStdioTransporting, Sendable {
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let writes = Mutex<[Data]>([])
    init() {
        let input = AsyncStream<JSONRPCStdioTransport.Incoming>.makeStream()
        incoming = input.stream
        continuation = input.continuation
    }
    func start() throws {}
    func send(_ data: Data) throws { writes.withLock { $0.append(data) } }
    func terminate() { continuation.finish() }
}

@MainActor
private final class OwnerReference {
    var owner: ACPV2InboundReceiptOwner?
    var isCurrent = true
}

actor InboundJournalGate: ACPV2InboundLedgerPersisting {
    enum Operation: Sendable { case registration, replay, retention }
    enum Fault: Sendable { case none, frame, identity, gap, source, insertedDuplicate, pageGap, registration, pending }
    let base: ACPSessionPersistence
    let operation: Operation?
    let after: Bool
    let fault: Fault
    private(set) var reached = false
    private(set) var retentions = 0
    private var waiter: CheckedContinuation<Void, Never>?

    init(base: ACPSessionPersistence, operation: Operation? = nil, after: Bool = false, fault: Fault = .none) {
        self.base = base
        self.operation = operation
        self.after = after
        self.fault = fault
    }
    func release() { waiter?.resume()
    waiter = nil }
    private func pause(_ operation: Operation, after: Bool) async {
        guard self.operation == operation, self.after == after, !reached else { return }
        reached = true
        await withCheckedContinuation { waiter = $0 }
    }
    func registerV2InboundLedger(sessionId: String, upstreamSessionId: String, source: ACPV2InboundLedgerSource,
        fence: ACPSessionLeaseFence) async throws -> ACPV2InboundLedgerStream {
        await pause(.registration, after: false)
        let value = try await base.registerV2InboundLedger(sessionId: sessionId, upstreamSessionId: upstreamSessionId, source: source, fence: fence)
        await pause(.registration, after: true)
        if fault == .registration {
            return .init(id: value.id, sessionId: value.sessionId, upstreamSessionId: "wrong", source: value.source, formatVersion: 1, initialBrokerCursor: value.initialBrokerCursor)
        }
        return value
    }
    func retainV2Inbound(_ delivery: ACPV2InboundDelivery, to stream: ACPV2InboundLedgerStream,
        fence: ACPSessionLeaseFence) async throws -> ACPV2InboundLedgerReceipt {
        retentions += 1
        await pause(.retention, after: false)
        let value = try await base.retainV2Inbound(delivery, to: stream, fence: fence)
        await pause(.retention, after: true)
        let original = value.record
        var source = original.source
        if fault == .source { source = .broker(provenance: .init(brokerID: .init(rawValue: "wrong"), generation: .init(rawValue: 7), cursor: .init(rawValue: 1), origin: .journal), pendingRequestID: nil) }
        if fault == .pending, case .broker(let provenance, _) = source { source = .broker(provenance: provenance, pendingRequestID: "e\u{301}") }
        let changed = ACPV2InboundLedgerRecord(streamID: original.streamID, ordinal: original.ordinal + (fault == .gap ? 1 : 0),
            receiptID: fault == .identity ? UUID() : original.receiptID, connectionID: original.connectionID,
            source: source,
            frame: fault == .frame ? Data([99]) : original.frame)
        return .init(record: changed, wasInserted: fault == .insertedDuplicate || value.wasInserted)
    }
    func loadV2InboundLedgerPage(stream: ACPV2InboundLedgerStream, after: ACPV2InboundLedgerContinuation?, maxRecords: Int, maxBytes: Int) async throws -> ACPV2InboundLedgerPage {
        await pause(.replay, after: false)
        let value = try await base.loadV2InboundLedgerPage(stream: stream, after: after, maxRecords: maxRecords, maxBytes: maxBytes)
        await pause(.replay, after: true)
        guard fault == .pageGap, let original = value.records.first else { return value }
        let changed = ACPV2InboundLedgerRecord(streamID: original.streamID, ordinal: original.ordinal + 1, receiptID: original.receiptID,
            connectionID: original.connectionID, source: original.source, frame: original.frame)
        return .init(records: [changed], next: nil, isAtEnd: true, hasKnownMissingPrefix: value.hasKnownMissingPrefix, containsOversizedRecord: false)
    }
}
