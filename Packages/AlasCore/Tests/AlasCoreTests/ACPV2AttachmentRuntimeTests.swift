import Foundation
import Synchronization
import Testing
import AlasCore
@testable import AlasSessions

@MainActor
struct ACPV2AttachmentRuntimeTests {
    @Test func everyCommittedRequestIsOfferedWithItsOriginalCaptureAcrossABurst() async throws {
        let fixture = try await RuntimeFixture()
        let runtime = try fixture.runtime()
        defer { runtime.stop()
        fixture.transport.terminate() }
        #expect(runtime.start())
        #expect(!runtime.start())
        for id in 1...12 { fixture.request(id: id) }
        fixture.transport.emit(Data(#"{"jsonrpc":"2.0","method":"peer/notice"}"#.utf8))
        fixture.transport.emit(Data([255, 0]))
        try await eventually { await MainActor.run { fixture.offers.count == 12 && runtime.status == .ready } }
        let stream = try #require(runtime.inboundStream)
        try await eventually { (try? await fixture.persistence.loadV2InboundLedgerPage(stream: stream).records.count) == 14 }
        #expect(fixture.offers.map { $0.record.ordinal }.count == Set(fixture.offers.map { $0.record.ordinal }).count)
        let offer = try #require(fixture.offers.first)
        #expect(try await fixture.persistence.loadV2InboundLedgerPage(stream: stream).records.contains(offer.record))
        let id = String(decoding: try JSONEncoder().encode(try #require(offer.record.decodeHeader().id)), as: UTF8.self)
        let answer = Data(" {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"n\":1e999}} ".utf8)
        let proof = try await runtime.respond(to: offer, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "answer"), frame: answer)
        #expect(proof.value.fact == .stdio(.written))
        #expect(fixture.transport.writes.withLock { $0 } == [answer])
        #expect(fixture.consumed.value.withLock { $0 } == 12)
    }

    @Test func requestsCanBeOfferedDuringRestorationButCommandsWaitForBothOwners() async throws {
        let fixture = try await RuntimeFixture()
        let updateGate = RuntimeUpdateGate(base: fixture.persistence, operation: .replay)
        let runtime = try fixture.runtime(journals: .init(persistence: fixture.persistence, updates: updateGate))
        defer { runtime.stop()
        fixture.transport.terminate()
        Task { await updateGate.release() } }
        #expect(runtime.start())
        fixture.request(id: 7)
        try await eventually { await updateGate.entered }
        try await eventually { await MainActor.run { fixture.offers.count == 1 } }
        let offer = try #require(fixture.offers.first)
        #expect(runtime.status == .restoring)
        await #expect(throws: ACPV2AttachmentRuntime.Failure.notReady) {
            try await runtime.respond(to: offer, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "answer"), frame: Self.answer)
        }
        await #expect(throws: ACPV2AttachmentRuntime.Failure.notReady) {
            try await runtime.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
        }
        await updateGate.release()
        try await eventually { await MainActor.run { runtime.status == .ready } }
        #expect(try await runtime.respond(to: offer, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "answer"), frame: Self.answer).value.fact == .stdio(.written))
    }

