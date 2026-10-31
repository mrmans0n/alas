import Foundation
import Synchronization
import Testing
import AlasCore

@MainActor
struct ACPV2SessionUpdateOwnerTests {
    @Test func separateEqualChunksApplyInOrderWhileCopiedReceiptsApplyOnce() async throws {
        let fixture = try await Fixture()
        let owner = try fixture.owner()
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        let consumed = Mutex<[Int]>([])
        let first = fixture.delivery(Self.chunk, ack: { consumed.withLock { $0.append(1) } })
        let second = fixture.delivery(Self.chunk, ack: { consumed.withLock { $0.append(2) } })
        deliveries.continuation.yield(first)
        deliveries.continuation.yield(first)
        deliveries.continuation.yield(second)
        deliveries.continuation.finish()
        #expect(owner.start(deliveries.stream))
        #expect(!owner.start(deliveries.stream))
        await owner.waitUntilFinished()
        #expect(owner.lastAppliedOrdinal == 2)
        #expect(owner.state.transcript.messages.first?.content == [.object(["type": .string("text"), "text": .string("x")]), .object(["type": .string("text"), "text": .string("x")])])
        #expect(consumed.withLock { $0 } == [1, 2])
        let stream = try #require(owner.stream)
        let page = try await fixture.persistence.loadV2UpdateJournalPage(stream: stream)
        #expect(page.records.map(\.frame) == [first.frame, second.frame])
        #expect(owner.status == .observationLost)
    }

    @Test func brokerRedeliveryAfterRestorationConsumesCurrentHandleWithoutApplyingAgain() async throws {
        let fixture = try await Fixture(broker: true)
        let stream = try await fixture.register()
        let original = fixture.delivery(Self.chunk, cursor: 5)
        _ = try await fixture.persistence.appendV2Update(original, to: stream, fence: fixture.fence)
        let owner = try fixture.owner(tail: 5)
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        let consumed = Mutex(0)
        let retry = fixture.delivery(Self.chunk, cursor: 5, origin: .pendingSnapshot, ack: { consumed.withLock { $0 += 1 } })
        deliveries.continuation.yield(retry)
        deliveries.continuation.finish()
        #expect(owner.start(deliveries.stream))
        await owner.waitUntilFinished()
        #expect(owner.lastAppliedOrdinal == 1)
        #expect(owner.state.transcript.messages.first?.content.count == 1)
        #expect(consumed.withLock { $0 } == 1)
        #expect(try await fixture.persistence.loadV2UpdateJournalPage(stream: stream).records.first?.receiptID == original.receiptID)
        #expect(owner.hasKnownMissingPrefix)
    }

    @Test(arguments: [false, true])
    func brokerBacklogCannotPublishHistoricalCompletion(hasFreshTransition: Bool) async throws {
        let fixture = try await Fixture(broker: true)
        let owner = try fixture.owner(tail: 6)
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.yield(fixture.delivery(Self.running, cursor: 5))
        deliveries.continuation.yield(fixture.delivery(Self.idle, cursor: 6))
        if hasFreshTransition {
            deliveries.continuation.yield(fixture.delivery(Self.running, cursor: 7))
            deliveries.continuation.yield(fixture.delivery(Self.idle, cursor: 8))
        }
        deliveries.continuation.finish()
        _ = owner.start(deliveries.stream)
        await owner.waitUntilFinished()
        #expect((owner.state.lifecycle.lastForegroundCompletion != nil) == hasFreshTransition)
        #expect(owner.state.latestStateObservation?.source == (hasFreshTransition ? .live : .snapshot))
    }

    @Test func multipleReplayPagesRebuildSnapshotStateBeforeLiveDuplicate() async throws {
        let fixture = try await Fixture(broker: true)
        let stream = try await fixture.register()
        for cursor in 5...134 {
            _ = try await fixture.persistence.appendV2Update(fixture.delivery(Self.chunk, cursor: UInt64(cursor)), to: stream, fence: fixture.fence)
        }
        _ = try await fixture.persistence.appendV2Update(fixture.delivery(Self.running, cursor: 135), to: stream, fence: fixture.fence)
        _ = try await fixture.persistence.appendV2Update(fixture.delivery(Self.idle, cursor: 136), to: stream, fence: fixture.fence)
        let owner = try fixture.owner(tail: 136)
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.finish()
        _ = owner.start(deliveries.stream)
        await owner.waitUntilFinished()
        #expect(owner.lastAppliedOrdinal == 132)
        #expect(owner.state.transcript.messages.first?.content.count == 130)
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
        #expect(owner.state.latestStateObservation?.source == .snapshot)
    }

    @Test func pendingAppendCannotBeOvertakenOrConsumedBeforeCommit() async throws {
        let fixture = try await Fixture()
        let gate = JournalGate(fixture.persistence, operation: .append, after: false)
        let owner = try fixture.owner(journal: gate)
        let consumed = Mutex<[Int]>([])
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.yield(fixture.delivery(Self.chunk, ack: { consumed.withLock { $0.append(1) } }))
        deliveries.continuation.yield(fixture.delivery(Self.chunk, ack: { consumed.withLock { $0.append(2) } }))
        deliveries.continuation.finish()
        _ = owner.start(deliveries.stream)
        try await eventually { await gate.entered }
        #expect(owner.state.transcript.messages.isEmpty)
        #expect(consumed.withLock { $0 }.isEmpty)
        let registered = try #require(owner.stream)
        #expect(try await fixture.persistence.loadV2UpdateJournalPage(stream: registered).records.isEmpty)
        await gate.release()
        await owner.waitUntilFinished()
        #expect(consumed.withLock { $0 } == [1, 2])
        #expect(owner.state.transcript.messages.first?.content.count == 2)
    }

