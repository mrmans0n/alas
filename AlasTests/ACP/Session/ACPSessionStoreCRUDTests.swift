import Foundation
import Synchronization
import Testing
@testable import Alas
@testable import AlasACP

@Suite("ACPSessionStore CRUD")
struct ACPSessionStoreCRUDTests {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("acp-crud-\(UUID()).sqlite")
    }

    private func tmp() throws -> ACPSessionStore {
        try ACPSessionStore(path: tmpURL().path)
    }

    private func inboundFixture(source: ACPV2InboundLedgerSource? = nil) throws -> (ACPSessionStore, ACPSessionLeaseFence, ACPV2InboundLedgerStream) {
        let (store, fence, _) = try journalFixture()
        let stream = try store.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream",
            source: source ?? .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 7)), fence: fence)
        return (store, fence, stream)
    }

    private func inbound(_ frame: Data, cursor: UInt64 = 5, pending: String? = "opaque-helper",
        origin: ACPBrokerFrameProvenance.Origin = .journal, callback: ACPDurableConsumptionAcknowledgement? = nil) -> ACPV2InboundDelivery {
        .init(frame: frame, connectionID: UUID(), source: .broker(provenance: .init(brokerID: .init(rawValue: "broker"),
            generation: .init(rawValue: 7), cursor: .init(rawValue: cursor), origin: origin), pendingRequestID: pending),
            durableConsumptionAcknowledgement: callback)
    }

    @Test(arguments: [false, true])
    func inboundRegistrationKeepsOneSourceContextAcrossSessionsAndAck(broker: Bool) throws {
        let source: ACPV2InboundLedgerSource = broker ? .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 7)) : .stdio(connectionID: UUID())
        let (store, fence, stream) = try inboundFixture(source: source)
        #expect(try store.updateACPBrokerAcknowledgedCursor(sessionId: "journal", brokerId: "broker", generation: 7, cursor: 8, wireContext: .rawV2))
        let reopened = try ACPSessionStore(path: store.path)
        #expect(try reopened.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream", source: source, fence: fence) == stream)
        #expect(stream.initialBrokerCursor?.rawValue == (broker ? 4 : nil))
        #expect(throws: ACPV2InboundLedgerError.incompatibleStream) {
            try reopened.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "other", source: source, fence: fence)
        }
        try reopened.upsertSession(.init(id: "other", agentId: "fixture", title: "Other", autoRun: false,
            acpBrokerId: "broker", acpBrokerGeneration: 7, acpBrokerWireContextJSON: try ACPBrokerWireContext.rawV2.persistedJSON(),
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        try reopened.seizeLease(sessionId: "other", instanceId: "A", pid: 1, now: 1, leaseToken: "other")
        #expect(throws: ACPV2InboundLedgerError.incompatibleStream) {
            try reopened.registerV2InboundLedger(sessionId: "other", upstreamSessionId: "upstream", source: source,
                fence: .init(sessionId: "other", ownerInstance: "A", token: "other"))
        }
        #expect(try reopened.db.query("SELECT id FROM acp_v2_inbound_streams").count == 1)
        if broker {
            for invalid in [ACPV2InboundLedgerSource.broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 0)),
                .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: .max)),
                .broker(id: .init(rawValue: "bad/id"), generation: .init(rawValue: 7))] {
                #expect(throws: ACPV2InboundLedgerError.invalidInput) {
                    try reopened.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream", source: invalid, fence: fence)
                }
            }
        }
        let unicodeSource = ACPV2InboundLedgerSource.stdio(connectionID: UUID())
        let unicodeStream = try reopened.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "\u{feff}upstream-\u{e9}", source: unicodeSource, fence: fence)
        #expect(try reopened.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "\u{feff}upstream-\u{e9}", source: unicodeSource, fence: fence) == unicodeStream)
        #expect(throws: ACPV2InboundLedgerError.incompatibleStream) {
            try reopened.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "\u{feff}upstream-e\u{301}", source: unicodeSource, fence: fence)
        }
    }

    @Test(arguments: [Data(), Data([0, 255, 128]), Data(" \n{\"jsonrpc\":\"2.0\",\"id\":-7,\"method\":\"peer/future\",\"params\":{\"n\":1e999,\"n\":2}}\n".utf8)])
    func inboundStdioCopiesRetryWhileEqualCapturesStayDistinct(bytes: Data) throws {
        let connection = UUID()
        let (store, fence, stream) = try inboundFixture(source: .stdio(connectionID: connection))
        let count = Mutex(0)
        let delivery = ACPV2InboundDelivery(frame: bytes, connectionID: connection, source: .stdio,
            durableConsumptionAcknowledgement: { count.withLock { $0 += 1 } })
        let first = try store.retainV2Inbound(delivery, to: stream, fence: fence)
        let reopened = try ACPSessionStore(path: store.path)
        let copy = try reopened.retainV2Inbound(delivery, to: stream, fence: fence)
        let equal = try reopened.retainV2Inbound(.init(frame: bytes, connectionID: connection, source: .stdio), to: stream, fence: fence)
        #expect(first.wasInserted && !copy.wasInserted && equal.wasInserted)
        #expect(first.record == copy.record)
        #expect(equal.record.ordinal == 2)
        #expect(first.record.frame == bytes)
        #expect(first.record.receiptID == delivery.receiptID)
        #expect(first.record.source == .stdio)
        let row = try #require(try reopened.db.query("SELECT typeof(frame) AS kind, length(frame) AS bytes FROM acp_v2_inbound_records WHERE ordinal = 1").first)
        #expect(row["kind"] as? String == "blob")
        #expect(row["bytes"] as? Int64 == Int64(bytes.count))
        #expect(throws: ACPV2InboundLedgerError.incompatibleStream) {
            try reopened.retainV2Inbound(.init(frame: bytes, connectionID: UUID(), source: .stdio), to: stream, fence: fence)
        }
        #expect(count.withLock { $0 } == 0)
        delivery.acknowledgeDurableConsumption()
        #expect(count.withLock { $0 } == 1)
    }

    @Test func inboundBrokerRetriesKeepOriginalEvidenceWithoutMergingReusedPendingIDs() throws {
        let (store, fence, stream) = try inboundFixture()
        let bytes = Data(#"{"jsonrpc":"2.0","id":"wire-id","method":"unknown","params":true}"#.utf8)
        let pendingID = "\u{feff}opaque-\u{e9}\0id"
        let original = inbound(bytes, pending: pendingID)
        let first = try store.retainV2Inbound(original, to: stream, fence: fence)
        let reopened = try ACPSessionStore(path: store.path)
        let retry = try reopened.retainV2Inbound(inbound(bytes, pending: pendingID, origin: .pendingSnapshot), to: stream, fence: fence)
        #expect(!retry.wasInserted)
        #expect(retry.record == first.record)
        #expect(retry.record.connectionID == original.connectionID)
        #expect(retry.record.source == original.source)
        if case .broker(_, let stored) = retry.record.source {
            #expect(stored.map { Data($0.utf8) } == Data(pendingID.utf8))
        }
        #expect(try reopened.retainV2Inbound(inbound(bytes, cursor: 6, pending: pendingID), to: stream, fence: fence).record.ordinal == 2)
        for pending in [nil, "different", "\u{feff}opaque-e\u{301}\0id"] as [String?] {
            #expect(throws: ACPV2InboundLedgerError.conflictingReceipt) {
                try reopened.retainV2Inbound(inbound(bytes, pending: pending), to: stream, fence: fence)
            }
        }
        #expect(throws: ACPV2InboundLedgerError.conflictingReceipt) {
            try reopened.retainV2Inbound(inbound(Data("changed".utf8)), to: stream, fence: fence)
        }
        #expect(try reopened.loadSession(id: "journal")?.acpBrokerAcknowledgedCursor == 4)
    }

    @Test(arguments: ["lease", "session", "generation", "context", "legacy", "cursor", "source", "descriptor"])
    func inboundAuthorityFailureCannotRetainOrConsume(reason: String) throws {
        let (store, originalFence, stream) = try inboundFixture()
        var fence = originalFence
        switch reason {
        case "lease": try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        case "session": fence = .init(sessionId: "other", ownerInstance: "A", token: "owner")
        case "generation": _ = try store.updateACPBrokerState(sessionId: "journal", brokerId: "broker", generation: 8, acknowledgedCursor: 0, wireContext: .rawV2)
        case "context": try store.db.exec("UPDATE sessions SET acp_broker_wire_context = '{future}'")
        case "legacy": try store.db.exec("UPDATE sessions SET acp_broker_wire_context = NULL")
        case "descriptor": try store.db.exec("UPDATE acp_v2_inbound_streams SET upstream_session_id = 'changed'")
        default: break
        }
        let count = Mutex(0)
        let delivery = reason == "source" ? ACPV2InboundDelivery(frame: Data(), connectionID: UUID(), source: .stdio) : inbound(Data(), cursor: reason == "cursor" ? .max : 5, callback: { count.withLock { $0 += 1 } })
        let before = try store.loadSession(id: "journal")
        #expect(throws: (any Error).self) { try store.retainV2Inbound(delivery, to: stream, fence: fence) }
        #expect(try store.db.query("SELECT ordinal FROM acp_v2_inbound_records").isEmpty)
        #expect(try store.loadSession(id: "journal") == before)
        #expect(count.withLock { $0 } == 0)
        if ["lease", "context", "legacy", "generation"].contains(reason) {
            #expect(throws: (any Error).self) { try store.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream", source: stream.source, fence: fence) }
        }
    }

    @Test func failedInboundInsertRollsBackBeforeDurableProofOrConsumption() throws {
        let (store, fence, stream) = try inboundFixture()
        let count = Mutex(0)
        let delivery = inbound(Data(), callback: { count.withLock { $0 += 1 } })
        try store.db.exec("CREATE TRIGGER fail_inbound AFTER INSERT ON acp_v2_inbound_records BEGIN SELECT RAISE(ABORT, 'injected'); END")
        #expect(throws: SQLiteError.self) { try store.retainV2Inbound(delivery, to: stream, fence: fence) }
        #expect(try store.db.query("SELECT ordinal FROM acp_v2_inbound_records").isEmpty)
        try store.db.exec("DROP TRIGGER fail_inbound")
        #expect(try store.retainV2Inbound(delivery, to: stream, fence: fence).record.ordinal == 1)
        #expect(count.withLock { $0 } == 0)
    }

    @Test func inboundRecoveryPagesKeepBytesAndMakeOversizedProgress() throws {
        let (store, fence, stream) = try inboundFixture()
        let consumed = Mutex(0)
        let known = Data(#"{"jsonrpc":"2.0","id":-7,"method":"session/request_permission","params":{"n":1e999}}"#.utf8)
        let frames = [Data(), Data([1, 2]), Data(repeating: 255, count: 6), known]
        var originals: [ACPV2InboundLedgerRecord] = []
        for (index, frame) in frames.enumerated() {
            originals.append(try store.retainV2Inbound(inbound(frame, cursor: UInt64(index + 5), pending: nil,
                callback: { consumed.withLock { $0 += 1 } }), to: stream, fence: fence).record)
        }
        let reopened = try ACPSessionStore(path: store.path)
        let first = try reopened.loadV2InboundLedgerPage(stream: stream, maxRecords: 3, maxBytes: 2)
        #expect(first.records == Array(originals.prefix(2)))
        #expect(!first.isAtEnd && first.hasKnownMissingPrefix && !first.containsOversizedRecord)
        let afterFirst = try #require(first.next)
        #expect(afterFirst.afterOrdinal == 2)
        let second = try reopened.loadV2InboundLedgerPage(stream: stream, after: afterFirst, maxRecords: 3, maxBytes: 2)
        #expect(second.records == [originals[2]])
        #expect(second.containsOversizedRecord && !second.isAtEnd)
        let third = try reopened.loadV2InboundLedgerPage(stream: stream, after: second.next, maxRecords: 1)
        #expect(third.records == [originals[3]])
        #expect(third.isAtEnd && third.next == nil)
        let header = try #require(third.records.first).decodeHeader()
        #expect(header.id == .number(-7))
        #expect(header.params == .object(["n": .number("1e999")]))
        #expect(throws: (any Error).self) { try originals[2].decodeHeader() }
        let empty = try reopened.loadV2InboundLedgerPage(stream: stream, after: .init(streamID: stream.id, afterOrdinal: 4))
        #expect(empty.isAtEnd && empty.records.isEmpty)
        let countPage = try reopened.loadV2InboundLedgerPage(stream: stream, maxRecords: 1)
        #expect(countPage.records == [originals[0]] && countPage.next?.afterOrdinal == 1)
        #expect(consumed.withLock { $0 } == 0)
        #expect(try reopened.loadSession(id: "journal")?.acpBrokerAcknowledgedCursor == 4)
    }

    @Test func inboundRecoveryRejectsForeignPositionsAndInvalidBudgets() throws {
        let (store, fence, stream) = try inboundFixture()
        _ = try store.retainV2Inbound(inbound(Data()), to: stream, fence: fence)
        let other = try store.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "other", source: .stdio(connectionID: UUID()), fence: fence)
        for after in [ACPV2InboundLedgerContinuation(streamID: stream.id, afterOrdinal: 0),
            .init(streamID: stream.id, afterOrdinal: 2), .init(streamID: other.id, afterOrdinal: 1)] {
            #expect(throws: ACPV2InboundLedgerError.invalidInput) { try store.loadV2InboundLedgerPage(stream: stream, after: after) }
        }
        for (records, bytes) in [(0, 1), (1001, 1), (1, 0), (1, Int(Int32.max) + 1)] {
            #expect(throws: ACPV2InboundLedgerError.invalidInput) { try store.loadV2InboundLedgerPage(stream: stream, maxRecords: records, maxBytes: bytes) }
        }
        #expect(throws: ACPV2InboundLedgerError.invalidInput) { try store.loadV2InboundLedgerStream(sessionId: "other", beforeStreamID: stream.id) }
        #expect(throws: ACPV2InboundLedgerError.invalidInput) { try store.loadV2InboundLedgerStream(sessionId: "journal", beforeStreamID: UUID()) }
    }

    @Test(arguments: ["format", "context", "stream-uuid", "source-key", "baseline", "receipt-uuid", "connection-uuid", "cursor", "origin", "receipt-key", "pending-type", "frame-type"])
    func inboundRecoveryFailsExplicitlyOnUnsupportedOrCorruptMetadata(reason: String) throws {
        let (store, fence, stream) = try inboundFixture()
        _ = try store.retainV2Inbound(inbound(Data([255])), to: stream, fence: fence)
        let statement: String
        switch reason {
        case "format": statement = "UPDATE acp_v2_inbound_streams SET format_version = 99"
        case "context": statement = "UPDATE acp_v2_inbound_streams SET wire_context = '{future}'"
        case "stream-uuid": statement = "UPDATE acp_v2_inbound_streams SET id = lower(id)"
        case "source-key": statement = "UPDATE acp_v2_inbound_streams SET source_key = 'wrong'"
        case "baseline": statement = "UPDATE acp_v2_inbound_streams SET initial_cursor = -1"
        case "receipt-uuid": statement = "UPDATE acp_v2_inbound_records SET receipt_id = 'bad'"
        case "connection-uuid": statement = "UPDATE acp_v2_inbound_records SET connection_id = 'bad'"
        case "cursor": statement = "UPDATE acp_v2_inbound_records SET broker_cursor = -1"
        case "origin": statement = "UPDATE acp_v2_inbound_records SET broker_origin = 'future'"
        case "receipt-key": statement = "UPDATE acp_v2_inbound_records SET receipt_key = 'different'"
        case "pending-type": statement = "UPDATE acp_v2_inbound_records SET pending_request_id = x'ff'"
        default: statement = "UPDATE acp_v2_inbound_records SET frame = 'text'"
        }
        if reason == "stream-uuid" { try store.db.exec("PRAGMA foreign_keys = OFF") }
        try store.db.exec(statement)
        let expected: ACPV2InboundLedgerError = ["format", "context"].contains(reason) ? .unsupportedFormat : .corruptRecord
        if ["format", "context", "stream-uuid", "source-key", "baseline"].contains(reason) {
            #expect(throws: expected) { try store.loadV2InboundLedgerStream(sessionId: "journal") }
        } else {
            #expect(throws: expected) { try store.loadV2InboundLedgerPage(stream: stream) }
        }
        #expect(try store.db.query("SELECT frame FROM acp_v2_inbound_records").count == 1)
    }

    @Test func inboundHistoricalDiscoverySurvivesSourceReplacementUntilSessionDeletion() throws {
        let (store, fence, old) = try inboundFixture()
        try store.enableReplicaExport(sessionId: "journal", recordId: "replica")
        let serial = try store.db.query("SELECT serial FROM session_replica_serial").first?["serial"] as? Int64
        let captured = inbound(Data(#"{"jsonrpc":"2.0","id":1,"method":"m"}"#.utf8), origin: .pendingSnapshot)
        let original = try store.retainV2Inbound(captured, to: old, fence: fence)
        #expect(try store.db.query("SELECT serial FROM session_replica_serial").first?["serial"] as? Int64 == serial)
        #expect(try store.updateACPBrokerAcknowledgedCursor(sessionId: "journal", brokerId: "broker", generation: 7, cursor: 8, wireContext: .rawV2))
        let ackedRetry = try store.retainV2Inbound(inbound(captured.frame, origin: .pendingSnapshot), to: old, fence: fence)
        #expect(ackedRetry.record == original.record && !ackedRetry.wasInserted)
        try store.clearACPBrokerState(sessionId: "journal")
        let reopened = try ACPSessionStore(path: store.path)
        #expect(try reopened.loadV2InboundLedgerStream(sessionId: "journal") == old)
        #expect(try reopened.updateACPBrokerState(sessionId: "journal", brokerId: "broker", generation: 8, acknowledgedCursor: 0, wireContext: .rawV2))
        try reopened.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        let current = try reopened.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream", source: .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 8)),
            fence: .init(sessionId: "journal", ownerInstance: "B", token: "new"))
        #expect(try reopened.loadV2InboundLedgerStream(sessionId: "journal") == current)
        #expect(try reopened.loadV2InboundLedgerStream(sessionId: "journal", beforeStreamID: current.id) == old)
        #expect(try reopened.loadV2InboundLedgerStream(sessionId: "journal", beforeStreamID: old.id) == nil)
        let before = try reopened.loadSession(id: "journal")
        let replica = try reopened.db.query("SELECT serial FROM session_replica_serial").first?["serial"] as? Int64
        let recovered = try reopened.loadV2InboundLedgerPage(stream: old)
        #expect(recovered.records == [original.record] && recovered.hasKnownMissingPrefix)
        #expect(try reopened.loadV2InboundLedgerPage(stream: current).hasKnownMissingPrefix == false)
        #expect(try reopened.loadSession(id: "journal") == before)
        #expect(try reopened.db.query("SELECT serial FROM session_replica_serial").first?["serial"] as? Int64 == replica)
        try reopened.deleteSession(id: "journal")
        #expect(try reopened.loadV2InboundLedgerStream(sessionId: "journal") == nil)
        #expect(try reopened.db.query("SELECT stream_id FROM acp_v2_inbound_records").isEmpty)
    }

    @Test(arguments: ["delivery", "stored-key"])
    func inboundBrokerIdentityCannotUseUnicodeEquivalenceToChangeItsSource(path: String) throws {
        let (store, fence, _) = try inboundFixture()
        #expect(try store.updateACPBrokerState(sessionId: "journal", brokerId: "K", generation: 7, acknowledgedCursor: 4, wireContext: .rawV2))
        let source = ACPV2InboundLedgerSource.broker(id: .init(rawValue: "K"), generation: .init(rawValue: 7))
        let stream = try store.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream", source: source, fence: fence)
        let count = Mutex(0)
        if path == "delivery" {
            let delivery = ACPV2InboundDelivery(frame: Data(), connectionID: UUID(), source: .broker(provenance: .init(brokerID: .init(rawValue: "\u{212a}"),
                generation: .init(rawValue: 7), cursor: .init(rawValue: 5), origin: .journal), pendingRequestID: "p"),
                durableConsumptionAcknowledgement: { count.withLock { $0 += 1 } })
            #expect(throws: ACPV2InboundLedgerError.incompatibleStream) { try store.retainV2Inbound(delivery, to: stream, fence: fence) }
        } else {
            try store.db.exec("UPDATE acp_v2_inbound_streams SET source_key = ? WHERE id = ?", bindings: ["broker:\u{212a}:7", stream.id.uuidString])
            #expect(throws: ACPV2InboundLedgerError.corruptRecord) { try store.loadV2InboundLedgerStream(sessionId: "journal") }
            #expect(throws: ACPV2InboundLedgerError.corruptRecord) {
                try store.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream", source: source, fence: fence)
            }
        }
        #expect(count.withLock { $0 } == 0)
        #expect(try store.db.query("SELECT ordinal FROM acp_v2_inbound_records").isEmpty)
        #expect(try store.db.query("SELECT id FROM acp_v2_inbound_streams").count == 2)
    }

    @Test(arguments: [false, true])
    func corruptCurrentBrokerAckCannotBecomeAZeroLedgerBaseline(retention: Bool) throws {
        let (store, fence, _) = try journalFixture()
        let source = ACPV2InboundLedgerSource.broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 7))
        let stream = retention ? try store.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream", source: source, fence: fence) : nil
        try store.db.exec("UPDATE sessions SET acp_broker_acknowledged_cursor = 'corrupt' WHERE id = 'journal'")
        let count = Mutex(0)
        if let stream {
            #expect(throws: ACPV2InboundLedgerError.incompatibleStream) {
                try store.retainV2Inbound(inbound(Data(), callback: { count.withLock { $0 += 1 } }), to: stream, fence: fence)
            }
        } else {
            #expect(throws: ACPV2InboundLedgerError.incompatibleStream) {
                try store.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "upstream", source: source, fence: fence)
            }
        }
        #expect(try store.db.query("SELECT ordinal FROM acp_v2_inbound_records").isEmpty)
        #expect(try store.db.query("SELECT id FROM acp_v2_inbound_streams").count == (retention ? 1 : 0))
        #expect(count.withLock { $0 } == 0)
    }

    @Test(arguments: ["pending", "upstream"])
    func inboundOpaqueMetadataCannotRecoverThroughLossyUTF8Repair(field: String) throws {
        let (store, fence, stream) = try inboundFixture()
        let delivery = inbound(Data([255]), pending: "\u{fffd}")
        _ = try store.retainV2Inbound(delivery, to: stream, fence: fence)
        if field == "pending" {
            try store.db.exec("UPDATE acp_v2_inbound_records SET pending_request_id = CAST(x'ff' AS TEXT)")
            #expect(throws: ACPV2InboundLedgerError.corruptRecord) { try store.loadV2InboundLedgerPage(stream: stream) }
            #expect(throws: ACPV2InboundLedgerError.corruptRecord) { try store.retainV2Inbound(delivery, to: stream, fence: fence) }
        } else {
            try store.db.exec("UPDATE acp_v2_inbound_streams SET upstream_session_id = CAST(x'ff' AS TEXT)")
            #expect(throws: ACPV2InboundLedgerError.corruptRecord) { try store.loadV2InboundLedgerStream(sessionId: "journal") }
            #expect(throws: ACPV2InboundLedgerError.corruptRecord) {
                try store.registerV2InboundLedger(sessionId: "journal", upstreamSessionId: "\u{fffd}", source: stream.source, fence: fence)
            }
        }
        #expect(try store.db.query("SELECT frame FROM acp_v2_inbound_records").first?["frame"] as? Data == Data([255]))
    }

    private func responseFixture(broker: Bool = true, frame: Data? = nil, pending: String? = "opaque-helper",
        callback: ACPDurableConsumptionAcknowledgement? = nil) throws -> (ACPSessionStore, ACPSessionLeaseFence, ACPV2InboundLedgerStream, ACPV2InboundLedgerRecord) {
        let connection = UUID()
        let (store, fence, stream) = try inboundFixture(source: broker ? nil : .stdio(connectionID: connection))
        let bytes = frame ?? Data(#"{"jsonrpc":"2.0","id":7,"method":"peer/request","params":{"n":1e999}}"#.utf8)
        let delivery = broker ? inbound(bytes, pending: pending, callback: callback) : ACPV2InboundDelivery(frame: bytes, connectionID: connection, source: .stdio, durableConsumptionAcknowledgement: callback)
        return (store, fence, stream, try store.retainV2Inbound(delivery, to: stream, fence: fence).record)
    }

    @Test(arguments: [false, true])
    func responseIntentsKeepOneExactDecisionPerRetainedOrigin(broker: Bool) throws {
        let count = Mutex(0)
        let (store, fence, stream, request) = try responseFixture(broker: broker, callback: { count.withLock { $0 += 1 } })
        let bytes = Data(#" {"jsonrpc":"2.0","id":7,"result":{"n":1e999}} "#.utf8)
        let id = UUID()
        let first = try store.registerV2ResponseIntent(id: id, request: request, in: stream, frame: bytes, fence: fence)
        let reopened = try ACPSessionStore(path: store.path)
        let retry = try reopened.registerV2ResponseIntent(id: id, request: request, in: stream, frame: bytes, fence: fence)
        #expect(first.wasInserted && !retry.wasInserted && first.value == retry.value)
        #expect(first.value.frame == bytes && first.value.request == request)
        if broker {
            let redelivery = try reopened.retainV2Inbound(inbound(request.frame, origin: .pendingSnapshot), to: stream, fence: fence)
            #expect(try !reopened.registerV2ResponseIntent(id: id, request: redelivery.record, in: stream, frame: bytes, fence: fence).wasInserted)
        }
        for (otherID, frame) in [(UUID(), bytes), (id, Data(#"{"jsonrpc":"2.0","id":7,"result":false}"#.utf8))] {
            #expect(throws: ACPV2ResponseLedgerError.conflict) { try reopened.registerV2ResponseIntent(id: otherID, request: request, in: stream, frame: frame, fence: fence) }
        }
        let key = ACPV2ReplyOperationKey(rawValue: "\u{feff}é\0answer")
        let attemptID = UUID()
        let attempt = try reopened.registerV2ResponseAttempt(id: attemptID, for: first.value, operationKey: key, fence: fence)
        #expect(attempt.value.sequence == 1)
        #expect(try !reopened.registerV2ResponseAttempt(id: attemptID, for: first.value, operationKey: key, fence: fence).wasInserted)
        #expect(throws: ACPV2ResponseLedgerError.conflict) { try reopened.registerV2ResponseAttempt(id: UUID(), for: first.value, operationKey: .init(rawValue: "new"), fence: fence) }
        #expect(count.withLock { $0 } == 0)
        #expect(try store.loadSession(id: "journal")?.acpBrokerAcknowledgedCursor == 4)
    }

    @Test(arguments: ["notification", "malformed", "missing-pending", "wrong-id", "changed-record", "invalid-response"])
    func responseIntentRejectsNonRequestOrMismatchedEvidence(reason: String) throws {
        let frame = reason == "notification" ? Data(#"{"jsonrpc":"2.0","method":"notice"}"#.utf8) : (reason == "malformed" ? Data([255]) : nil)
        let (store, fence, stream, request) = try responseFixture(frame: frame, pending: reason == "missing-pending" ? nil : "opaque-helper")
        if reason == "changed-record" { try store.db.exec("UPDATE acp_v2_inbound_records SET frame = ?", bindings: [Data("changed".utf8)]) }
        let response = reason == "wrong-id" ? #"{"jsonrpc":"2.0","id":8,"result":null}"# : (reason == "invalid-response" ? "{}" : #"{"jsonrpc":"2.0","id":7,"result":null}"#)
        #expect(throws: (any Error).self) { try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(response.utf8), fence: fence) }
        #expect(try store.db.query("SELECT id FROM acp_v2_response_intents").isEmpty)
    }

    @Test(arguments: ["lease", "generation", "context", "sql"])
    func responseRegistrationAuthorityAndRollbackAreAtomic(reason: String) throws {
        let (store, fence, stream, request) = try responseFixture()
        if reason == "lease" { try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new") }
        if reason == "generation" { _ = try store.updateACPBrokerState(sessionId: "journal", brokerId: "broker", generation: 8, acknowledgedCursor: 0, wireContext: .rawV2) }
        if reason == "context" { try store.db.exec("UPDATE sessions SET acp_broker_wire_context = '{bad}'") }
        if reason == "sql" { try store.db.exec("CREATE TRIGGER fail_response AFTER INSERT ON acp_v2_response_intents BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        let saved = try store.loadSession(id: "journal")
        #expect(throws: (any Error).self) { try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence) }
        #expect(try store.db.query("SELECT id FROM acp_v2_response_intents").isEmpty)
        #expect(try store.loadSession(id: "journal") == saved)
    }

    private func responseStdioProof(_ intent: ACPV2ResponseIntent, _ attempt: ACPV2ResponseAttempt,
        status: ACPV2StdioReplyStatus) throws -> ACPV2StdioReplyResult {
        .init(connectionID: intent.request.connectionID, receiptID: intent.request.receiptID,
            requestID: try #require(intent.request.decodeHeader().id), operationKey: attempt.operationKey, status: status)
    }

    private func responseBrokerProof(_ intent: ACPV2ResponseIntent, _ attempt: ACPV2ResponseAttempt,
        status: ACPBrokerRawReplyStatus) throws -> ACPBrokerRawReplyResult {
        guard case .broker(let provenance, let pending) = intent.request.source else { throw ACPV2ResponseLedgerError.invalidInput }
        let params = ACPBrokerRespondExactParams(brokerId: provenance.brokerID, generation: provenance.generation,
            pendingRequestId: try #require(pending), originCursor: provenance.cursor,
            operationKey: .init(rawValue: attempt.operationKey.rawValue), frame: .init(bytes: intent.frame))
        return .init(params: params, status: status)
    }

    @Test(arguments: [false, true])
    func responseFactsRefineUncertaintyWithoutRegressingTerminalEvidence(broker: Bool) throws {
        let (store, fence, stream, request) = try responseFixture(broker: broker)
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        let attempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "answer"), fence: fence).value
        let id = UUID()
        let unknown = try store.retainV2ResponseObservation(id: id, for: attempt, evidence: .uncertain(message: "\u{feff}é\0"), fence: fence)
        #expect(try !store.retainV2ResponseObservation(id: id, for: attempt, evidence: .uncertain(message: "\u{feff}é\0"), fence: fence).wasInserted)
        #expect(unknown.value.sequence == 1)
        #expect(throws: ACPV2ResponseLedgerError.conflict) { try store.retainV2ResponseObservation(id: id, for: attempt, evidence: .uncertain(message: "\u{feff}e\u{301}\0"), fence: fence) }
        let terminal: ACPV2ResponseEvidence = broker ? .broker(try responseBrokerProof(intent, attempt, status: .written)) : .stdio(try responseStdioProof(intent, attempt, status: .written))
        _ = try store.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: terminal, fence: fence)
        let stale: ACPV2ResponseEvidence = broker ? .broker(try responseBrokerProof(intent, attempt, status: .inFlight)) : .stdio(try responseStdioProof(intent, attempt, status: .queued))
        _ = try store.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: stale, fence: fence)
        #expect(try ACPSessionStore(path: store.path).loadV2ResponseAttempt(id: attempt.id)?.recovery == .written)
        #expect(throws: ACPV2ResponseLedgerError.conflict) { try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "new"), fence: fence) }
    }

    @Test func responseNotWrittenPermitsOnlyAnExplicitNextAttempt() throws {
        let (store, fence, stream, request) = try responseFixture(broker: false)
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        let first = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "first"), fence: fence).value
        _ = try store.retainV2ResponseObservation(id: UUID(), for: first, evidence: .stdio(responseStdioProof(intent, first, status: .notWritten)), fence: fence)
        #expect(throws: ACPV2ResponseLedgerError.conflict) { try store.retainV2ResponseObservation(id: UUID(), for: first, evidence: .stdio(responseStdioProof(intent, first, status: .written)), fence: fence) }
        let reopened = try ACPSessionStore(path: store.path)
        let second = try reopened.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "second"), fence: fence).value
        #expect(second.sequence == 2)
        #expect(try reopened.loadV2ResponseAttempt(id: first.id)?.recovery == .notWritten)
        #expect(try reopened.loadV2ResponseAttempt(id: second.id)?.recovery == .uncertain)
        #expect(throws: ACPV2ResponseLedgerError.conflict) { try reopened.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "third"), fence: fence) }
        #expect(try reopened.db.query("SELECT id FROM acp_v2_response_observations").count == 1)
    }

    @Test(arguments: ["key", "request", "receipt", "connection", "source", "lease", "sql"])
    func responseObservationIdentityAndContradictionCannotMutateHistory(reason: String) throws {
        let (store, fence, stream, request) = try responseFixture(broker: false)
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        let attempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "é"), fence: fence).value
        let proof = ACPV2StdioReplyResult(connectionID: reason == "connection" ? UUID() : request.connectionID,
            receiptID: reason == "receipt" ? UUID() : request.receiptID, requestID: .number(reason == "request" ? 8 : 7),
            operationKey: reason == "key" ? .init(rawValue: "e\u{301}") : attempt.operationKey, status: .written)
        if reason == "lease" { try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new") }
        if reason == "sql" { try store.db.exec("CREATE TRIGGER fail_response_observation AFTER INSERT ON acp_v2_response_observations BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        let evidence: ACPV2ResponseEvidence = reason == "source" ? .broker(.init(params: .init(brokerId: .init(rawValue: "broker"), generation: .init(rawValue: 7), pendingRequestId: "opaque-helper", originCursor: .init(rawValue: 5), operationKey: .init(rawValue: "é"), frame: .init(bytes: intent.frame)), status: .written)) : .stdio(proof)
        #expect(throws: (any Error).self) { try store.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: evidence, fence: fence) }
        #expect(try store.db.query("SELECT id FROM acp_v2_response_observations").isEmpty)
        #expect(try store.loadV2ResponseAttempt(id: attempt.id)?.recovery == .uncertain)
    }

    @Test func responseAttemptKeysRemainExactAcrossDistinctReusedOrigins() throws {
        let (store, fence, stream, firstRequest) = try responseFixture()
        let bytes = Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)
        let first = try store.registerV2ResponseIntent(id: UUID(), request: firstRequest, in: stream, frame: bytes, fence: fence).value
        let secondRequest = try store.retainV2Inbound(inbound(firstRequest.frame, cursor: 6), to: stream, fence: fence).record
        let second = try store.registerV2ResponseIntent(id: UUID(), request: secondRequest, in: stream, frame: bytes, fence: fence).value
        let firstKey = ACPV2ReplyOperationKey(rawValue: "\u{feff}é\0")
        _ = try store.registerV2ResponseAttempt(id: UUID(), for: first, operationKey: firstKey, fence: fence)
        #expect(throws: ACPV2ResponseLedgerError.conflict) { try store.registerV2ResponseAttempt(id: UUID(), for: second, operationKey: firstKey, fence: fence) }
        let secondAttempt = try store.registerV2ResponseAttempt(id: UUID(), for: second, operationKey: .init(rawValue: "\u{feff}e\u{301}\0"), fence: fence)
        #expect(secondAttempt.value.sequence == 1)
    }

    @Test func responseRecoveryPagesKeepContextsAndOversizedPayloads() throws {
        let (store, fence, stream, request) = try responseFixture(broker: false)
        let frame = Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"\(String(repeating: "x", count: 512))\"}".utf8)
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: frame, fence: fence).value
        let nextRequest = try store.retainV2Inbound(.init(frame: request.frame, connectionID: request.connectionID, source: .stdio), to: stream, fence: fence).record
        let nextIntent = try store.registerV2ResponseIntent(id: UUID(), request: nextRequest, in: stream, frame: frame, fence: fence).value
        let attempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "\u{feff}é\0"), fence: fence).value
        let message = "\u{feff}" + String(repeating: "n", count: 200) + "\0"
        let observation = try store.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: .uncertain(message: message), fence: fence).value
        _ = try store.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: .stdio(responseStdioProof(intent, attempt, status: .notWritten)), fence: fence)
        let secondAttempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "second"), fence: fence).value
        let reopened = try ACPSessionStore(path: store.path)
        let first = try reopened.loadV2ResponseIntentPage(stream: stream, maxBytes: 16)
        #expect(first.records == [intent] && first.containsOversizedRecord && !first.isAtEnd)
        let byCount = try reopened.loadV2ResponseIntentPage(stream: stream, maxRecords: 1)
        #expect(byCount.records == [intent] && !byCount.isAtEnd && !byCount.containsOversizedRecord)
        let second = try reopened.loadV2ResponseIntentPage(stream: stream, after: first.next, maxBytes: 16)
        #expect(second.records == [nextIntent] && second.isAtEnd)
        let attempts = try reopened.loadV2ResponseAttemptPage(intentID: intent.id, maxBytes: 16)
        #expect(attempts.records.first?.attempt == attempt && attempts.records.first?.recovery == .notWritten)
        #expect(attempts.containsOversizedRecord && !attempts.isAtEnd)
        let final = try reopened.loadV2ResponseAttemptPage(intentID: intent.id, after: attempts.next, maxBytes: 16)
        #expect(final.records.first?.attempt == secondAttempt && final.records.first?.recovery == .uncertain && final.isAtEnd)
        let observations = try reopened.loadV2ResponseObservationPage(attemptID: attempt.id, maxBytes: 16)
        #expect(observations.records == [observation] && observations.containsOversizedRecord && !observations.isAtEnd)
        #expect(try reopened.loadV2ResponseObservationPage(attemptID: attempt.id, after: observations.next).records.count == 1)
        #expect(try reopened.loadV2ResponseObservationPage(attemptID: secondAttempt.id).records.isEmpty)
        let empty = try reopened.loadV2ResponseAttemptPage(intentID: nextIntent.id, maxBytes: 16)
        #expect(empty.records.isEmpty && empty.isAtEnd && empty.containsOversizedRecord)
        #expect(throws: ACPV2ResponseLedgerError.invalidInput) { try reopened.loadV2ResponseIntentPage(stream: stream, after: .init(kind: .observations, parentID: stream.id, afterSequence: 1)) }
        #expect(throws: ACPV2ResponseLedgerError.invalidInput) { try reopened.loadV2ResponseAttemptPage(intentID: nextIntent.id, after: attempts.next) }
        #expect(throws: ACPV2ResponseLedgerError.invalidInput) { try reopened.loadV2ResponseObservationPage(attemptID: attempt.id, maxRecords: 0) }
        #expect(throws: ACPV2ResponseLedgerError.invalidInput) { try reopened.loadV2ResponseIntentPage(stream: stream, maxBytes: 0) }
    }

    @Test(arguments: ["intent-format", "attempt-format", "key-type", "key-utf8", "namespace", "message-utf8", "observation-id", "observation-status"])
    func responseRecoveryRejectsCorruptMetadataInsteadOfRepairingIt(field: String) throws {
        let (store, fence, stream, request) = try responseFixture()
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        let attempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "key"), fence: fence).value
        _ = try store.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: .uncertain(message: "message"), fence: fence)
        switch field {
        case "intent-format": try store.db.exec("UPDATE acp_v2_response_intents SET format_version = 9")
        case "attempt-format": try store.db.exec("UPDATE acp_v2_response_attempts SET format_version = 9")
        case "key-type": try store.db.exec("UPDATE acp_v2_response_attempts SET operation_key = 'key'")
        case "key-utf8": try store.db.exec("UPDATE acp_v2_response_attempts SET operation_key = x'ff'")
        case "namespace": try store.db.exec("UPDATE acp_v2_response_attempts SET namespace = x'ff'")
        case "message-utf8": try store.db.exec("UPDATE acp_v2_response_observations SET message = x'ff'")
        case "observation-id": try store.db.exec("UPDATE acp_v2_response_observations SET id = 'invalid'")
        default: try store.db.exec("UPDATE acp_v2_response_observations SET kind = 1, status = 4, message = NULL")
        }
        if field == "intent-format" { #expect(throws: (any Error).self) { try store.loadV2ResponseIntent(id: intent.id) } }
        else if field == "message-utf8" { #expect(throws: ACPV2ResponseLedgerError.corruptRecord) { try store.loadV2ResponseObservationPage(attemptID: attempt.id) } }
        else { #expect(throws: (any Error).self) { try store.loadV2ResponseAttempt(id: attempt.id) } }
    }

    @Test func responseHistorySurvivesLostLeaseAndChangedCurrentGenerationWithoutGrantingRetry() throws {
        let (store, fence, stream, request) = try responseFixture()
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        let attempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "key"), fence: fence).value
        try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        _ = try store.updateACPBrokerState(sessionId: "journal", brokerId: "broker", generation: 8, acknowledgedCursor: 0, wireContext: .rawV2)
        let reopened = try ACPSessionStore(path: store.path)
        #expect(try reopened.loadV2ResponseIntent(id: intent.id) == intent)
        #expect(try reopened.loadV2ResponseAttempt(id: attempt.id)?.recovery == .uncertain)
        #expect(try reopened.loadV2ResponseIntentPage(stream: stream).records == [intent])
        #expect(try reopened.loadV2ResponseObservationPage(attemptID: attempt.id).isAtEnd)
        #expect(throws: ACPV2ResponseLedgerError.staleLease) { try reopened.registerV2ResponseAttempt(id: attempt.id, for: intent, operationKey: attempt.operationKey, fence: fence) }
        let currentFence = ACPSessionLeaseFence(sessionId: "journal", ownerInstance: "B", token: "new")
        #expect(throws: ACPV2ResponseLedgerError.incompatibleSource) { try reopened.registerV2ResponseAttempt(id: attempt.id, for: intent, operationKey: attempt.operationKey, fence: currentFence) }
        #expect(throws: ACPV2ResponseLedgerError.incompatibleSource) { try reopened.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: .uncertain(message: "lost"), fence: currentFence) }
    }

    @Test(arguments: ["pending", "cursor", "generation", "broker", "key"])
    func responseBrokerFactsRequireTheExactOriginalBinding(field: String) throws {
        let pending = "\u{feff}é\0"
        let (store, fence, stream, _) = try responseFixture()
        let request = try store.retainV2Inbound(inbound(Data(#"{"jsonrpc":"2.0","id":7,"method":"m"}"#.utf8), cursor: 6, pending: pending), to: stream, fence: fence).record
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        let attempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "é"), fence: fence).value
        let params = ACPBrokerRespondExactParams(brokerId: .init(rawValue: field == "broker" ? "other" : "broker"), generation: .init(rawValue: field == "generation" ? 8 : 7),
            pendingRequestId: field == "pending" ? "\u{feff}e\u{301}\0" : pending, originCursor: .init(rawValue: field == "cursor" ? 5 : 6),
            operationKey: .init(rawValue: field == "key" ? "e\u{301}" : "é"), frame: .init(bytes: intent.frame))
        #expect(throws: ACPV2ResponseLedgerError.incompatibleSource) { try store.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: .broker(.init(params: params, status: .written)), fence: fence) }
        #expect(try store.loadV2ResponseAttempt(id: attempt.id)?.recovery == .uncertain)
    }

    @Test(arguments: [false, true])
    func responseStringIDsMustKeepTheirExactUnicodeSpelling(mismatch: Bool) throws {
        let (store, fence, stream, request) = try responseFixture(frame: Data(#"{"jsonrpc":"2.0","id":"é","method":"m"}"#.utf8))
        let frame = Data((mismatch ? #"{"jsonrpc":"2.0","id":"e\u0301","result":null}"# : #"{"jsonrpc":"2.0","id":"é","result":null}"#).utf8)
        if mismatch {
            #expect(throws: ACPV2ResponseLedgerError.invalidInput) { try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: frame, fence: fence) }
        } else { #expect(try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: frame, fence: fence).value.frame == frame) }
    }

    @Test func responseAttemptInsertFailureDoesNotReserveTheNextKeyOrSequence() throws {
        let (store, fence, stream, request) = try responseFixture(broker: false)
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        let first = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "first"), fence: fence).value
        _ = try store.retainV2ResponseObservation(id: UUID(), for: first, evidence: .stdio(responseStdioProof(intent, first, status: .notWritten)), fence: fence)
        try store.db.exec("CREATE TRIGGER fail_response_attempt AFTER INSERT ON acp_v2_response_attempts BEGIN SELECT RAISE(ABORT, 'injected'); END")
        let id = UUID()
        #expect(throws: SQLiteError.self) { try store.registerV2ResponseAttempt(id: id, for: intent, operationKey: .init(rawValue: "second"), fence: fence) }
        try store.db.exec("DROP TRIGGER fail_response_attempt")
        #expect(try store.registerV2ResponseAttempt(id: id, for: intent, operationKey: .init(rawValue: "second"), fence: fence).value.sequence == 2)
    }

    @Test(arguments: ["request", "answer", "pending", "upstream"])
    func responseIntentCannotBeReboundByChangingValidParentEvidence(field: String) throws {
        let (store, fence, stream, request) = try responseFixture()
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        switch field {
        case "request": try store.db.exec("UPDATE acp_v2_inbound_records SET frame = ?", bindings: [Data(#"{"jsonrpc":"2.0","id":7,"method":"different"}"#.utf8)])
        case "answer": try store.db.exec("UPDATE acp_v2_response_intents SET frame = ?", bindings: [Data(#"{"jsonrpc":"2.0","id":7,"result":true}"#.utf8)])
        case "pending": try store.db.exec("UPDATE acp_v2_inbound_records SET pending_request_id = 'different'")
        default: try store.db.exec("UPDATE acp_v2_inbound_streams SET upstream_session_id = 'different'")
        }
        #expect(throws: ACPV2ResponseLedgerError.corruptRecord) { try store.loadV2ResponseIntent(id: intent.id) }
    }

    @Test func corruptObservationUUIDCannotGrantASecondResponseAttempt() throws {
        let (store, fence, stream, request) = try responseFixture(broker: false)
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        let attempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "first"), fence: fence).value
        let observation = try store.retainV2ResponseObservation(id: UUID(), for: attempt, evidence: .stdio(responseStdioProof(intent, attempt, status: .notWritten)), fence: fence).value
        try store.db.exec("UPDATE acp_v2_response_observations SET id = ?", bindings: [observation.id.uuidString + "\0suffix"])
        #expect(throws: ACPV2ResponseLedgerError.corruptRecord) { try store.loadV2ResponseAttempt(id: attempt.id) }
        #expect(throws: ACPV2ResponseLedgerError.corruptRecord) { try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "second"), fence: fence) }
        #expect(try store.db.query("SELECT id FROM acp_v2_response_attempts").count == 1)
    }

    @Test(arguments: ["binding", "large-digest", "digest-type", "key", "namespace", "large-parent-id"])
    func emptyResponseHistoryStillValidatesItsRequestedParent(field: String) throws {
        let (store, fence, stream, request) = try responseFixture()
        let intent = try store.registerV2ResponseIntent(id: UUID(), request: request, in: stream, frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8), fence: fence).value
        if ["binding", "large-digest", "digest-type"].contains(field) {
            switch field {
            case "binding": try store.db.exec("UPDATE acp_v2_response_intents SET binding_digest = zeroblob(32)")
            case "large-digest": try store.db.exec("UPDATE acp_v2_response_intents SET binding_digest = zeroblob(1048576)")
            default: try store.db.exec("UPDATE acp_v2_response_intents SET binding_digest = 'not-a-digest'")
            }
            #expect(throws: ACPV2ResponseLedgerError.corruptRecord) { try store.loadV2ResponseAttemptPage(intentID: intent.id, maxBytes: 16) }
            #expect(throws: ACPV2ResponseLedgerError.corruptRecord) { try store.loadV2ResponseIntentPage(stream: stream, maxBytes: 16) }
        } else {
            let attempt = try store.registerV2ResponseAttempt(id: UUID(), for: intent, operationKey: .init(rawValue: "first"), fence: fence).value
            switch field {
            case "key": try store.db.exec("UPDATE acp_v2_response_attempts SET operation_key = x'ff'")
            case "namespace": try store.db.exec("UPDATE acp_v2_response_attempts SET namespace = zeroblob(1048576)")
            default:
                // Disable constraints only to simulate persisted corrupt metadata.
                try store.db.exec("PRAGMA foreign_keys = OFF")
                try store.db.exec("UPDATE acp_v2_response_attempts SET intent_id = ?", bindings: [intent.id.uuidString + "\0" + String(repeating: "x", count: 1024)])
            }
            #expect(throws: ACPV2ResponseLedgerError.corruptRecord) { try store.loadV2ResponseObservationPage(attemptID: attempt.id, maxBytes: 16) }
        }
    }

    private func submission(_ store: ACPSessionStore, fence: ACPSessionLeaseFence, id: UUID = UUID(),
        row: UUID = UUID(), binding: ACPV2SubmissionBinding? = nil) throws -> ACPV2SubmissionRegistration {
        try store.registerV2Submission(id: id, sessionId: "journal", upstreamSessionId: "upstream", localRowID: row,
            binding: binding ?? .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 7), operationKey: .init(rawValue: UUID().uuidString)), fence: fence)
    }

    @Test(arguments: [JSONRPCID.number(-7), .string("prefix:7")])
    func submissionRegistrationKeepsWireAndLocalIdentityAcrossReopen(wireID: JSONRPCID) throws {
        let (store, fence, _) = try journalFixture()
        let connection = UUID()
        let binding = ACPV2SubmissionBinding.stdio(connectionID: connection, requestID: wireID)
        let first = try submission(store, fence: fence, binding: binding)
        let reopened = try ACPSessionStore(path: store.path)
        let retry = try submission(reopened, fence: fence, id: first.id, row: first.localRowID, binding: binding)
        #expect(retry == first)
        #expect(first.sequence == 1)
        let other = try submission(reopened, fence: fence, binding: .stdio(connectionID: UUID(), requestID: wireID))
        #expect(other.sequence == 2)
        #expect(other.localRowID != first.localRowID)
        #expect(throws: ACPV2SubmissionLedgerError.conflict) { try submission(reopened, fence: fence, binding: binding) }
        #expect(throws: ACPV2SubmissionLedgerError.conflict) { try submission(reopened, fence: fence, id: first.id, binding: binding) }
        #expect(throws: ACPV2SubmissionLedgerError.conflict) {
            try submission(reopened, fence: fence, row: first.localRowID, binding: .stdio(connectionID: connection, requestID: .number(8)))
        }
        let laterAttempt = try submission(reopened, fence: fence, row: first.localRowID,
            binding: .stdio(connectionID: UUID(), requestID: wireID))
        #expect(laterAttempt.sequence == 3)
    }

    @Test(arguments: ["lease", "session", "generation", "context", "id", "exhausted"])
    func invalidSubmissionRegistrationCannotAllocateAnAttempt(reason: String) throws {
        let (store, original, _) = try journalFixture()
        var fence = original
        var binding = ACPV2SubmissionBinding.broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 7), operationKey: .init(rawValue: "op"))
        switch reason {
        case "lease": try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        case "session": fence = .init(sessionId: "elsewhere", ownerInstance: "A", token: "owner")
        case "generation": binding = .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: .max), operationKey: .init(rawValue: "op"))
        case "context": try store.db.exec("UPDATE sessions SET acp_broker_wire_context = '{future}' WHERE id = 'journal'")
        case "id": binding = .broker(id: .init(rawValue: "bad/id"), generation: .init(rawValue: 7), operationKey: .init(rawValue: "op"))
        default:
            _ = try submission(store, fence: fence)
            try store.db.exec("UPDATE acp_v2_submissions SET sequence = ?", bindings: [Int64.max])
        }
        let count = try store.db.query("SELECT id FROM acp_v2_submissions").count
        #expect(throws: (any Error).self) { try submission(store, fence: fence, binding: binding) }
        #expect(try store.db.query("SELECT id FROM acp_v2_submissions").count == count)
    }

    private func submissionDelivery(_ registration: ACPV2SubmissionRegistration, frame: Data,
        cursor: UInt64 = 5, requestID: UInt64 = .max, origin: ACPBrokerFrameProvenance.Origin = .journal,
        callback: ACPDurableConsumptionAcknowledgement? = nil) -> ACPRawRPCDelivery {
        switch registration.binding {
        case .stdio(let connection, let id):
            return .init(frame: frame, connectionID: connection, source: .stdio(requestID: id, method: "session/prompt"),
                durableConsumptionAcknowledgement: callback)
        case .broker(let id, let generation, let key):
            return .init(frame: frame, connectionID: UUID(), source: .brokerOperation(operationKey: key,
                requestID: .init(rawValue: requestID), method: "session/prompt"),
                brokerProvenance: .init(brokerID: id, generation: generation, cursor: .init(rawValue: cursor), origin: origin),
                durableConsumptionAcknowledgement: callback)
        }
    }

    @Test(arguments: ["accepted", "error", "malformed", "wrong-id", "bad-result", "empty"])
    func submissionOutcomesRetainExactEvidenceAndInterpretConservatively(kind: String) throws {
        let (store, fence, _) = try journalFixture()
        let registration = try submission(store, fence: fence)
        let before = try #require(try store.loadV2Submission(id: registration.id))
        #expect(before.recovery == .uncertain)
        let text: String
        switch kind {
        case "accepted": text = " \n{\"jsonrpc\":\"2.0\",\"id\":18446744073709551615,\"result\":{\"messageId\":\"m\",\"future\":1e999}}\n"
        case "error": text = #"{"jsonrpc":"2.0","id":18446744073709551615,"error":{"code":-32044,"message":"failed","data":{"n":1e999}}}"#
        case "wrong-id": text = #"{"jsonrpc":"2.0","id":7,"result":{"messageId":"wrong"}}"#
        case "bad-result": text = #"{"jsonrpc":"2.0","id":18446744073709551615,"result":null}"#
        case "empty": text = ""
        default: text = "{broken"
        }
        let bytes = Data(text.utf8)
        let consumed = Mutex(0)
        let delivery = submissionDelivery(registration, frame: bytes, callback: { consumed.withLock { $0 += 1 } })
        let first = try store.retainV2SubmissionOutcome(delivery, for: registration, fence: fence)
        #expect(first.wasInserted)
        let outcome = try #require(first.record.outcome)
        #expect(outcome.frame == bytes)
        #expect(outcome.receiptID == delivery.receiptID)
        let reopened = try ACPSessionStore(path: store.path)
        #expect(try reopened.loadV2Submission(id: registration.id) == first.record)
        switch first.record.recovery {
        case .accepted(let acceptance):
            #expect(kind == "accepted")
            #expect(acceptance.messageID == "m")
            guard case .object(let fields) = acceptance.rawValue else { Issue.record("Missing acceptance object")
            return }
            #expect(fields["future"] == .number("1e999"))
        case .rpcFailure: #expect(kind == "error")
        case .uninterpretable: #expect(!["accepted", "error"].contains(kind))
        case .uncertain: Issue.record("Committed outcome became uncertain")
        }
        #expect(try reopened.updateACPBrokerAcknowledgedCursor(sessionId: "journal", brokerId: "broker", generation: 7, cursor: 8, wireContext: .rawV2))
        let retry = try reopened.retainV2SubmissionOutcome(submissionDelivery(registration, frame: bytes, origin: .pendingSnapshot), for: registration, fence: fence)
        #expect(!retry.wasInserted)
        #expect(retry.record == first.record)
        #expect(consumed.withLock { $0 } == 0)
        delivery.acknowledgeDurableConsumption()
        #expect(consumed.withLock { $0 } == 1)
    }

    @Test func reversedStdioResponsesPreserveExactLocalRowAssociations() throws {
        let (store, fence, _) = try journalFixture()
        let connection = UUID()
        let a = try submission(store, fence: fence, binding: .stdio(connectionID: connection, requestID: .number(-7)))
        let b = try submission(store, fence: fence, binding: .stdio(connectionID: connection, requestID: .string("prefix:7")))
        for (registration, json) in [(b, #"{"jsonrpc":"2.0","id":"prefix:7","result":{"messageId":"b"}}"#),
            (a, #"{"jsonrpc":"2.0","id":-7,"result":{"messageId":"a"}}"#)] {
            let delivery = submissionDelivery(registration, frame: Data(json.utf8))
            let receipt = try store.retainV2SubmissionOutcome(delivery, for: registration, fence: fence)
            #expect(receipt.record.registration.localRowID == registration.localRowID)
            #expect(try store.retainV2SubmissionOutcome(delivery, for: registration, fence: fence).wasInserted == false)
        }
        guard case .accepted(let acceptedA)? = try store.loadV2Submission(id: a.id)?.recovery,
              case .accepted(let acceptedB)? = try store.loadV2Submission(id: b.id)?.recovery else { Issue.record("Lost acceptance")
              return }
        #expect(acceptedA.messageID == "a")
        #expect(acceptedB.messageID == "b")
    }

    @Test(arguments: ["lease", "descriptor", "cache", "diagnostic", "method", "cursor", "request", "bytes"])
    func rejectedSubmissionOutcomeCannotReplaceEvidenceOrConsume(reason: String) throws {
        let (store, fence, _) = try journalFixture()
        let registration = try submission(store, fence: fence)
        let frame = Data(#"{"jsonrpc":"2.0","id":18446744073709551615,"result":{"messageId":"m"}}"#.utf8)
        let original = try store.retainV2SubmissionOutcome(submissionDelivery(registration, frame: frame), for: registration, fence: fence)
        let count = Mutex(0)
        let callback: ACPDurableConsumptionAcknowledgement = { count.withLock { $0 += 1 } }
        var delivery = submissionDelivery(registration, frame: reason == "bytes" ? Data([255]) : frame,
            cursor: reason == "cursor" ? 6 : 5, requestID: reason == "request" ? 7 : .max, callback: callback)
        switch reason {
        case "lease": try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        case "descriptor": _ = try store.updateACPBrokerState(sessionId: "journal", brokerId: "broker", generation: 8, acknowledgedCursor: 0, wireContext: .rawV2)
        case "cache", "diagnostic": delivery = .init(frame: frame, connectionID: UUID(), source: reason == "cache" ? .brokerSnapshotCache : .diagnostic, durableConsumptionAcknowledgement: callback)
        case "method": delivery = .init(frame: frame, connectionID: UUID(), source: .brokerOperation(operationKey: .init(rawValue: "other"), requestID: .init(rawValue: .max), method: "initialize"), durableConsumptionAcknowledgement: callback)
        default: break
        }
        #expect(throws: (any Error).self) { try store.retainV2SubmissionOutcome(delivery, for: registration, fence: fence) }
        #expect(try store.loadV2Submission(id: registration.id) == original.record)
        #expect(count.withLock { $0 } == 0)
    }

    @Test func failedSubmissionCommitLeavesNoOutcomeOrConsumption() throws {
        let (store, fence, _) = try journalFixture()
        let registration = try submission(store, fence: fence)
        let consumed = Mutex(0)
        let delivery = submissionDelivery(registration, frame: Data([255, 0]), callback: { consumed.withLock { $0 += 1 } })
        try store.db.exec("CREATE TRIGGER fail_submission AFTER INSERT ON acp_v2_submission_outcomes BEGIN SELECT RAISE(ABORT, 'failure'); END")
        #expect(throws: SQLiteError.self) { try store.retainV2SubmissionOutcome(delivery, for: registration, fence: fence) }
        #expect(try store.loadV2Submission(id: registration.id)?.recovery == .uncertain)
        try store.db.exec("DROP TRIGGER fail_submission")
        #expect(try store.retainV2SubmissionOutcome(delivery, for: registration, fence: fence).wasInserted)
        #expect(consumed.withLock { $0 } == 0)
    }

    @Test func oneTransportBindingCannotBeClaimedByAnotherLocalSession() throws {
        let (store, fence, _) = try journalFixture()
        let binding = ACPV2SubmissionBinding.stdio(connectionID: UUID(), requestID: .string("same:1"))
        _ = try submission(store, fence: fence, binding: binding)
        try store.upsertSession(.init(id: "other-local", agentId: "fixture", title: "Other", autoRun: false,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        try store.seizeLease(sessionId: "other-local", instanceId: "A", pid: 1, now: 1, leaseToken: "other")
        #expect(throws: ACPV2SubmissionLedgerError.conflict) {
            try store.registerV2Submission(id: UUID(), sessionId: "other-local", upstreamSessionId: "another-upstream", localRowID: UUID(),
                binding: binding, fence: .init(sessionId: "other-local", ownerInstance: "A", token: "other"))
        }
    }

    @Test func submissionRecoveryPagesBoundFramesAndRejectForeignPositions() throws {
        let (store, fence, _) = try journalFixture()
        let connection = UUID()
        var registrations: [ACPV2SubmissionRegistration] = []
        for index in 1...4 {
            registrations.append(try submission(store, fence: fence, binding: .stdio(connectionID: connection, requestID: .number(index))))
        }
        for (registration, size) in zip(registrations, [3, 3, 8]) {
            _ = try store.retainV2SubmissionOutcome(submissionDelivery(registration, frame: Data(repeating: 255, count: size)), for: registration, fence: fence)
        }
        let source = ACPV2SubmissionSource.stdio(connectionID: connection)
        let first = try store.loadV2SubmissionPage(sessionId: "journal", upstreamSessionId: "upstream", source: source, maxRecords: 3, maxBytes: 4)
        #expect(first.records.map(\.registration.sequence) == [1])
        let second = try store.loadV2SubmissionPage(sessionId: "journal", upstreamSessionId: "upstream", source: source, after: first.next, maxRecords: 1, maxBytes: 4)
        #expect(second.records.map(\.registration.sequence) == [2])
        let oversized = try store.loadV2SubmissionPage(sessionId: "journal", upstreamSessionId: "upstream", source: source, after: second.next, maxBytes: 1)
        #expect(oversized.records.map(\.registration.sequence) == [3])
        #expect(oversized.containsOversizedRecord)
        #expect(!oversized.isAtEnd)
        let end = try store.loadV2SubmissionPage(sessionId: "journal", upstreamSessionId: "upstream", source: source, after: oversized.next, maxBytes: 1)
        #expect(end.records.map(\.registration.sequence) == [4])
        #expect(end.records.first?.recovery == .uncertain)
        #expect(end.isAtEnd)
        #expect(end.next == nil)
        for bad in [ACPV2SubmissionContinuation(sessionId: "other", upstreamSessionId: "upstream", source: source, afterSequence: 1),
            .init(sessionId: "journal", upstreamSessionId: "upstream", source: .stdio(connectionID: UUID()), afterSequence: 1),
            .init(sessionId: "journal", upstreamSessionId: "upstream", source: source, afterSequence: 99),
            .init(sessionId: "journal", upstreamSessionId: "upstream", source: source, afterSequence: -1)] {
            #expect(throws: ACPV2SubmissionLedgerError.invalidInput) {
                try store.loadV2SubmissionPage(sessionId: "journal", upstreamSessionId: "upstream", source: source, after: bad)
            }
        }
        for (count, bytes) in [(0, 1), (1001, 1), (1, 0), (1, Int.max)] {
            #expect(throws: ACPV2SubmissionLedgerError.invalidInput) {
                try store.loadV2SubmissionPage(sessionId: "journal", upstreamSessionId: "upstream", source: source, maxRecords: count, maxBytes: bytes)
            }
        }
        #expect(try store.loadV2SubmissionPage(sessionId: "journal", upstreamSessionId: "different", source: source).records.isEmpty)
    }

    @Test(arguments: ["format", "context", "source", "receipt", "interpretation", "broker-request"])
    func corruptSubmissionMetadataFailsWithoutRewritingEvidence(reason: String) throws {
        let (store, fence, _) = try journalFixture()
        let registration = try submission(store, fence: fence)
        _ = try store.retainV2SubmissionOutcome(submissionDelivery(registration, frame: Data()), for: registration, fence: fence)
        switch reason {
        case "format": try store.db.exec("UPDATE acp_v2_submissions SET format_version = 99")
        case "context": try store.db.exec("UPDATE acp_v2_submissions SET wire_context = '{future}'")
        case "source": try store.db.exec("UPDATE acp_v2_submissions SET source_key = 'wrong'")
        case "receipt": try store.db.exec("UPDATE acp_v2_submission_outcomes SET receipt_id = 'wrong'")
        case "interpretation": try store.db.exec("UPDATE acp_v2_submission_outcomes SET interpretation = 'accepted', message_id = 'fiction'")
        default: try store.db.exec("UPDATE acp_v2_submission_outcomes SET broker_request_id = '18446744073709551616'")
        }
        #expect(throws: (any Error).self) { try store.loadV2Submission(id: registration.id) }
        #expect(try store.db.query("SELECT frame FROM acp_v2_submission_outcomes").first?["frame"] as? Data == Data())
    }

    @Test func submissionHistorySurvivesBrokerReplacementUntilSessionDeletion() throws {
        let (store, fence, _) = try journalFixture()
        try store.enableReplicaExport(sessionId: "journal", recordId: "replica")
        let serial = try store.db.query("SELECT serial FROM session_replica_serial").first?["serial"] as? Int64
        let registration = try submission(store, fence: fence)
        _ = try store.retainV2SubmissionOutcome(submissionDelivery(registration, frame: Data([0, 255])), for: registration, fence: fence)
        #expect(try store.db.query("SELECT serial FROM session_replica_serial").first?["serial"] as? Int64 == serial)
        #expect(try store.clearACPBrokerState(sessionId: "journal"))
        #expect(try store.updateACPBrokerState(sessionId: "journal", brokerId: "broker", generation: 8, acknowledgedCursor: 0, wireContext: .rawV2))
        _ = try submission(store, fence: fence, row: registration.localRowID,
            binding: .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 8), operationKey: .init(rawValue: "new")))
        try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        let reopened = try ACPSessionStore(path: store.path)
        let history = try reopened.loadV2SubmissionPage(sessionId: "journal", upstreamSessionId: "upstream", source: registration.binding.source)
        #expect(history.records.map(\.registration.id) == [registration.id])
        #expect(history.records.first?.outcome?.frame == Data([0, 255]))
        #expect(try reopened.loadV2Submission(id: registration.id) != nil)
        try reopened.deleteSession(id: "journal")
        #expect(try reopened.loadV2Submission(id: registration.id) == nil)
        #expect(try reopened.db.query("SELECT submission_id FROM acp_v2_submission_outcomes").isEmpty)
    }

    @Test(arguments: [false, true])
    func recoveredAcceptanceReconcilesEchoWithoutInventingForegroundCompletion(echoFirst: Bool) throws {
        let (store, fence, _) = try journalFixture()
        let registration = try submission(store, fence: fence)
        let frame = Data(#"{"jsonrpc":"2.0","id":18446744073709551615,"result":{"messageId":"user"}}"#.utf8)
        _ = try store.retainV2SubmissionOutcome(submissionDelivery(registration, frame: frame), for: registration, fence: fence)
        let loaded = try #require(try ACPSessionStore(path: store.path).loadV2Submission(id: registration.id))
        guard case .accepted(let accepted) = loaded.recovery else { Issue.record("Missing acceptance")
        return }
        let context = ACPV2SessionState.Context(sessionID: "upstream", connectionID: UUID())
        var state = ACPV2SessionState(context: context)
        #expect(state.register(requestID: loaded.registration.sequence, localRowID: loaded.registration.localRowID, context: context).disposition == .registered)
        let echo = try ACPV2SessionUpdateEnvelope.decode(from: Data(#"{"sessionId":"upstream","update":{"sessionUpdate":"user_message","messageId":"user","content":[{"type":"text","text":"same"}]}}"#.utf8))
        if echoFirst { _ = try state.apply(echo, source: .snapshot, context: context) }
        #expect(state.accept(requestID: loaded.registration.sequence, response: accepted, context: context).disposition == .accepted)
        if !echoFirst { _ = try state.apply(echo, source: .snapshot, context: context) }
        #expect(state.transcript.messages.first?.localRowID == registration.localRowID)
        #expect(state.lifecycle.lastForegroundCompletion == nil)
    }

    private func journalFixture(source: ACPV2UpdateJournalSource? = nil) throws -> (ACPSessionStore, ACPSessionLeaseFence, ACPV2UpdateJournalStream) {
        let store = try tmp()
        try store.upsertSession(.init(id: "journal", agentId: "fixture", title: "Journal", autoRun: false,
            acpBrokerId: "broker", acpBrokerGeneration: 7, acpBrokerWireContextJSON: try ACPBrokerWireContext.rawV2.persistedJSON(),
            acpBrokerAcknowledgedCursor: 4, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        try store.seizeLease(sessionId: "journal", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        let fence = ACPSessionLeaseFence(sessionId: "journal", ownerInstance: "A", token: "owner")
        let stream = try store.registerV2UpdateJournal(sessionId: "journal", upstreamSessionId: "upstream",
            source: source ?? .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 7)), fence: fence)
        return (store, fence, stream)
    }

    private func brokerDelivery(_ bytes: Data, cursor: UInt64 = 5, origin: ACPBrokerFrameProvenance.Origin = .journal,
        callback: ACPDurableConsumptionAcknowledgement? = nil) -> ACPV2SessionUpdateDelivery {
        ACPV2SessionUpdateDelivery(frame: bytes, connectionID: UUID(),
            brokerProvenance: .init(brokerID: .init(rawValue: "broker"), generation: .init(rawValue: 7),
                cursor: .init(rawValue: cursor), origin: origin), durableConsumptionAcknowledgement: callback)
    }

    @Test func brokerReceiptRetriesRetainOriginalEvidenceAcrossReopenAndAck() throws {
        let (store, fence, stream) = try journalFixture()
        let bytes = Data(" \n{\"n\":1e999,\"n\":2,\"big\":123456789012345678901234567890}\n".utf8)
        let first = try store.appendV2Update(brokerDelivery(bytes), to: stream, fence: fence)
        #expect(first.wasInserted)
        #expect(first.record.ordinal == 1)
        #expect(try store.updateACPBrokerAcknowledgedCursor(sessionId: "journal", brokerId: "broker", generation: 7, cursor: 8, wireContext: .rawV2))
        let reopened = try ACPSessionStore(path: store.path)
        let registered = try reopened.registerV2UpdateJournal(sessionId: "journal", upstreamSessionId: "upstream", source: stream.source, fence: fence)
        #expect(registered == stream)
        #expect(registered.initialBrokerCursor?.rawValue == 4)
        let retry = try reopened.appendV2Update(brokerDelivery(bytes, origin: .pendingSnapshot), to: registered, fence: fence)
        #expect(!retry.wasInserted)
        #expect(retry.record == first.record)
        let next = try reopened.appendV2Update(brokerDelivery(Data([0, 255, 128]), cursor: 6), to: registered, fence: fence)
        #expect(next.record.ordinal == 2)
        #expect(next.record.frame == Data([0, 255, 128]))
        #expect(throws: ACPV2UpdateJournalError.conflictingReceipt) {
            try reopened.appendV2Update(brokerDelivery(Data("changed".utf8)), to: registered, fence: fence)
        }
        #expect(throws: ACPV2UpdateJournalError.incompatibleStream) {
            try reopened.registerV2UpdateJournal(sessionId: "journal", upstreamSessionId: "different", source: stream.source, fence: fence)
        }
        #expect(try reopened.loadSession(id: "journal")?.acpBrokerAcknowledgedCursor == 8)
    }

    @Test(arguments: [Data(), Data([0, 255, 192, 128]), Data("  {\"n\":1e999}\n".utf8)])
    func equalStdioChunksKeepDistinctReceiptsWhileCopiesRetryOnce(bytes: Data) throws {
        let connection = UUID()
        let (store, fence, stream) = try journalFixture(source: .stdio(connectionID: connection))
        let original = ACPV2SessionUpdateDelivery(frame: bytes, connectionID: connection)
        let copy = original
        let a = try store.appendV2Update(original, to: stream, fence: fence)
        let b = try store.appendV2Update(copy, to: stream, fence: fence)
        let c = try store.appendV2Update(.init(frame: bytes, connectionID: connection), to: stream, fence: fence)
        #expect(a.record == b.record)
        #expect(!b.wasInserted)
        #expect(c.record.ordinal == 2)
        #expect(c.record.frame == bytes)
        let row = try #require(try store.db.query("SELECT typeof(frame) AS kind, length(frame) AS size FROM acp_v2_update_records WHERE stream_id = ? AND ordinal = 1", bindings: [stream.id.uuidString]).first)
        #expect(row["kind"] as? String == "blob")
        #expect(row["size"] as? Int64 == Int64(bytes.count))
    }

    @Test(arguments: ["lease", "generation", "opaque", "legacy", "cursor-range", "wrong-session"])
    func invalidJournalAuthorityCannotInsertOrAdvanceAck(reason: String) throws {
        let (store, originalFence, stream) = try journalFixture()
        var fence = originalFence
        switch reason {
        case "lease": try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        case "generation": _ = try store.updateACPBrokerState(sessionId: "journal", brokerId: "broker", generation: 8, acknowledgedCursor: 0, wireContext: .rawV2)
        case "opaque": try store.db.exec("UPDATE sessions SET acp_broker_wire_context = '{future}' WHERE id = 'journal'")
        case "legacy": try store.db.exec("UPDATE sessions SET acp_broker_wire_context = NULL WHERE id = 'journal'")
        case "wrong-session": fence = .init(sessionId: "elsewhere", ownerInstance: "A", token: "owner")
        default: break
        }
        let before = try store.loadSession(id: "journal")
        let received = Mutex(0)
        let delivery = brokerDelivery(Data("evidence".utf8), cursor: reason == "cursor-range" ? .max : 5,
            callback: { received.withLock { $0 += 1 } })
        #expect(throws: (any Error).self) { try store.appendV2Update(delivery, to: stream, fence: fence) }
        #expect(try store.db.query("SELECT ordinal FROM acp_v2_update_records").isEmpty)
        #expect(try store.loadSession(id: "journal") == before)
        #expect(received.withLock { $0 } == 0)
    }

    @Test func failedJournalInsertRollsBackBeforeReceiptOrExplicitConsumption() throws {
        let (store, fence, stream) = try journalFixture()
        let consumed = Mutex(0)
        let delivery = brokerDelivery(Data(), callback: { consumed.withLock { $0 += 1 } })
        try store.db.exec("CREATE TRIGGER fail_receipt AFTER INSERT ON acp_v2_update_records BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        #expect(throws: SQLiteError.self) { try store.appendV2Update(delivery, to: stream, fence: fence) }
        #expect(try store.db.query("SELECT ordinal FROM acp_v2_update_records").isEmpty)
        try store.db.exec("DROP TRIGGER fail_receipt")
        let committed = try store.appendV2Update(delivery, to: stream, fence: fence)
        #expect(committed.wasInserted)
        #expect(committed.record.ordinal == 1)
        #expect(consumed.withLock { $0 } == 0)
        delivery.acknowledgeDurableConsumption()
        #expect(consumed.withLock { $0 } == 1)
        #expect(try store.loadSession(id: "journal")?.acpBrokerAcknowledgedCursor == 4)
    }

    @Test func replayPagesRespectBytesCountsAndStreamContinuations() throws {
        let connection = UUID()
        let (store, fence, stream) = try journalFixture(source: .stdio(connectionID: connection))
        for size in [3, 3, 8, 0] {
            _ = try store.appendV2Update(.init(frame: Data(repeating: UInt8(size), count: size), connectionID: connection), to: stream, fence: fence)
        }
        let first = try store.loadV2UpdateJournalPage(stream: stream, maxRecords: 3, maxBytes: 4)
        #expect(first.records.map(\.ordinal) == [1])
        #expect(!first.isAtEnd)
        #expect(!first.containsOversizedRecord)
        let second = try store.loadV2UpdateJournalPage(stream: stream, after: first.next, maxRecords: 1, maxBytes: 4)
        #expect(second.records.map(\.ordinal) == [2])
        let oversized = try store.loadV2UpdateJournalPage(stream: stream, after: second.next, maxRecords: 3, maxBytes: 1)
        #expect(oversized.records.map(\.ordinal) == [3])
        #expect(oversized.containsOversizedRecord)
        #expect(!oversized.isAtEnd)
        let last = try store.loadV2UpdateJournalPage(stream: stream, after: oversized.next, maxRecords: 3, maxBytes: 1)
        #expect(last.records.map(\.ordinal) == [4])
        #expect(last.records.first?.frame == Data())
        #expect(last.isAtEnd)
        #expect(last.next == nil)
        #expect(!last.hasKnownMissingPrefix)
        for invalid in [ACPV2UpdateJournalContinuation(streamID: UUID(), afterOrdinal: 1),
            .init(streamID: stream.id, afterOrdinal: -1), .init(streamID: stream.id, afterOrdinal: 99)] {
            #expect(throws: ACPV2UpdateJournalError.invalidInput) { try store.loadV2UpdateJournalPage(stream: stream, after: invalid) }
        }
        #expect(throws: ACPV2UpdateJournalError.invalidInput) { try store.loadV2UpdateJournalPage(stream: stream, maxRecords: 0) }
        #expect(throws: ACPV2UpdateJournalError.invalidInput) { try store.loadV2UpdateJournalPage(stream: stream, maxBytes: .max) }
    }

    @Test(arguments: ["future-format", "future-context", "corrupt-receipt"])
    func unreadableJournalMetadataFailsWithoutLosingEvidence(reason: String) throws {
        let (store, fence, stream) = try journalFixture()
        let receipt = try store.appendV2Update(brokerDelivery(Data([255, 0])), to: stream, fence: fence)
        switch reason {
        case "future-format": try store.db.exec("UPDATE acp_v2_update_streams SET format_version = 99")
        case "future-context": try store.db.exec("UPDATE acp_v2_update_streams SET wire_context = '{future}'")
        default: try store.db.exec("UPDATE acp_v2_update_records SET receipt_id = 'invalid'")
        }
        #expect(throws: (any Error).self) { try store.loadV2UpdateJournalPage(stream: stream) }
        let rows = try store.db.query("SELECT frame FROM acp_v2_update_records")
        #expect(rows.count == 1)
        #expect(rows.first?["frame"] as? Data == receipt.record.frame)
    }

    @Test func oldGenerationsSurviveBrokerClearUntilSessionDeletion() throws {
        let path = try { () -> String in
            let (store, fence, stream) = try journalFixture()
            _ = try store.appendV2Update(brokerDelivery(Data("old".utf8)), to: stream, fence: fence)
            #expect(try store.clearACPBrokerState(sessionId: "journal"))
            return store.path
        }()
        let store = try ACPSessionStore(path: path)
        let original = try #require(try store.loadV2UpdateJournalStream(sessionId: "journal"))
        let history = try store.loadV2UpdateJournalPage(stream: original)
        #expect(history.records.map(\.frame) == [Data("old".utf8)])
        #expect(history.hasKnownMissingPrefix)
        #expect(try store.updateACPBrokerState(sessionId: "journal", brokerId: "broker", generation: 8, acknowledgedCursor: 0, wireContext: .rawV2))
        let fence = ACPSessionLeaseFence(sessionId: "journal", ownerInstance: "A", token: "owner")
        let newer = try store.registerV2UpdateJournal(sessionId: "journal", upstreamSessionId: "upstream",
            source: .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 8)), fence: fence)
        #expect(newer.id != original.id)
        try store.seizeLease(sessionId: "journal", instanceId: "B", pid: 2, now: 2, leaseToken: "successor")
        let reopened = try ACPSessionStore(path: path)
        let latest = try #require(try reopened.loadV2UpdateJournalStream(sessionId: "journal"))
        let older = try #require(try reopened.loadV2UpdateJournalStream(sessionId: "journal", beforeStreamID: latest.id))
        #expect(latest == newer)
        #expect(older == original)
        #expect(try reopened.loadV2UpdateJournalStream(sessionId: "journal", beforeStreamID: older.id) == nil)
        #expect(throws: ACPV2UpdateJournalError.invalidInput) {
            try reopened.loadV2UpdateJournalStream(sessionId: "different", beforeStreamID: older.id)
        }
        #expect(try reopened.loadV2UpdateJournalPage(stream: latest).records.isEmpty)
        #expect(try reopened.loadV2UpdateJournalPage(stream: older).records.map(\.frame) == [Data("old".utf8)])
        try store.deleteSession(id: "journal")
        #expect(try store.db.query("SELECT id FROM acp_v2_update_streams").isEmpty)
        #expect(try store.db.query("SELECT ordinal FROM acp_v2_update_records").isEmpty)
        #expect(try reopened.loadV2UpdateJournalStream(sessionId: "journal") == nil)
        #expect(throws: ACPV2UpdateJournalError.incompatibleStream) { try store.loadV2UpdateJournalPage(stream: original) }
    }

    @Test(arguments: ["upstream", "zero-generation", "huge-generation", "broker-id"])
    func invalidJournalRegistrationNeverCreatesAStream(reason: String) throws {
        let (store, fence, _) = try journalFixture()
        try store.db.exec("DELETE FROM acp_v2_update_streams")
        let source: ACPV2UpdateJournalSource
        switch reason {
        case "zero-generation": source = .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 0))
        case "huge-generation": source = .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: .max))
        case "broker-id": source = .broker(id: .init(rawValue: "bad/id"), generation: .init(rawValue: 7))
        default: source = .stdio(connectionID: UUID())
        }
        #expect(throws: (any Error).self) {
            try store.registerV2UpdateJournal(sessionId: "journal", upstreamSessionId: reason == "upstream" ? "" : "upstream", source: source, fence: fence)
        }
        #expect(try store.db.query("SELECT id FROM acp_v2_update_streams").isEmpty)
    }

    @Test func storedUpdatesRebuildFactsWithoutLiveCompletionOrConsumption() throws {
        let connection = UUID()
        let (store, fence, stream) = try journalFixture(source: .stdio(connectionID: connection))
        let trace = [
            #"{"sessionUpdate":"state_update","state":"running"}"#,
            #"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"x"}}"#,
            #"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"x"}}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"t","rawInput":{"n":1e999}}"#,
            #"{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}"#,
            #"{"sessionUpdate":"future","n":1e999}"#,
        ]
        let liveContext = ACPV2MessageTranscript.Context(sessionID: "upstream", connectionID: connection)
        let replayContext = ACPV2MessageTranscript.Context(sessionID: "upstream", connectionID: UUID())
        var live = ACPV2SessionState(context: liveContext)
        var replay = ACPV2SessionState(context: replayContext)
        let consumed = Mutex(0)
        for update in trace {
            let frame = Data((#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":"# + update + "}}").utf8)
            let delivery = ACPV2SessionUpdateDelivery(frame: frame, connectionID: connection,
                durableConsumptionAcknowledgement: { consumed.withLock { $0 += 1 } })
            _ = try live.apply(delivery.decode(), source: .live, context: liveContext)
            _ = try store.appendV2Update(delivery, to: stream, fence: fence)
        }
        let malformed = ACPV2SessionUpdateDelivery(frame: Data("{broken".utf8), connectionID: connection)
        _ = try store.appendV2Update(malformed, to: stream, fence: fence)
        let reopened = try ACPSessionStore(path: store.path)
        let page = try reopened.loadV2UpdateJournalPage(stream: stream)
        for record in page.records.dropLast() {
            let decoded = try ACPV2SessionUpdateDelivery(frame: record.frame, connectionID: replayContext.connectionID).decode()
            _ = try replay.apply(decoded, source: .snapshot, context: replayContext)
        }
        #expect(replay.order == live.order)
        #expect(replay.transcript.messages.first?.content == live.transcript.messages.first?.content)
        #expect(replay.transcript.messages.first?.content.count == 2)
        #expect(replay.activity.toolCall(id: "t")?.rawInput == .object(["n": .number("1e999")]))
        #expect(live.lifecycle.lastForegroundCompletion != nil)
        #expect(replay.lifecycle.lastForegroundCompletion == nil)
        let malformedRecord = try #require(page.records.last)
        #expect(malformedRecord.frame == Data("{broken".utf8))
        #expect(throws: (any Error).self) { try ACPV2SessionUpdateDelivery(frame: malformedRecord.frame, connectionID: UUID()).decode() }
        #expect(consumed.withLock { $0 } == 0)
        #expect(try store.loadSession(id: "journal")?.acpBrokerAcknowledgedCursor == 4)
    }

    @Test("insert + load session round-trips fields")
    func sessions() throws {
        let store = try tmp()
        let row = ACPSessionRow(
            id: "s1", agentId: "claude", title: "hello",
            titleSource: .manual,
            currentModel: "sonnet", currentMode: "agent",
            autoRun: true,
            createdAt: 100, updatedAt: 100, lastOpenedAt: 100, archived: false)
        try store.upsertSession(row)
        let got = try #require(try store.loadSession(id: "s1"))
        #expect(got == row)
    }

    @Test("setAuthStatus round-trips through JSON and clears back to nil")
    func setAuthStatusRoundTrips() throws {
        let store = try tmp()
        let row = ACPSessionRow(
            id: "s1", agentId: "claude", title: "hello",
            titleSource: .manual,
            currentModel: nil, currentMode: nil,
            autoRun: false,
            createdAt: 100, updatedAt: 100, lastOpenedAt: 100, archived: false)
        try store.upsertSession(row)
        #expect(try store.loadSession(id: "s1")?.authStatus == nil)

        let status = ACPAuthStatus(
            kind: .account,
            label: "Claude Max",
            detail: "Renews monthly",
            account: .init(email: "person@example.com", organization: "Acme", plan: "Pro")
        )
        try store.setAuthStatus(sessionId: "s1", status: status)
        #expect(try store.loadSession(id: "s1")?.authStatus == status)

        try store.setAuthStatus(sessionId: "s1", status: nil)
        #expect(try store.loadSession(id: "s1")?.authStatus == nil)
    }

    @Test("session row persists remote ACP session id")
    func sessionRowPersistsRemoteSessionId() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Restored",
            titleSource: .manual,
            remoteSessionId: "remote-1",
            currentModel: "sonnet",
            currentMode: "agent",
            autoRun: true,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.remoteSessionId == "remote-1")
        #expect(row.currentModel == "sonnet")
        #expect(row.currentMode == "agent")
        #expect(row.autoRun == true)
    }

    @Test("session metadata updates preserve stored remote ACP session id")
    func sessionMetadataUpdatesPreserveRemoteSessionId() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Restored",
            titleSource: .manual,
            remoteSessionId: "remote-1",
            currentModel: "sonnet",
            currentMode: "agent",
            autoRun: true,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Updated",
            titleSource: .manual,
            currentModel: "opus",
            currentMode: "agent",
            autoRun: true,
            createdAt: 1,
            updatedAt: 4,
            lastOpenedAt: 5,
            archived: false
        ))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.remoteSessionId == "remote-1")
        #expect(row.title == "Updated")
        #expect(row.currentModel == "opus")
    }

    @Test("helper proc offsets persist monotonically within each proc generation")
    func helperProcOffsetsPersistMonotonicallyWithinGeneration() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Remote",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: true,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        #expect(try store.updateHelperProcOffsets(
            sessionId: "local-1",
            stdoutOffset: 20,
            stderrOffset: nil
        ))
        #expect(try store.updateHelperProcOffsets(
            sessionId: "local-1",
            stdoutOffset: 12,
            stderrOffset: 4
        ))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.helperProcStdoutOffset == 20)
        #expect(row.helperProcStderrOffset == 4)

        #expect(try store.resetHelperProcOffsets(sessionId: "local-1"))
        #expect(try store.updateHelperProcOffsets(
            sessionId: "local-1",
            stdoutOffset: 3,
            stderrOffset: 1
        ))

        let respawnedRow = try #require(try store.loadSession(id: "local-1"))
        #expect(respawnedRow.helperProcStdoutOffset == 3)
        #expect(respawnedRow.helperProcStderrOffset == 1)
    }

    @Test(arguments: [#"{"acpVersion":2,"payloadFormat":"alas.acp.raw-json.v1"}"#, " {future context} "])
    func brokerContextSurvivesConflictingMetadataSnapshots(context: String) throws {
        let store = try tmp()
        var row = ACPSessionRow(id: "context", agentId: "fixture", title: "Original", autoRun: false,
            acpBrokerId: "raw-broker", acpBrokerGeneration: 7, acpBrokerAcknowledgedCursor: 4,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false)
        row.acpBrokerWireContextJSON = context
        try store.upsertSession(row)
        var metadata = row
        metadata.title = "Renamed"
        metadata.acpBrokerId = "other"
        metadata.acpBrokerGeneration = 8
        metadata.acpBrokerAcknowledgedCursor = 99
        metadata.acpBrokerWireContextJSON = nil
        try store.upsertSession(metadata)
        let restored = try #require(try store.loadSession(id: row.id))
        #expect(restored.title == "Renamed")
        #expect(restored.acpBrokerId == "raw-broker")
        #expect(restored.acpBrokerGeneration == 7)
        #expect(restored.acpBrokerAcknowledgedCursor == 4)
        #expect(restored.acpBrokerWireContextJSON == context)
    }

    @Test func brokerContextFencesWritesAndClearsAsOneDescriptor() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "context", agentId: "fixture", title: "Saved", remoteSessionId: "upstream",
            autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        #expect(try store.updateACPBrokerState(sessionId: "context", brokerId: "raw", generation: 7,
            acknowledgedCursor: 4, wireContext: .rawV2))
        #expect(try store.updateACPBrokerState(sessionId: "context", brokerId: "raw", generation: 7,
            acknowledgedCursor: 99, wireContext: .legacyV1) == false)
        #expect(try store.updateACPBrokerAcknowledgedCursor(sessionId: "context", brokerId: "raw", generation: 7,
            cursor: 99, wireContext: .legacyV1) == false)
        #expect(try store.updateACPBrokerAcknowledgedCursor(sessionId: "context", brokerId: "raw", generation: 7,
            cursor: 8, wireContext: .rawV2))
        #expect(try store.updateACPBrokerAcknowledgedCursor(sessionId: "context", brokerId: "raw", generation: 7,
            cursor: 5, wireContext: .rawV2))
        var saved = try #require(try store.loadSession(id: "context"))
        #expect(saved.acpBrokerAcknowledgedCursor == 8)
        #expect(try ACPBrokerRestorePolicy.context(from: saved.acpBrokerWireContextJSON) == .rawV2)
        #expect(try store.updateACPBrokerState(sessionId: "context", brokerId: "raw", generation: 8,
            acknowledgedCursor: 1, wireContext: .legacyV1))
        saved = try #require(try store.loadSession(id: "context"))
        #expect(saved.acpBrokerAcknowledgedCursor == 1)
        #expect(try ACPBrokerRestorePolicy.context(from: saved.acpBrokerWireContextJSON) == .legacyV1)
        #expect(try store.clearACPBrokerState(sessionId: "context"))
        saved = try #require(try store.loadSession(id: "context"))
        #expect(saved.acpBrokerWireContextJSON == nil)
        #expect(saved.acpBrokerId == nil)
        #expect(saved.acpBrokerGeneration == nil)
        #expect(saved.acpBrokerAcknowledgedCursor == 0)
        #expect(saved.remoteSessionId == "upstream")
    }

    @Test("broker state round-trips and survives metadata-only upserts")
    func brokerStateSurvivesMetadataUpserts() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Recovered",
            titleSource: .manual,
            currentModel: "sonnet",
            currentMode: nil,
            autoRun: true,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        #expect(try store.updateACPBrokerState(
            sessionId: "local-1",
            brokerId: "broker-1",
            generation: 10,
            acknowledgedCursor: 4
        ))

        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Recovered",
            titleSource: .manual,
            currentModel: "opus",
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 4,
            lastOpenedAt: 5,
            archived: false
        ))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.acpBrokerId == "broker-1")
        #expect(row.acpBrokerGeneration == 10)
        #expect(row.acpBrokerAcknowledgedCursor == 4)
        #expect(row.currentModel == "opus")
        #expect(row.autoRun == false)

        let byBroker = try #require(try store.loadSession(acpBrokerId: "broker-1"))
        #expect(byBroker.id == "local-1")
    }

    @Test("broker cursor updates are monotonic and fenced by broker generation")
    func brokerCursorUpdatesAreMonotonicAndFenced() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Recovered",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: true,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))
        #expect(try store.updateACPBrokerState(
            sessionId: "local-1",
            brokerId: "broker-1",
            generation: 10,
            acknowledgedCursor: 4
        ))

        #expect(try store.updateACPBrokerAcknowledgedCursor(
            sessionId: "local-1",
            brokerId: "broker-1",
            generation: 10,
            cursor: 7
        ))
        #expect(try store.updateACPBrokerAcknowledgedCursor(
            sessionId: "local-1",
            brokerId: "broker-1",
            generation: 10,
            cursor: 5
        ))
        #expect(!(try store.updateACPBrokerAcknowledgedCursor(
            sessionId: "local-1",
            brokerId: "broker-1",
            generation: 11,
            cursor: 9
        )))
        #expect(!(try store.updateACPBrokerAcknowledgedCursor(
            sessionId: "local-1",
            brokerId: "broker-2",
            generation: 10,
            cursor: 9
        )))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.acpBrokerAcknowledgedCursor == 7)
    }

    @Test("session upsert resets broker cursor when generation changes")
    func sessionUpsertResetsBrokerCursorWhenGenerationChanges() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Recovered",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: true,
            acpBrokerId: "broker-1",
            acpBrokerGeneration: 10,
            acpBrokerAcknowledgedCursor: 12,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Recovered",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: true,
            acpBrokerId: "broker-1",
            acpBrokerGeneration: 11,
            acpBrokerAcknowledgedCursor: 2,
            createdAt: 1,
            updatedAt: 4,
            lastOpenedAt: 5,
            archived: false
        ))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.acpBrokerId == "broker-1")
        #expect(row.acpBrokerGeneration == 11)
        #expect(row.acpBrokerAcknowledgedCursor == 2)
    }

    @Test("broker state clears explicitly")
    func brokerStateClearsExplicitly() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Recovered",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: true,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))
        #expect(try store.updateACPBrokerState(
            sessionId: "local-1",
            brokerId: "broker-1",
            generation: 10,
            acknowledgedCursor: 4
        ))

        #expect(try store.clearACPBrokerState(sessionId: "local-1"))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.acpBrokerId == nil)
        #expect(row.acpBrokerGeneration == nil)
        #expect(row.acpBrokerAcknowledgedCursor == 0)
        #expect(try store.loadSession(acpBrokerId: "broker-1") == nil)
    }

    @Test("metadata-only upsert can preserve stored title")
    func sessionMetadataUpsertPreservesStoredTitleWhenRequested() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Remote Title",
            titleSource: .manual,
            currentModel: "sonnet",
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Stale Writer Title",
            titleSource: .placeholder,
            currentModel: "opus",
            currentMode: nil,
            autoRun: true,
            createdAt: 1,
            updatedAt: 4,
            lastOpenedAt: 5,
            archived: false
        ), preserveTitle: true)

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.title == "Remote Title")
        #expect(row.titleSource == .manual)
        #expect(row.currentModel == "opus")
        #expect(row.autoRun)
    }

    @Test("rename session reports archived rows as unchanged")
    func renameSessionReportsArchivedRowsAsUnchanged() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Archived",
            titleSource: .placeholder,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: true
        ))

        let renamed = try store.renameSession(
            id: "local-1",
            title: "Remote Title",
            titleSource: .manual,
            updatedAt: 4
        )

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(!renamed)
        #expect(row.title == "Archived")
        #expect(row.titleSource == .placeholder)
    }

    @Test("prompt fallback only changes placeholder rows")
    func fallbackTitleUpdateOnlyChangesPlaceholderRows() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "placeholder",
            agentId: "claude",
            title: "New session",
            titleSource: .placeholder,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))
        try store.upsertSession(.init(
            id: "manual",
            agentId: "claude",
            title: "Remote Title",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let placeholderChanged = try store.updateFallbackTitleIfPlaceholder(
            id: "placeholder",
            title: "Generated Title",
            updatedAt: 4
        )
        let manualChanged = try store.updateFallbackTitleIfPlaceholder(
            id: "manual",
            title: "Stale Generated Title",
            updatedAt: 4
        )

        let placeholder = try #require(try store.loadSession(id: "placeholder"))
        let manual = try #require(try store.loadSession(id: "manual"))
        #expect(placeholderChanged)
        #expect(placeholder.title == "Generated Title")
        #expect(placeholder.titleSource == .fallback)
        #expect(manualChanged == false)
        #expect(manual.title == "Remote Title")
        #expect(manual.titleSource == .manual)
    }

    @Test("late local result cannot replace stored provider, manual, or legacy titles")
    func localTitleOnlyReplacesFallback() throws {
        let store = try tmp()
        for (id, source) in [
            ("fallback", ACPSessionTitleSource.fallback),
            ("provider", .provider),
            ("manual", .manual),
            ("legacy", .generated)
        ] {
            try store.upsertSession(.init(
                id: id, agentId: "claude", title: "Before", titleSource: source,
                currentModel: nil, currentMode: nil, autoRun: false,
                createdAt: 1, updatedAt: 2, lastOpenedAt: 3, archived: false
            ))
        }

        for id in ["provider", "manual", "legacy"] {
            #expect(try !store.updateLocalTitleIfFallback(id: id, title: "Late model", updatedAt: 4))
            let row = try #require(try store.loadSession(id: id))
            #expect(row.title == "Before")
        }
        #expect(try store.updateLocalTitleIfFallback(id: "fallback", title: "Local title", updatedAt: 4))
        let row = try #require(try store.loadSession(id: "fallback"))
        #expect(row.title == "Local title")
        #expect(row.titleSource == .local)
    }

    @Test("session info title update changes placeholder and generated rows")
    func sessionInfoTitleUpdateChangesNonManualRows() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "placeholder",
            agentId: "claude",
            title: "New session",
            titleSource: .placeholder,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))
        try store.upsertSession(.init(
            id: "generated",
            agentId: "claude",
            title: "Old generated",
            titleSource: .generated,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let placeholderChanged = try store.updateGeneratedTitleIfNotManual(
            id: "placeholder",
            title: "Adapter Title",
            updatedAt: 10
        )
        let generatedChanged = try store.updateGeneratedTitleIfNotManual(
            id: "generated",
            title: "Better Adapter Title",
            updatedAt: 11
        )

        let placeholder = try #require(try store.loadSession(id: "placeholder"))
        let generated = try #require(try store.loadSession(id: "generated"))
        #expect(placeholderChanged)
        #expect(placeholder.title == "Adapter Title")
        #expect(placeholder.titleSource == .provider)
        #expect(placeholder.updatedAt == 10)
        #expect(generatedChanged)
        #expect(generated.title == "Better Adapter Title")
        #expect(generated.titleSource == .provider)
        #expect(generated.updatedAt == 11)
    }

    @Test("session info title update refuses manual and archived rows")
    func sessionInfoTitleUpdateRefusesManualAndArchivedRows() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "manual",
            agentId: "claude",
            title: "User Title",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))
        try store.upsertSession(.init(
            id: "archived",
            agentId: "claude",
            title: "Archived Title",
            titleSource: .generated,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: true
        ))

        let manualChanged = try store.updateGeneratedTitleIfNotManual(
            id: "manual",
            title: "Adapter Title",
            updatedAt: 10
        )
        let archivedChanged = try store.updateGeneratedTitleIfNotManual(
            id: "archived",
            title: "Adapter Title",
            updatedAt: 10
        )

        let manual = try #require(try store.loadSession(id: "manual"))
        let archived = try #require(try store.loadSession(id: "archived"))
        #expect(!manualChanged)
        #expect(manual.title == "User Title")
        #expect(manual.titleSource == .manual)
        #expect(manual.updatedAt == 2)
        #expect(!archivedChanged)
        #expect(archived.title == "Archived Title")
        #expect(archived.titleSource == .generated)
        #expect(archived.updatedAt == 2)
    }

    @Test("context recovery pending is stored separately from metadata upserts")
    func contextRecoveryPendingRoundTrip() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Restored",
            titleSource: .manual,
            remoteSessionId: "remote-1",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        try store.setContextRecoveryPending(sessionId: "local-1", pending: true)
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Updated",
            titleSource: .manual,
            currentModel: "opus",
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 4,
            lastOpenedAt: 5,
            archived: false
        ))

        var row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.contextRecoveryPending)
        #expect(row.title == "Updated")

        try store.setContextRecoveryPending(sessionId: "local-1", pending: false)
        row = try #require(try store.loadSession(id: "local-1"))
        #expect(!row.contextRecoveryPending)
    }

    @Test("recent list orders by last_opened_at desc and skips archived")
    func recent() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "a", agentId: "claude", title: "A",
            titleSource: .manual,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 10, archived: false))
        try store.upsertSession(.init(id: "b", agentId: "claude", title: "B",
            titleSource: .manual,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 2, updatedAt: 2, lastOpenedAt: 20, archived: false))
        try store.upsertSession(.init(id: "c", agentId: "claude", title: "C",
            titleSource: .manual,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 3, updatedAt: 3, lastOpenedAt: 30, archived: true))
        let recent = try store.recentSessions(limit: 10)
        #expect(recent.map(\.id) == ["b", "a"])
    }

    @Test("append + load messages preserves order via seq")
    func messages() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let m1 = Data(#"{"k":"user","v":"hi"}"#.utf8)
        let m2 = Data(#"{"k":"agent","v":"yo"}"#.utf8)
        try store.appendMessage(sessionId: "s", id: "m1", kind: "user", seq: 0, payload: m1, createdAt: 1)
        try store.appendMessage(sessionId: "s", id: "m2", kind: "agent", seq: 1, payload: m2, createdAt: 2)
        let loaded = try store.loadMessages(sessionId: "s")
        #expect(loaded.map(\.kind) == ["user", "agent"])
        #expect(loaded[0].payload == m1)
    }

    @Test("message row updates report whether a row existed")
    func updateMessageRowReportsChanges() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.appendMessage(
            sessionId: "s",
            id: "m1",
            kind: "agent",
            seq: 1,
            payload: Data("old".utf8),
            createdAt: 1
        )

        #expect(try store.updateMessageRow(
            id: "m1",
            kind: "user",
            seq: 0,
            payload: Data("new".utf8)
        ))
        #expect(try store.updateMessageRow(
            id: "missing",
            kind: "agent",
            seq: 2,
            payload: Data("ignored".utf8)
        ) == false)

        let loaded = try store.loadMessages(sessionId: "s")
        #expect(loaded.map(\.id) == ["m1"])
        #expect(loaded[0].kind == "user")
        #expect(loaded[0].seq == 0)
        #expect(loaded[0].payload == Data("new".utf8))
    }

    @Test("message count uses a narrow aggregate query")
    func messageCount() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertSession(.init(id: "other", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        try store.appendMessage(sessionId: "s", id: "m1", kind: "user", seq: 0, payload: Data("one".utf8), createdAt: 1)
        try store.appendMessage(sessionId: "s", id: "m2", kind: "agent", seq: 1, payload: Data("two".utf8), createdAt: 2)
        try store.appendMessage(sessionId: "other", id: "m3", kind: "agent", seq: 0, payload: Data("three".utf8), createdAt: 3)

        #expect(try store.messageCount(sessionId: "s") == 2)
        #expect(try store.messageCount(sessionId: "other") == 1)
        #expect(try store.messageCount(sessionId: "missing") == 0)
        #expect(try store.latestMessageSeq(sessionId: "s") == 1)
        #expect(try store.latestMessageSeq(sessionId: "other") == 0)
        #expect(try store.latestMessageSeq(sessionId: "missing") == nil)
    }

    @Test("composer draft upsert load and delete round-trips")
    func composerDraftCRUD() throws {
        let url = tmpURL()
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let draft = ACPComposerDraft(segments: [
            .text("Read "),
            .mention(displayName: "A.swift", uri: "file:///tmp/A.swift"),
            .text(" please")
        ])
        try store.upsertComposerDraft(sessionId: "s", draft: draft, updatedAt: 123)

        #expect(try store.loadComposerDraft(sessionId: "s") == draft)
        #expect(try ACPSessionStore(path: url.path).loadComposerDraft(sessionId: "s") == draft)

        let stored = try #require(try store.loadComposerDraftRecord(sessionId: "s"))
        #expect(stored.submittedRecovery == false)
        #expect(stored.submittedAfterSeq == nil)
        let newer = ACPComposerDraft(segments: [.text("newer")])
        try store.upsertComposerDraft(
            sessionId: "s",
            draft: newer,
            updatedAt: 124,
            submittedRecovery: true,
            submittedAfterSeq: 42
        )
        let newerStored = try #require(try store.loadComposerDraftRecord(sessionId: "s"))
        #expect(newerStored.submittedRecovery == true)
        #expect(newerStored.submittedAfterSeq == 42)
        #expect(try store.deleteComposerDraft(sessionId: "s", matching: stored) == false)
        #expect(try store.loadComposerDraft(sessionId: "s") == newer)

        try store.deleteComposerDraft(sessionId: "s")
        #expect(try store.loadComposerDraft(sessionId: "s") == nil)
    }

    @Test("composer draft is deleted with owning session")
    func composerDraftCascadesWithSession() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertComposerDraft(
            sessionId: "s",
            draft: ACPComposerDraft(segments: [.text("unsent")]),
            updatedAt: 123
        )

        try store.deleteSession(id: "s")

        #expect(try store.loadComposerDraft(sessionId: "s") == nil)
    }
}