    @Test func submissionAcceptanceAndForegroundUpdatesShareTheCanonicalOwner() async throws {
        let fixture = try await RuntimeFixture()
        let runtime = try fixture.runtime()
        defer { runtime.stop()
        fixture.transport.terminate() }
        #expect(runtime.start())
        try await eventually { await MainActor.run { runtime.status == .ready } }
        let record = try await runtime.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
        #expect(runtime.state.lifecycle.submission(record.registration.sequence) == .accepted(messageID: "u1"))
        #expect(runtime.state.lifecycle.lastForegroundCompletion == nil)
        fixture.update(state: "running")
        fixture.update(state: "idle", extra: #", "stopReason":"end_turn""#)
        try await eventually { await MainActor.run { runtime.state.lifecycle.lastForegroundCompletion != nil } }
        #expect(fixture.offers.isEmpty)
        #expect(fixture.transport.writes.withLock { $0.count } == 1)
    }

    @Test func stdioDiagnosticAdaptationPreservesCaptureIdentityAndSingleUseConsumption() throws {
        let count = Mutex(0)
        let original = ACPRawRPCDelivery(frame: Data([255]), connectionID: UUID(), source: .diagnostic,
            durableConsumptionAcknowledgement: { count.withLock { $0 += 1 } })
        let adapted = try ACPV2InboundDelivery(stdioDiagnostic: original)
        #expect(adapted.receiptID == original.receiptID && adapted.connectionID == original.connectionID && adapted.frame == original.frame)
        #expect(count.withLock { $0 } == 0)
        adapted.acknowledgeDurableConsumption()
        original.acknowledgeDurableConsumption()
        #expect(count.withLock { $0 } == 1)
    }

    @Test(arguments: ["registration", "retention"])
    func failedInboundProofCannotOfferOrConsumeARequest(phase: String) async throws {
        let fixture = try await RuntimeFixture()
        let gate = InboundJournalGate(base: fixture.persistence, fault: phase == "registration" ? .registration : .frame)
        let runtime = try fixture.runtime(journals: .init(persistence: fixture.persistence, inbound: gate))
        defer { runtime.stop()
        fixture.transport.terminate() }
        #expect(runtime.start())
        fixture.request(id: 7)
        try await eventually { await MainActor.run { if case .blocked = runtime.status { return true }
        return false } }
        #expect(fixture.offers.isEmpty)
        #expect(fixture.consumed.value.withLock { $0 } == 0)
        #expect(fixture.transport.writes.withLock { $0 }.isEmpty)
        #expect(fixture.transport.terminations.withLock { $0 } == 0)
    }

    @Test func reentrantOfferStopWithdrawsTheHandleAndReceiptConsumption() async throws {
        let fixture = try await RuntimeFixture()
        let runtime = try fixture.runtime()
        fixture.onOffer = { [weak runtime] _ in runtime?.stop() }
        defer { fixture.transport.terminate() }
        #expect(runtime.start())
        fixture.request(id: 7)
        fixture.request(id: 8)
        try await eventually { await MainActor.run { runtime.status == .stopped } }
        #expect(fixture.offers.count == 1)
        #expect(fixture.consumed.value.withLock { $0 } == 0)
        let offer = try #require(fixture.offers.first)
        await #expect(throws: ACPV2AttachmentRuntime.Failure.invalidated) {
            try await runtime.respond(to: offer, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "answer"), frame: Self.answer)
        }
        #expect(!runtime.start())
        #expect(fixture.transport.terminations.withLock { $0 } == 0)
    }

    @Test(arguments: ["stop", "update-failure", "eof", "replacement"])
    func losingEitherOwnerSettlesBlockedResponseCallersWithoutClosingTheTransport(loss: String) async throws {
        let fixture = try await RuntimeFixture()
        let gate = ResponseJournal(base: fixture.persistence, hold: "attempt")
        let runtime = try fixture.runtime(journals: .init(persistence: fixture.persistence, responses: gate))
        defer { runtime.stop()
        fixture.transport.terminate()
        Task { await gate.release() } }
        #expect(runtime.start())
        fixture.request(id: 7)
        try await eventually { await MainActor.run { fixture.offers.count == 1 && runtime.status == .ready } }
        let offer = try #require(fixture.offers.first)
        let settled = Mutex(false)
        let sending = Task {
            defer { settled.withLock { $0 = true } }
            return try await runtime.respond(to: offer, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "answer"), frame: Self.answer)
        }
        defer { sending.cancel() }
        try await eventually { await gate.reached }
        switch loss {
        case "update-failure":
            fixture.transport.emit(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"state_update","state":4}}}"#.utf8))
        case "eof": fixture.transport.continuation.finish()
        case "replacement": fixture.current = false
        runtime.stop()
        default: runtime.stop()
        }
        try await eventually { settled.withLock { $0 } }
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(fixture.transport.writes.withLock { $0 }.isEmpty)
        #expect(fixture.transport.terminations.withLock { $0 } == 0)
        await gate.release()
        await #expect(throws: ACPV2AttachmentRuntime.Failure.invalidated) {
            try await runtime.respond(to: offer, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "later"), frame: Self.answer)
        }
    }

    @Test(arguments: ["submit", "respond"])
    func cancellingOneCommandCannotInvalidateTheAttachment(command: String) async throws {
        let fixture = try await RuntimeFixture()
        let runtime = try fixture.runtime()
        defer { runtime.stop()
        fixture.transport.terminate() }
        #expect(runtime.start())
        fixture.request(id: 7)
        try await eventually { await MainActor.run { runtime.status == .ready && fixture.offers.count == 1 } }
        let request = try #require(fixture.offers.first)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            if command == "submit" {
                _ = try await runtime.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
            } else {
                _ = try await runtime.respond(to: request, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "cancelled"), frame: Self.answer)
            }
        }
        await #expect(throws: (any Error).self) { try await cancelled.value }
        #expect(runtime.status == .ready)
        #expect(fixture.transport.writes.withLock { $0 }.isEmpty)
        #expect(try await runtime.respond(to: request, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "answer"), frame: Self.answer).value.fact == .stdio(.written))
    }

    @Test func observedOwnershipLossWithdrawsTheWholeRuntime() async throws {
        let fixture = try await RuntimeFixture()
        let runtime = try fixture.runtime()
        defer { runtime.stop()
        fixture.transport.terminate() }
        #expect(runtime.start())
        try await eventually { await MainActor.run { runtime.status == .ready } }
        fixture.current = false
        fixture.request(id: 7)
        try await eventually { await MainActor.run { runtime.status == .blocked(.ownershipLost) } }
        #expect(fixture.offers.isEmpty)
        #expect(fixture.consumed.value.withLock { $0 } == 0)
        #expect(fixture.transport.terminations.withLock { $0 } == 0)
    }

    @Test func historyCannotMintHandlesAndForeignRuntimeHandlesCannotAnswer() async throws {
        let fixture = try await RuntimeFixture()
        let stream = try await fixture.persistence.registerV2InboundLedger(sessionId: "local", upstreamSessionId: "upstream",
            source: .stdio(connectionID: fixture.client.updateConnectionID), fence: fixture.fence)
        _ = try await fixture.persistence.retainV2Inbound(.init(frame: Data(#"{"jsonrpc":"2.0","id":99,"method":"peer/history"}"#.utf8),
            connectionID: fixture.client.updateConnectionID, source: .stdio), to: stream, fence: fixture.fence)
        let runtime = try fixture.runtime()
        let other = try await RuntimeFixture()
        let replacement = try other.runtime()
        defer { runtime.stop()
        replacement.stop()
        fixture.transport.terminate()
        other.transport.terminate() }
        #expect(runtime.start() && replacement.start())
        try await eventually { await MainActor.run { runtime.status == .ready && replacement.status == .ready } }
        #expect(fixture.offers.isEmpty)
        fixture.request(id: 7)
        try await eventually { await MainActor.run { fixture.offers.count == 1 } }
        let handle = try #require(fixture.offers.first)
        await #expect(throws: ACPV2AttachmentRuntime.Failure.invalidHandle) {
            try await replacement.respond(to: handle, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "answer"), frame: Self.answer)
        }
        #expect(other.transport.writes.withLock { $0 }.isEmpty)
    }

    @Test func invalidAttachmentConstructionCannotStartLegacyTraffic() async throws {
        let transport = RuntimeTransport()
        let legacy = ACPStdioClient(transport: transport)
        #expect(throws: (any Error).self) { try ACPV2AttachmentRuntime.Attachment(stdioClient: legacy) }
        #expect(transport.writes.withLock { $0 }.isEmpty)
        let fixture = try await RuntimeFixture()
        defer { fixture.transport.terminate() }
        #expect(throws: ACPV2AttachmentRuntime.Failure.invalidAttachment) {
            try ACPV2AttachmentRuntime(sessionId: "foreign", upstreamSessionId: "upstream", attachment: .init(stdioClient: fixture.client),
                fence: fixture.fence, journals: .init(persistence: fixture.persistence), isCurrent: { true }, onRequest: { _ in })
        }
    }

    @Test func siblingFailureWithdrawsAuthorityBeforeAPendingSubmissionResumes() async throws {
        let fixture = try await RuntimeFixture()
        let fault = RuntimeFaultSignal()
        let inbound = RuntimeFaultingInbound(base: fixture.persistence, signal: fault)
        let submissions = RuntimeSubmissionGate(base: fixture.persistence)
        let runtime = try fixture.runtime(journals: .init(persistence: fixture.persistence, inbound: inbound, submissions: submissions))
        defer { runtime.stop()
        fixture.transport.terminate()
        submissions.release() }
        #expect(runtime.start())
        fixture.request(id: 7)
        try await eventually { await MainActor.run { runtime.status == .ready && fixture.offers.count == 1 } }
        let finished = Mutex(false)
        let sending = Task(priority: .high) {
            defer { finished.withLock { $0 = true } }
            return try await runtime.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "upstream", prompt: []))
        }
        defer { sending.cancel() }
        try await eventually { submissions.entered.withLock { $0 } }
        // The inbound worker releases the command from its post-COMMIT
        // ownership check, before rejecting the proof and scheduling monitors.
        fixture.onCurrentCheck = { if fault.take() { submissions.release() } }
        fixture.request(id: 8)
        try await eventually { await MainActor.run { if case .blocked = runtime.status { return true }
        return false } }
        try await eventually { finished.withLock { $0 } }
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(fixture.transport.writes.withLock { $0 }.isEmpty)
        #expect(fixture.consumed.value.withLock { $0 } == 1)
    }

    private static let answer = Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)
}