    @Test(arguments: [ACPV2SessionUpdateOwner.Operation.registration, .replay, .append], [false, true])
    func stopFencesStorageEntryAndReturningCommittedReceipts(operation: ACPV2SessionUpdateOwner.Operation, after: Bool) async throws {
        let fixture = try await Fixture()
        let gate = JournalGate(fixture.persistence, operation: operation, after: after)
        let owner = try fixture.owner(journal: gate)
        let consumed = Mutex(0)
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.yield(fixture.delivery(Self.chunk, ack: { consumed.withLock { $0 += 1 } }))
        _ = owner.start(deliveries.stream)
        try await eventually { await gate.entered }
        owner.stop()
        await gate.release()
        await owner.waitUntilFinished()
        deliveries.continuation.finish()
        #expect(owner.status == .stopped)
        #expect(owner.lastAppliedOrdinal == 0)
        #expect(owner.state.transcript.messages.isEmpty)
        #expect(consumed.withLock { $0 } == 0)
        if operation == .append {
            let stream = try #require(owner.stream)
            #expect(try await fixture.persistence.loadV2UpdateJournalPage(stream: stream).records.count == 1)
        }
    }

    @Test func ownershipLostAfterCommitRetainsReceiptWithoutModelOrConsumption() async throws {
        let fixture = try await Fixture(broker: true)
        let gate = JournalGate(fixture.persistence, operation: .append, after: true)
        let current = Mutex(true)
        let owner = try fixture.owner(journal: gate, isCurrent: { current.withLock { $0 } })
        let consumed = Mutex(0)
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.yield(fixture.delivery(Self.chunk, ack: { consumed.withLock { $0 += 1 } }))
        _ = owner.start(deliveries.stream)
        try await eventually { await gate.entered }
        current.withLock { $0 = false }
        await gate.release()
        await owner.waitUntilFinished()
        deliveries.continuation.finish()
        #expect(owner.status == .blocked(.ownershipLost))
        #expect(owner.lastAppliedOrdinal == 0)
        #expect(owner.state.transcript.messages.isEmpty)
        #expect(consumed.withLock { $0 } == 0)
        let stream = try #require(owner.stream)
        #expect(try await fixture.persistence.loadV2UpdateJournalPage(stream: stream).records.count == 1)
        let restored = try fixture.owner(tail: 5)
        let retry = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        retry.continuation.yield(fixture.delivery(Self.chunk, ack: { consumed.withLock { $0 += 1 } }))
        retry.continuation.finish()
        _ = restored.start(retry.stream)
        await restored.waitUntilFinished()
        #expect(restored.state.transcript.messages.first?.content.count == 1)
        #expect(consumed.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func rejectedWriteBlocksWithoutApplyingOrConsuming(staleLease: Bool) async throws {
        let fixture = try await Fixture()
        let gate = JournalGate(fixture.persistence, operation: .append, after: false)
        let owner = try fixture.owner(journal: gate)
        let consumed = Mutex(0)
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.yield(fixture.delivery(Self.chunk, ack: { consumed.withLock { $0 += 1 } }))
        _ = owner.start(deliveries.stream)
        try await eventually { await gate.entered }
        if staleLease {
            _ = try await fixture.persistence.seizeLease(sessionId: "local", instanceId: "B", pid: 2, now: 2, leaseToken: "replacement")
        } else {
            let store = try ACPSessionStore(path: fixture.persistence.path)
            try store.db.exec("CREATE TRIGGER owner_write_failure BEFORE INSERT ON acp_v2_update_records BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        await gate.release()
        await owner.waitUntilFinished()
        deliveries.continuation.finish()
        if staleLease { #expect(owner.status == .blocked(.journal(.append, .staleLease))) }
        else {
            guard case .blocked(.persistence(.append, _)) = owner.status else {
                Issue.record("Expected append persistence failure, got \(owner.status)")
                return
            }
        }
        #expect(owner.state.transcript.messages.isEmpty)
        #expect(owner.lastAppliedOrdinal == 0)
        #expect(consumed.withLock { $0 } == 0)
        let stream = try #require(owner.stream)
        #expect(try await fixture.persistence.loadV2UpdateJournalPage(stream: stream).records.isEmpty)
    }

    @Test(arguments: ["known-shape", "envelope", "session"], [false, true])
    func uninterpretableRecordBlocksItsPrefixAndRetainsBytes(reason: String, historical: Bool) async throws {
        let fixture = try await Fixture()
        let invalid: Data
        switch reason {
        case "known-shape": invalid = fixture.delivery(#"{"sessionUpdate":"state_update","state":4}"#).frame
        case "envelope": invalid = Data(#"{"jsonrpc":"2.0","method":"session/update","params":null}"#.utf8)
        default: invalid = Data(String(decoding: fixture.delivery(Self.chunk).frame, as: UTF8.self).replacingOccurrences(of: "upstream", with: "elsewhere").utf8)
        }
        let consumed = Mutex(0)
        let delivery = ACPV2SessionUpdateDelivery(frame: invalid, connectionID: fixture.connectionID,
            durableConsumptionAcknowledgement: { consumed.withLock { $0 += 1 } })
        let prefix = fixture.delivery(Self.chunk)
        if historical {
            let stream = try await fixture.register()
            _ = try await fixture.persistence.appendV2Update(prefix, to: stream, fence: fixture.fence)
            _ = try await fixture.persistence.appendV2Update(delivery, to: stream, fence: fixture.fence)
        }
        let owner = try fixture.owner()
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        if !historical {
            deliveries.continuation.yield(prefix)
            deliveries.continuation.yield(delivery)
        }
        deliveries.continuation.yield(fixture.delivery(Self.running))
        deliveries.continuation.yield(fixture.delivery(Self.idle))
        deliveries.continuation.finish()
        _ = owner.start(deliveries.stream)
        await owner.waitUntilFinished()
        switch owner.status {
        case .blocked(.interpretation(let ordinal, _)):
            #expect(reason != "session")
            #expect(ordinal == 2)
        case .blocked(.sessionMismatch(let ordinal, let expected, let received)):
            #expect(reason == "session")
            #expect(ordinal == 2)
            #expect(expected == "upstream")
            #expect(received == "elsewhere")
        default: Issue.record("Expected interpretation failure, got \(owner.status)")
        }
        #expect(owner.lastAppliedOrdinal == 1)
        #expect(owner.state.transcript.messages.first?.content.count == 1)
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
        #expect(consumed.withLock { $0 } == 0)
        let stream = try #require(owner.stream)
        #expect(try await fixture.persistence.loadV2UpdateJournalPage(stream: stream).records.map(\.frame) == [prefix.frame, invalid])
    }

    @Test func validUnknownUpdateIsRetainedAndExplicitlyConsumed() async throws {
        let fixture = try await Fixture()
        let owner = try fixture.owner()
        let consumed = Mutex(0)
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        let delivery = fixture.delivery(#"{"sessionUpdate":"future","n":1e999}"#, ack: { consumed.withLock { $0 += 1 } })
        deliveries.continuation.yield(delivery)
        deliveries.continuation.finish()
        _ = owner.start(deliveries.stream)
        await owner.waitUntilFinished()
        #expect(owner.latestApplication?.disposition == .unhandled)
        #expect(owner.lastAppliedOrdinal == 1)
        #expect(consumed.withLock { $0 } == 1)
        let stream = try #require(owner.stream)
        #expect(try await fixture.persistence.loadV2UpdateJournalPage(stream: stream).records.first?.frame == delivery.frame)
    }

    @Test(arguments: ["connection", "broker", "generation", "stdio-provenance"])
    func incompatibleDeliveryCannotEnterTheJournal(reason: String) async throws {
        let fixture = try await Fixture(broker: reason != "stdio-provenance")
        let owner = try fixture.owner()
        let consumed = Mutex(0)
        let delivery = ACPV2SessionUpdateDelivery(frame: fixture.delivery(Self.chunk).frame,
            connectionID: reason == "connection" ? UUID() : fixture.connectionID,
            brokerProvenance: .init(brokerID: .init(rawValue: reason == "broker" ? "other" : "broker"),
                generation: .init(rawValue: reason == "generation" ? 8 : 7), cursor: .init(rawValue: 5), origin: .journal),
            durableConsumptionAcknowledgement: { consumed.withLock { $0 += 1 } })
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.yield(delivery)
        deliveries.continuation.finish()
        _ = owner.start(deliveries.stream)
        await owner.waitUntilFinished()
        #expect(owner.status == .blocked(.deliveryMismatch))
        #expect(owner.lastAppliedOrdinal == 0)
        #expect(consumed.withLock { $0 } == 0)
        let stream = try #require(owner.stream)
        #expect(try await fixture.persistence.loadV2UpdateJournalPage(stream: stream).records.isEmpty)
    }

    @Test func corruptReplayGapCannotClaimACompleteCanonicalPrefix() async throws {
        let fixture = try await Fixture()
        let stream = try await fixture.register()
        _ = try await fixture.persistence.appendV2Update(fixture.delivery(Self.running), to: stream, fence: fixture.fence)
        _ = try await fixture.persistence.appendV2Update(fixture.delivery(Self.idle), to: stream, fence: fixture.fence)
        let store = try ACPSessionStore(path: fixture.persistence.path)
        try store.db.exec("DELETE FROM acp_v2_update_records WHERE ordinal = 1")
        let owner = try fixture.owner()
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.finish()
        _ = owner.start(deliveries.stream)
        await owner.waitUntilFinished()
        #expect(owner.status == .blocked(.ordinalGap(expected: 1, received: 2)))
        #expect(owner.lastAppliedOrdinal == 0)
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
    }

    @Test(arguments: [false, true])
    func intentionalStopAndUnexpectedEndKeepDistinctObservationState(intentional: Bool) async throws {
        let fixture = try await Fixture()
        let owner = try fixture.owner()
        let deliveries = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        deliveries.continuation.yield(fixture.delivery(Self.running))
        _ = owner.start(deliveries.stream)
        try await eventually { await MainActor.run { owner.lastAppliedOrdinal == 1 } }
        if intentional { owner.stop() } else { deliveries.continuation.finish() }
        await owner.waitUntilFinished()
        deliveries.continuation.finish()
        #expect(owner.status == (intentional ? .stopped : .observationLost))
        #expect(owner.state.lifecycle.foreground == (intentional ? .running : .unknown))
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
        #expect(!owner.start(deliveries.stream))
    }

    @Test(arguments: ["legacy", "zero-generation", "tail-range", "ack-after-tail"])
    func incompatibleBrokerObservationCannotAuthorizeAnAttachment(reason: String) async throws {
        let fixture = try await Fixture(broker: true)
        let opened = fixture.opened(tail: reason == "tail-range" ? .max : (reason == "ack-after-tail" ? 3 : 4),
            context: reason == "legacy" ? .legacyV1 : .rawV2, generation: reason == "zero-generation" ? 0 : 7)
        #expect(throws: ACPV2SessionUpdateOwner.Failure.invalidAttachment) {
            try ACPV2SessionUpdateOwner.Attachment(brokerConnectionID: fixture.connectionID, opened: opened)
        }
    }

    @Test func submissionCommitsBeforeHandoffAndAppliesToLatestInterleavedState() async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID)
        let gate = SubmissionJournalGate(fixture.persistence, operation: .retain, after: true)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: gate))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        let id = UUID(), row = UUID()
        let submitting = Task { try await owner.submit(id: id, localRowID: row, params: .init(sessionId: "upstream", prompt: [.text("same")])) }
        defer { submitting.cancel() }
        try await eventually { await sender.sent.count == 1 }
        let registered = try #require(try await fixture.persistence.loadV2Submission(id: id))
        #expect(registered.recovery == .uncertain)
        updates.continuation.yield(fixture.delivery(Self.userEcho))
        await sender.respond(1, result: #"{"messageId":"user"}"#)
        try await eventually { await gate.entered }
        updates.continuation.yield(fixture.delivery(Self.chunk))
        try await eventually { await MainActor.run { owner.lastAppliedOrdinal == 2 } }
        #expect(sender.consumed.withLock { $0 }.isEmpty)
        await gate.release()
        let record = try await submitting.value
        #expect(record.registration.localRowID == row)
        #expect(owner.state.transcript.messages.first(where: { $0.key.messageID == "user" })?.localRowID == row)
        #expect(owner.state.transcript.messages.first(where: { $0.key.messageID == "m" })?.content.count == 1)
        #expect(sender.consumed.withLock { $0 } == [1])
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
        #expect(owner.lastAppliedOrdinal == 2)
    }

    @Test func concurrentSubmissionsWithReversedResponsesKeepTheirRows() async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: fixture.persistence))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        let rowA = UUID(), rowB = UUID()
        let first = Task { try await owner.submit(id: UUID(), localRowID: rowA, params: .init(sessionId: "upstream", prompt: [.text("same")])) }
        defer { first.cancel() }
        try await eventually { await sender.sent.count == 1 }
        let second = Task { try await owner.submit(id: UUID(), localRowID: rowB, params: .init(sessionId: "upstream", prompt: [.text("same")])) }
        defer { second.cancel() }
        try await eventually { await sender.sent.count == 2 }
        updates.continuation.yield(fixture.delivery(#"{"sessionUpdate":"user_message","messageId":"b","content":[{"type":"text","text":"same"}]}"#))
        await sender.respond(2, result: #"{"messageId":"b"}"#)
        _ = try await second.value
        await sender.respond(1, result: #"{"messageId":"a"}"#)
        _ = try await first.value
        updates.continuation.yield(fixture.delivery(#"{"sessionUpdate":"user_message","messageId":"a","content":[{"type":"text","text":"same"}]}"#))
        try await eventually { await MainActor.run { owner.lastAppliedOrdinal == 2 } }
        #expect(owner.state.transcript.messages.first(where: { $0.key.messageID == "a" })?.localRowID == rowA)
        #expect(owner.state.transcript.messages.first(where: { $0.key.messageID == "b" })?.localRowID == rowB)
        #expect(sender.consumed.withLock { $0 } == [2, 1])
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
    }

    @Test func submissionRestorationPagesPrecedeSnapshotReplayWithoutDispatch() async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID)
        var firstRow = UUID()
        for index in 1...130 {
            let row = UUID()
            if index == 1 { firstRow = row }
            let registration = try await fixture.persistence.registerV2Submission(id: UUID(), sessionId: "local", upstreamSessionId: "upstream", localRowID: row,
                binding: .stdio(connectionID: fixture.connectionID, requestID: .number(index)), fence: fixture.fence)
            if index < 130 {
                let frame = Data("{\"jsonrpc\":\"2.0\",\"id\":\(index),\"result\":{\"messageId\":\"u\(index)\"}}".utf8)
                _ = try await fixture.persistence.retainV2SubmissionOutcome(.init(frame: frame, connectionID: fixture.connectionID,
                    source: .stdio(requestID: .number(index), method: "session/prompt")), for: registration, fence: fixture.fence)
            }
        }
        let old = try await fixture.persistence.registerV2Submission(id: UUID(), sessionId: "local", upstreamSessionId: "upstream", localRowID: UUID(),
            binding: .stdio(connectionID: UUID(), requestID: .number(1)), fence: fixture.fence)
        let stream = try await fixture.register()
        _ = try await fixture.persistence.appendV2Update(fixture.delivery(#"{"sessionUpdate":"user_message","messageId":"u1","content":[]}"#), to: stream, fence: fixture.fence)
        _ = try await fixture.persistence.appendV2Update(fixture.delivery(Self.running), to: stream, fence: fixture.fence)
        _ = try await fixture.persistence.appendV2Update(fixture.delivery(Self.idle), to: stream, fence: fixture.fence)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: fixture.persistence))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        #expect(owner.state.transcript.messages.first?.localRowID == firstRow)
        #expect(owner.state.lifecycle.submission(1) == .accepted(messageID: "u1"))
        #expect(owner.state.lifecycle.submission(130) == .uncertain)
        #expect(owner.state.lifecycle.submission(old.sequence) == nil)
        #expect(owner.lastAppliedOrdinal == 3)
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
        #expect(await sender.sent.isEmpty)
        #expect(sender.consumed.withLock { $0 }.isEmpty)
    }

    @Test(arguments: ["registration", "retain"].flatMap { operation in [false, true].flatMap { after in ["stop", "ownership", "cancel"].map { (operation, after, $0) } } })
    func submissionCommitReturnsCannotPublishThroughInvalidatedOwnership(phase: String, after: Bool, loss: String) async throws {
        let operation: SubmissionJournalGate.Operation = phase == "registration" ? .registration : .retain
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID)
        let gate = SubmissionJournalGate(fixture.persistence, operation: operation, after: after)
        let current = Mutex(true)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: gate), isCurrent: { current.withLock { $0 } })
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        let id = UUID()
        let submitting = Task { try await owner.submit(id: id, localRowID: UUID(), params: .init(sessionId: "upstream", prompt: [])) }
        defer { submitting.cancel() }
        if operation == .retain {
            try await eventually { await sender.sent.count == 1 }
            await sender.respond(1, result: #"{"messageId":"user"}"#)
        }
        try await eventually { await gate.entered }
        if loss == "stop" { owner.stop() }
        else if loss == "ownership" { current.withLock { $0 = false } }
        else { submitting.cancel() }
        await gate.release()
        if case .success = await submitting.result { Issue.record("Invalidated submission applied") }
        let record = try #require(try await fixture.persistence.loadV2Submission(id: id))
        #expect((record.outcome != nil) == (operation == .retain))
        #expect(sender.consumed.withLock { $0 }.isEmpty)
        #expect(await sender.sent.count == (operation == .retain ? 1 : 0))
        if case .accepted? = owner.state.lifecycle.submission(record.registration.sequence) { Issue.record("Stale acceptance published") }
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
    }

    @Test(arguments: ["error", "malformed", "transport", "sql", "conflict", "source"])
    func failedSubmissionPreservesEvidenceWithoutRejectingOrCompleting(kind: String) async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: fixture.persistence))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        if kind == "sql" {
            let db = try SQLiteDatabase(path: fixture.persistence.path)
            try db.exec("CREATE TRIGGER fail_outcome AFTER INSERT ON acp_v2_submission_outcomes BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        if kind == "conflict" {
            updates.continuation.yield(fixture.delivery(Self.userEcho))
            try await eventually { await MainActor.run { owner.lastAppliedOrdinal == 1 } }
            // Bind that upstream message to a different optimistic row first.
            let first = Task { try await owner.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "upstream", prompt: [])) }
            try await eventually { await sender.sent.count == 1 }
            await sender.respond(1, result: #"{"messageId":"user"}"#)
            _ = try await first.value
        }
        let id = UUID()
        let index = kind == "conflict" ? 2 : 1
        let submitting = Task { try await owner.submit(id: id, localRowID: UUID(), params: .init(sessionId: "upstream", prompt: [])) }
        defer { submitting.cancel() }
        try await eventually { await sender.sent.count == index }
        await sender.respond(index, result: kind == "error" ? #"{"code":-32044,"message":"failed","data":{"n":1e999}}"# : #"{"messageId":"user"}"#,
            error: kind == "error", malformed: kind == "malformed", missingRaw: kind == "transport", wrongConnection: kind == "source")
        let result = await submitting.result
        let loaded = try #require(try await fixture.persistence.loadV2Submission(id: id))
        if kind == "error" {
            #expect(loaded.recovery == .rpcFailure)
            #expect(owner.status == .live)
            #expect(sender.consumed.withLock { $0 } == [1])
            if case .failure = result { Issue.record("Factual RPC error should return its durable record") }
        } else {
            if case .success = result { Issue.record("Invalid outcome applied") }
            if kind == "transport" { #expect(owner.status == .live) }
            else { if case .blocked = owner.status {} else { Issue.record("Unsafe owner remained active") } }
            #expect(sender.consumed.withLock { $0 } == (kind == "conflict" ? [1] : []))
        }
        #expect(owner.state.lifecycle.submission(loaded.registration.sequence) != .rejected)
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
        if ["sql", "transport", "source"].contains(kind) { #expect(loaded.recovery == .uncertain) }
        if kind == "malformed" { #expect(loaded.recovery == .uninterpretable) }
    }

    @Test func restoredMalformedOutcomeBlocksBeforeUpdateReplayOrDispatch() async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID)
        let registration = try await fixture.persistence.registerV2Submission(id: UUID(), sessionId: "local", upstreamSessionId: "upstream", localRowID: UUID(),
            binding: .stdio(connectionID: fixture.connectionID, requestID: .number(9)), fence: fixture.fence)
        _ = try await fixture.persistence.retainV2SubmissionOutcome(.init(frame: Data([255]), connectionID: fixture.connectionID,
            source: .stdio(requestID: .number(9), method: "session/prompt")), for: registration, fence: fixture.fence)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: fixture.persistence))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        updates.continuation.yield(fixture.delivery(Self.chunk))
        _ = owner.start(updates.stream)
        await owner.waitUntilFinished()
        updates.continuation.finish()
        #expect(owner.status == .blocked(.submission(.uninterpretable)))
        #expect(owner.state.lifecycle.submission(registration.sequence) == .uncertain)
        #expect(owner.lastAppliedOrdinal == 0)
        #expect(await sender.sent.isEmpty)
    }

    @Test func invalidOrReusedSubmissionCannotDispatchAnotherAttempt() async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: fixture.persistence))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        await #expect(throws: ACPV2SessionUpdateOwner.Failure.submission(.invalidRequest)) {
            try await owner.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "wrong", prompt: []))
        }
        let id = UUID()
        _ = try await fixture.persistence.registerV2Submission(id: id, sessionId: "local", upstreamSessionId: "upstream", localRowID: UUID(),
            binding: .stdio(connectionID: fixture.connectionID, requestID: .number(99)), fence: fixture.fence)
        await #expect(throws: ACPV2SessionUpdateOwner.Failure.submission(.duplicate)) {
            try await owner.submit(id: id, localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
        }
        #expect(await sender.sent.isEmpty)
        let activeID = UUID()
        let active = Task { try await owner.submit(id: activeID, localRowID: UUID(), params: .init(sessionId: "upstream", prompt: [])) }
        defer { active.cancel() }
        try await eventually { await sender.sent.count == 1 }
        await #expect(throws: ACPV2SessionUpdateOwner.Failure.submission(.duplicate)) {
            try await owner.submit(id: activeID, localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
        }
        await sender.respond(1, result: #"{"messageId":"only"}"#)
        _ = try await active.value
        #expect(await sender.sent == [1])
    }

    @Test func staleWriterCannotRegisterOrDispatchASubmission() async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: fixture.persistence))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        _ = try await fixture.persistence.seizeLease(sessionId: "local", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        let id = UUID()
        do { _ = try await owner.submit(id: id, localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
        Issue.record("Stale writer dispatched") }
        catch {}
        #expect(try await fixture.persistence.loadV2Submission(id: id) == nil)
        #expect(await sender.sent.isEmpty)
        if case .blocked = owner.status {} else { Issue.record("Lost writer remained active") }
    }

    @Test func preparationFromAnotherConnectionCannotRegisterOrDispatch() async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID, preparedConnection: UUID())
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: fixture.persistence))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        let id = UUID()
        await #expect(throws: ACPV2SessionUpdateOwner.Failure.submission(.invalidRequest)) {
            try await owner.submit(id: id, localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
        }
        #expect(try await fixture.persistence.loadV2Submission(id: id) == nil)
        #expect(await sender.sent.isEmpty)
    }

    @Test func blockingPreparationFailureStopsOtherWorkBeforeTransportPropagatesIt() async throws {
        let fixture = try await Fixture()
        let sender = PromptSenderFixture(connection: fixture.connectionID, holdPreparationFailure: true, autoReply: true)
        let owner = try fixture.owner(submissions: .init(sender: sender, journal: fixture.persistence))
        let updates = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        _ = owner.start(updates.stream)
        defer { owner.stop()
        updates.continuation.finish() }
        try await eventually { await MainActor.run { owner.status == .live } }
        let db = try SQLiteDatabase(path: fixture.persistence.path)
        try db.exec("CREATE TRIGGER fail_registration AFTER INSERT ON acp_v2_submissions BEGIN SELECT RAISE(ABORT, 'injected'); END")
        let first = Task { try await owner.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "upstream", prompt: [])) }
        defer { first.cancel() }
        try await eventually { await sender.preparationFailureObserved }
        if case .blocked = owner.status {} else { Issue.record("Known blocking failure left owner live while transport awaited propagation") }
        try db.exec("DROP TRIGGER fail_registration")
        do {
            _ = try await owner.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
            Issue.record("Another prompt dispatched after the canonical owner discovered a blocking failure")
        } catch {}
        #expect(await sender.sent.isEmpty)
        #expect(sender.consumed.withLock { $0 }.isEmpty)
        await sender.releasePreparationFailure()
        _ = await first.result
    }

    private static let userEcho = #"{"sessionUpdate":"user_message","messageId":"user","content":[{"type":"text","text":"same"}]}"#

    private static let chunk = #"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"x"}}"#
    private static let running = #"{"sessionUpdate":"state_update","state":"running"}"#
    private static let idle = #"{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}"#

    private struct Fixture {
        let persistence: ACPSessionPersistence
        let fence = ACPSessionLeaseFence(sessionId: "local", ownerInstance: "A", token: "owner")
        let connectionID = UUID()
        let broker: Bool

        init(broker: Bool = false) async throws {
            self.broker = broker
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("alas-v2-owner-\(UUID()).sqlite").path
            persistence = ACPSessionPersistence(path: path)
            var row = ACPSessionRow(id: "local", agentId: "fixture", title: "Owner", autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false)
            if broker {
                row.acpBrokerId = "broker"
                row.acpBrokerGeneration = 7
                row.acpBrokerWireContextJSON = try ACPBrokerWireContext.rawV2.persistedJSON()
                row.acpBrokerAcknowledgedCursor = 4
            }
            try await persistence.upsertSession(row)
            _ = try await persistence.seizeLease(sessionId: "local", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        }

        var source: ACPV2UpdateJournalSource {
            broker ? .broker(id: .init(rawValue: "broker"), generation: .init(rawValue: 7)) : .stdio(connectionID: connectionID)
        }

        func register() async throws -> ACPV2UpdateJournalStream {
            try await persistence.registerV2UpdateJournal(sessionId: "local", upstreamSessionId: "upstream", source: source, fence: fence)
        }

        func opened(tail: UInt64, context: ACPBrokerWireContext = .rawV2, generation: UInt64 = 7) -> ACPBrokerOpenResult {
            var metadata = ACPBrokerMetadata(brokerId: .init(rawValue: "broker"), generation: .init(rawValue: generation), alasSessionId: "local", adapterProgram: "fixture", adapterArgs: [], cwd: "/tmp", envKeys: [], createdAtMillis: 0)
            metadata.wireContext = context
            return .init(snapshot: .init(metadata: metadata, initializeResult: nil, remoteSessionResult: nil,
                turnState: .unknown("unknown"), acknowledgedCursor: .init(rawValue: 4), journalTail: .init(rawValue: tail), pendingRequests: [], operations: []), adopted: true)
        }

        @MainActor
        func owner(tail: UInt64 = 4, journal: (any ACPV2UpdateJournalPersisting)? = nil,
            submissions: ACPV2SessionUpdateOwner.SubmissionCapability? = nil,
            isCurrent: @escaping @MainActor () -> Bool = { true }) throws -> ACPV2SessionUpdateOwner {
            let attachment = try broker ? ACPV2SessionUpdateOwner.Attachment(brokerConnectionID: connectionID, opened: opened(tail: tail)) : ACPV2SessionUpdateOwner.Attachment(freshStdioConnectionID: connectionID)
            return ACPV2SessionUpdateOwner(sessionId: "local", upstreamSessionId: "upstream", attachment: attachment,
                fence: fence, journal: journal ?? persistence, submissions: submissions, isCurrent: isCurrent)
        }

        func delivery(_ update: String, cursor: UInt64 = 5, origin: ACPBrokerFrameProvenance.Origin = .journal,
            ack: ACPDurableConsumptionAcknowledgement? = nil) -> ACPV2SessionUpdateDelivery {
            let bytes = Data((#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":"# + update + "}}").utf8)
            return .init(frame: bytes, connectionID: connectionID,
                brokerProvenance: broker ? .init(brokerID: .init(rawValue: "broker"), generation: .init(rawValue: 7), cursor: .init(rawValue: cursor), origin: origin) : nil,
                durableConsumptionAcknowledgement: ack)
        }
    }
}

private actor JournalGate: ACPV2UpdateJournalPersisting {
    let persistence: ACPSessionPersistence
    let operation: ACPV2SessionUpdateOwner.Operation
    let after: Bool
    private(set) var entered = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(_ persistence: ACPSessionPersistence, operation: ACPV2SessionUpdateOwner.Operation, after: Bool) {
        self.persistence = persistence
        self.operation = operation
        self.after = after
    }

    private func pause(_ operation: ACPV2SessionUpdateOwner.Operation, after: Bool) async {
        guard self.operation == operation, self.after == after, !entered else { return }
        entered = true
        await withCheckedContinuation { waiting = $0 }
    }

    func release() { waiting?.resume()
    waiting = nil }

    func registerV2UpdateJournal(sessionId: String, upstreamSessionId: String,
        source: ACPV2UpdateJournalSource, fence: ACPSessionLeaseFence) async throws -> ACPV2UpdateJournalStream {
        await pause(.registration, after: false)
        let result = try await persistence.registerV2UpdateJournal(sessionId: sessionId, upstreamSessionId: upstreamSessionId, source: source, fence: fence)
        await pause(.registration, after: true)
        return result
    }

    func appendV2Update(_ delivery: ACPV2SessionUpdateDelivery, to stream: ACPV2UpdateJournalStream,
        fence: ACPSessionLeaseFence) async throws -> ACPV2UpdateJournalReceipt {
        await pause(.append, after: false)
        let result = try await persistence.appendV2Update(delivery, to: stream, fence: fence)
        await pause(.append, after: true)
        return result
    }

    func loadV2UpdateJournalPage(stream: ACPV2UpdateJournalStream, after: ACPV2UpdateJournalContinuation?,
        maxRecords: Int, maxBytes: Int) async throws -> ACPV2UpdateJournalPage {
        await pause(.replay, after: false)
        let result = try await persistence.loadV2UpdateJournalPage(stream: stream, after: after, maxRecords: maxRecords, maxBytes: maxBytes)
        await pause(.replay, after: true)
        return result
    }
}

private actor PromptSenderFixture: ACPV2PromptSending {
    nonisolated let v2PromptEndpoint: ACPV2PromptEndpoint?
    nonisolated let consumed = Mutex<[Int]>([])
    var sent: [Int] = []
    private var next = 0
    private var pending: [Int: CheckedContinuation<ACPResponse, Error>] = [:]

    private let holdPreparationFailure: Bool
    private let autoReply: Bool
    private(set) var preparationFailureObserved = false
    private let failureRelease = AsyncStream<Void>.makeStream()
    func releasePreparationFailure() { failureRelease.continuation.yield(()) }
    private let preparedConnection: UUID?
    init(connection: UUID, preparedConnection: UUID? = nil, holdPreparationFailure: Bool = false, autoReply: Bool = false) {
        v2PromptEndpoint = .stdio(connectionID: connection)
        self.preparedConnection = preparedConnection
        self.holdPreparationFailure = holdPreparationFailure
        self.autoReply = autoReply
    }

    func sendV2Prompt(_ params: ACPSessionPromptParams, operationKey: ACPBrokerOperationKey?, gate: ACPV2PromptHandoffGate,
        prepare: @escaping @Sendable (ACPV2PreparedPrompt) async throws -> Void) async throws -> ACPResponse {
        next += 1
        let index = next
        let endpoint = preparedConnection.map { ACPV2PromptEndpoint.stdio(connectionID: $0) } ?? v2PromptEndpoint!
        do { try await prepare(.init(endpoint: endpoint, binding: .stdio(requestID: .number(index)))) }
        catch {
            preparationFailureObserved = true
            if holdPreparationFailure { for await _ in failureRelease.stream { break } }
            throw error
        }
        try gate.claim()
        sent.append(index)
        return try await withCheckedThrowingContinuation {
            pending[index] = $0
            if autoReply { respond(index, result: #"{"messageId":"automatic"}"#) }
        }
    }

    func respond(_ index: Int, result: String, error: Bool = false, malformed: Bool = false, missingRaw: Bool = false, wrongConnection: Bool = false) {
        let frame = malformed ? Data("{broken".utf8) : Data("{\"jsonrpc\":\"2.0\",\"id\":\(index),\"\(error ? "error" : "result")\":\(result)}".utf8)
        let count = self
        let delivery = ACPRawRPCDelivery(frame: frame, connectionID: wrongConnection ? UUID() : v2PromptEndpoint!.connectionID,
            source: .stdio(requestID: .number(index), method: "session/prompt"), durableConsumptionAcknowledgement: { count.consumed.withLock { $0.append(index) } })
        let continuation = pending.removeValue(forKey: index)
        if missingRaw { continuation?.resume(throwing: ACPClientError.notRunning) }
        else if error || malformed { continuation?.resume(throwing: ACPRawRPCError(delivery: delivery, rpcError: nil)) }
        else { continuation?.resume(returning: .init(body: Data(result.utf8), rawDelivery: delivery)) }
    }
}

private actor SubmissionJournalGate: ACPV2SubmissionPersisting {
    enum Operation { case registration, retain, page }
    let persistence: ACPSessionPersistence
    let operation: Operation
    let after: Bool
    private(set) var entered = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(_ persistence: ACPSessionPersistence, operation: Operation, after: Bool) {
        self.persistence = persistence
        self.operation = operation
        self.after = after
    }
    private func pause(_ operation: Operation, after: Bool) async {
        guard self.operation == operation, self.after == after, !entered else { return }
        entered = true
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { waiting?.resume()
    waiting = nil }
    func registerV2Submission(id: UUID, sessionId: String, upstreamSessionId: String, localRowID: UUID,
        binding: ACPV2SubmissionBinding, fence: ACPSessionLeaseFence) async throws -> ACPV2SubmissionRegistration {
        await pause(.registration, after: false)
        let value = try await persistence.registerV2Submission(id: id, sessionId: sessionId, upstreamSessionId: upstreamSessionId,
            localRowID: localRowID, binding: binding, fence: fence)
        await pause(.registration, after: true)
        return value
    }
    func retainV2SubmissionOutcome(_ delivery: ACPRawRPCDelivery, for registration: ACPV2SubmissionRegistration,
        fence: ACPSessionLeaseFence) async throws -> ACPV2SubmissionReceipt {
        await pause(.retain, after: false)
        let value = try await persistence.retainV2SubmissionOutcome(delivery, for: registration, fence: fence)
        await pause(.retain, after: true)
        return value
    }
    func loadV2Submission(id: UUID) async throws -> ACPV2SubmissionRecord? { try await persistence.loadV2Submission(id: id) }
    func loadV2SubmissionPage(sessionId: String, upstreamSessionId: String, source: ACPV2SubmissionSource,
        after: ACPV2SubmissionContinuation?, maxRecords: Int, maxBytes: Int) async throws -> ACPV2SubmissionPage {
        await pause(.page, after: false)
        let page = try await persistence.loadV2SubmissionPage(sessionId: sessionId, upstreamSessionId: upstreamSessionId, source: source,
            after: after, maxRecords: maxRecords, maxBytes: maxBytes)
        await pause(.page, after: true)
        return page
    }
}