@MainActor
private final class RuntimeFixture {
    let transport = RuntimeTransport()
    let client: ACPStdioClient
    let persistence: ACPSessionPersistence
    let fence = ACPSessionLeaseFence(sessionId: "local", ownerInstance: "A", token: "owner")
    let consumed = RuntimeCount()
    var current = true
    var onCurrentCheck: (() -> Void)?
    var offers: [ACPV2AttachmentRuntime.Request] = []
    var onOffer: ((ACPV2AttachmentRuntime.Request) -> Void)?

    init() async throws {
        client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("attachment-runtime-\(UUID()).sqlite").path)
        try await persistence.upsertSession(.init(id: "local", agentId: "fixture", title: "Runtime", autoRun: false, createdAt: 1,
            updatedAt: 1, lastOpenedAt: 1, archived: false))
        _ = try await persistence.seizeLease(sessionId: "local", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        try client.start()
    }
    func runtime(journals: ACPV2AttachmentRuntime.Journals? = nil) throws -> ACPV2AttachmentRuntime {
        try .init(sessionId: "local", upstreamSessionId: "upstream", attachment: .init(stdioClient: client), fence: fence,
            journals: journals ?? .init(persistence: persistence), isCurrent: { [weak self] in self?.onCurrentCheck?()
            return self?.current == true },
            onRequest: { [weak self] offer in self?.offers.append(offer)
            self?.onOffer?(offer) })
    }
    func request(id: Int) {
        let count = consumed
        transport.emit(Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"peer/request\"}".utf8),
            consumed: { count.value.withLock { $0 += 1 } })
    }
    func update(state: String, extra: String = "") {
        transport.emit(Data("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"upstream\",\"update\":{\"sessionUpdate\":\"state_update\",\"state\":\"\(state)\"\(extra)}}}".utf8))
    }
}

private final class RuntimeCount: Sendable { let value = Mutex(0) }
private final class RuntimeTransport: JSONRPCStdioTransporting, JSONRPCFrameWriting, Sendable {
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let writes = Mutex<[Data]>([])
    let terminations = Mutex(0)
    init() {
        let input = AsyncStream<JSONRPCStdioTransport.Incoming>.makeStream()
        incoming = input.stream
        continuation = input.continuation
    }
    func start() throws {}
    func emit(_ bytes: Data, consumed: ACPDurableConsumptionAcknowledgement? = nil) { continuation.yield(.frame(bytes, onConsumed: consumed)) }
    func send(_ bytes: Data) throws {
        writes.withLock { $0.append(bytes) }
        let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        if envelope?["method"] as? String == "session/prompt", let id = envelope?["id"] as? Int {
            emit(Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"messageId\":\"u1\"}}".utf8))
        }
    }
    func writeFrame(_ bytes: Data, authorize: @escaping @Sendable () -> Bool) async -> JSONRPCFrameWriteResult {
        guard authorize() else { return .notWritten }
        writes.withLock { $0.append(bytes) }
        return .written
    }
    func terminate() { terminations.withLock { $0 += 1 }
    continuation.finish() }
}

actor RuntimeUpdateGate: ACPV2UpdateJournalPersisting {
    let base: ACPSessionPersistence
    let operation: ACPV2SessionUpdateOwner.Operation
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(base: ACPSessionPersistence, operation: ACPV2SessionUpdateOwner.Operation) { self.base = base
    self.operation = operation }
    func release() { waiter?.resume()
    waiter = nil }
    private func pause(_ phase: ACPV2SessionUpdateOwner.Operation) async {
        guard operation == phase, !entered else { return }
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func registerV2UpdateJournal(sessionId: String, upstreamSessionId: String, source: ACPV2UpdateJournalSource, fence: ACPSessionLeaseFence) async throws -> ACPV2UpdateJournalStream {
        await pause(.registration)
        return try await base.registerV2UpdateJournal(sessionId: sessionId, upstreamSessionId: upstreamSessionId, source: source, fence: fence)
    }
    func appendV2Update(_ delivery: ACPV2SessionUpdateDelivery, to stream: ACPV2UpdateJournalStream, fence: ACPSessionLeaseFence) async throws -> ACPV2UpdateJournalReceipt {
        await pause(.append)
        return try await base.appendV2Update(delivery, to: stream, fence: fence)
    }
    func loadV2UpdateJournalPage(stream: ACPV2UpdateJournalStream, after: ACPV2UpdateJournalContinuation?, maxRecords: Int, maxBytes: Int) async throws -> ACPV2UpdateJournalPage {
        await pause(.replay)
        return try await base.loadV2UpdateJournalPage(stream: stream, after: after, maxRecords: maxRecords, maxBytes: maxBytes)
    }
}

private final class RuntimeFaultSignal: Sendable {
    let ready = Mutex(false)
    func take() -> Bool { ready.withLock { value in let result = value
    value = false
    return result } }
}

private actor RuntimeFaultingInbound: ACPV2InboundLedgerPersisting {
    let base: ACPSessionPersistence
    let signal: RuntimeFaultSignal
    var retained = 0
    init(base: ACPSessionPersistence, signal: RuntimeFaultSignal) { self.base = base
    self.signal = signal }
    func registerV2InboundLedger(sessionId: String, upstreamSessionId: String, source: ACPV2InboundLedgerSource, fence: ACPSessionLeaseFence) async throws -> ACPV2InboundLedgerStream {
        try await base.registerV2InboundLedger(sessionId: sessionId, upstreamSessionId: upstreamSessionId, source: source, fence: fence)
    }
    func retainV2Inbound(_ delivery: ACPV2InboundDelivery, to stream: ACPV2InboundLedgerStream, fence: ACPSessionLeaseFence) async throws -> ACPV2InboundLedgerReceipt {
        let receipt = try await base.retainV2Inbound(delivery, to: stream, fence: fence)
        retained += 1
        guard retained == 2 else { return receipt }
        let record = receipt.record
        signal.ready.withLock { $0 = true }
        return .init(record: .init(streamID: record.streamID, ordinal: record.ordinal, receiptID: record.receiptID,
            connectionID: record.connectionID, source: record.source, frame: Data([0])), wasInserted: receipt.wasInserted)
    }
    func loadV2InboundLedgerPage(stream: ACPV2InboundLedgerStream, after: ACPV2InboundLedgerContinuation?, maxRecords: Int, maxBytes: Int) async throws -> ACPV2InboundLedgerPage {
        try await base.loadV2InboundLedgerPage(stream: stream, after: after, maxRecords: maxRecords, maxBytes: maxBytes)
    }
}

private final class RuntimeSubmissionGate: ACPV2SubmissionPersisting, Sendable {
    let base: ACPSessionPersistence
    let entered = Mutex(false)
    private let waiter = Mutex<CheckedContinuation<Void, Never>?>(nil)
    init(base: ACPSessionPersistence) { self.base = base }
    func release() { waiter.withLock { value in let result = value
    value = nil
    return result }?.resume() }
    func registerV2Submission(id: UUID, sessionId: String, upstreamSessionId: String, localRowID: UUID, binding: ACPV2SubmissionBinding, fence: ACPSessionLeaseFence) async throws -> ACPV2SubmissionRegistration {
        let registration = try await base.registerV2Submission(id: id, sessionId: sessionId, upstreamSessionId: upstreamSessionId, localRowID: localRowID, binding: binding, fence: fence)
        await withCheckedContinuation { continuation in waiter.withLock { $0 = continuation }
        entered.withLock { $0 = true } }
        return registration
    }
    func retainV2SubmissionOutcome(_ delivery: ACPRawRPCDelivery, for registration: ACPV2SubmissionRegistration, fence: ACPSessionLeaseFence) async throws -> ACPV2SubmissionReceipt {
        try await base.retainV2SubmissionOutcome(delivery, for: registration, fence: fence)
    }
    func loadV2Submission(id: UUID) async throws -> ACPV2SubmissionRecord? { try await base.loadV2Submission(id: id) }
    func loadV2SubmissionPage(sessionId: String, upstreamSessionId: String, source: ACPV2SubmissionSource, after: ACPV2SubmissionContinuation?, maxRecords: Int, maxBytes: Int) async throws -> ACPV2SubmissionPage {
        try await base.loadV2SubmissionPage(sessionId: sessionId, upstreamSessionId: upstreamSessionId, source: source, after: after, maxRecords: maxRecords, maxBytes: maxBytes)
    }
}
