import Foundation
import Synchronization
import Testing
import AlasCore
@testable import AlasSessions

@MainActor
struct ACPV2ResponseOwnerTests {
    @Test(arguments: ["available", "intent", "removed", "read-failure"])
    func responseInspectionObservesAuthorityWithoutWriting(reason: String) async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        if reason == "intent" { _ = try await fixture.persistence.registerV2ResponseIntent(id: UUID(), request: fixture.request, in: fixture.stream, frame: ResponseFixture.answer, fence: fixture.fence) }
        if reason == "removed" { await fixture.client.shutdown() }
        let owner = try fixture.owner(journal: ResponseJournal(base: fixture.persistence, fail: reason == "read-failure" ? "inspection" : nil))
        let result = try await owner.inspect(request: fixture.request, delivery: fixture.delivery)
        switch reason {
        case "available": #expect(result == .available)
        case "removed": #expect(result == .unavailable)
        case "read-failure": #expect(result == .observationLost)
        default: guard case .alreadyChosen = result else { Issue.record("Missing chosen evidence")
        return }
        }
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
    }

    @Test func exactResponseCommitsBeforeHandoffAndCopiedCallsNeverWriteAgain() async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let owner = try fixture.owner()
        let intentID = UUID(), attemptID = UUID()
        let durableAtWrite = Mutex(false)
        let path = fixture.persistence.path
        fixture.transport.onWrite.withLock { $0 = { _ in
            let saved = try? ACPSessionStore(path: path).loadV2ResponseAttempt(id: attemptID)
            durableAtWrite.withLock { $0 = saved?.recovery == .uncertain }
        } }
        let first = try await fixture.respond(owner, intent: intentID, attempt: attemptID)
        let copy = try await fixture.respond(owner, intent: intentID, attempt: attemptID)
        #expect(first == copy && first.value.fact == .stdio(.written))
        #expect(durableAtWrite.withLock { $0 })
        #expect(fixture.transport.frames.withLock { $0 } == [ResponseFixture.answer])
        #expect(fixture.consumed.value.withLock { $0 } == 0)
        #expect(try await fixture.persistence.loadV2ResponseAttempt(id: attemptID)?.recovery == .written)
    }

    @Test(arguments: ["invented", "foreign", "invalid"])
    func ineligibleOriginCannotRegisterOrHandOff(reason: String) async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let owner = try fixture.owner()
        let delivery = reason == "invented" ? ACPV2InboundDelivery(frame: fixture.delivery.frame,
            connectionID: fixture.delivery.connectionID, source: .stdio) : fixture.delivery
        if reason == "foreign" { await fixture.client.shutdown() }
        await #expect(throws: (any Error).self) {
            try await owner.respond(request: fixture.request, delivery: delivery, intentID: UUID(), attemptID: UUID(),
                operationKey: .init(rawValue: "answer"), frame: reason == "invalid" ? Data("{}".utf8) : ResponseFixture.answer)
        }
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        #expect(try await fixture.persistence.loadV2ResponseIntentPage(stream: fixture.stream).records.isEmpty)
    }

    @Test func recoveredUnresolvedAttemptCannotInitiateAnotherHandoff() async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let intent = try await fixture.persistence.registerV2ResponseIntent(id: UUID(), request: fixture.request,
            in: fixture.stream, frame: ResponseFixture.answer, fence: fixture.fence).value
        let attempt = try await fixture.persistence.registerV2ResponseAttempt(id: UUID(), for: intent,
            operationKey: .init(rawValue: "answer"), fence: fixture.fence).value
        let owner = try fixture.owner()
        await #expect(throws: ACPV2ResponseOwner.Failure.existingAttempt) {
            try await fixture.respond(owner, intent: intent.id, attempt: attempt.id)
        }
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        #expect(try await fixture.persistence.loadV2ResponseAttempt(id: attempt.id)?.recovery == .uncertain)
    }
    @Test(arguments: ["intent", "attempt", "handoff", "observation"], ["cancel", "stop", "replacement"])
    func invalidationSettlesCallersBeforeBlockedWorkReturns(phase: String, loss: String) async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.release()
        fixture.transport.terminate() }
        let journal = ResponseJournal(base: fixture.persistence, hold: phase)
        fixture.transport.hold.withLock { $0 = phase == "handoff" }
        let owner = try fixture.owner(journal: journal)
        let settled = Mutex(false)
        let intentID = UUID(), attemptID = UUID()
        let sending = Task {
            defer { settled.withLock { $0 = true } }
            return try await fixture.respond(owner, intent: intentID, attempt: attemptID)
        }
        defer { sending.cancel()
        Task { await journal.release() } }
        try await eventually { await journal.reached || fixture.transport.entered.withLock { $0 } }
        if loss == "cancel" { sending.cancel() }
        else {
            if loss == "replacement" { fixture.current = false }
            owner.stop()
        }
        try await eventually { settled.withLock { $0 } }
        await #expect(throws: (any Error).self) { try await sending.value }
        await journal.release()
        fixture.transport.release()
        #expect(fixture.transport.frames.withLock { $0.count } == (phase == "observation" ? 1 : 0))
        if phase == "intent", loss == "cancel" {
            // No attempt registration began, so an explicit fresh call may
            // reconcile the same still-current request after cancellation.
            #expect(try await fixture.respond(owner, intent: intentID, attempt: attemptID).value.fact == .stdio(.written))
            #expect(fixture.transport.frames.withLock { $0.count } == 1)
        } else {
            await #expect(throws: (any Error).self) { try await fixture.respond(owner, intent: intentID, attempt: attemptID) }
        }
    }

    @Test(arguments: [false, true])
    func cancellingJoinedWaiterCannotCancelTheInitiatingOperation(cancelInitiator: Bool) async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let journal = ResponseJournal(base: fixture.persistence, hold: "attempt")
        let owner = try fixture.owner(journal: journal)
        let intentID = UUID(), attemptID = UUID()
        let waiting = Mutex(0)
        let watching = Task { for await event in owner.observations { waiting.withLock { $0 = event.waitingCount } } }
        defer { watching.cancel()
        owner.stop()
        Task { await journal.release() } }
        let firstFinished = Mutex(false)
        let joinedFinished = Mutex(false)
        let first = Task { defer { firstFinished.withLock { $0 = true } }
        return try await fixture.respond(owner, intent: intentID, attempt: attemptID) }
        defer { first.cancel() }
        try await eventually { await journal.reached }
        let joined = Task { defer { joinedFinished.withLock { $0 = true } }
        return try await fixture.respond(owner, intent: intentID, attempt: attemptID) }
        defer { joined.cancel() }
        try await eventually { waiting.withLock { $0 } == 2 }
        if cancelInitiator { first.cancel() } else { joined.cancel() }
        if cancelInitiator {
            try await eventually { joinedFinished.withLock { $0 } && firstFinished.withLock { $0 } }
            await #expect(throws: (any Error).self) { try await joined.value }
            await journal.release()
            await #expect(throws: (any Error).self) { try await first.value }
            #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        } else {
            try await eventually { joinedFinished.withLock { $0 } }
            await #expect(throws: (any Error).self) { try await joined.value }
            await journal.release()
            try await eventually { firstFinished.withLock { $0 } }
            #expect(try await first.value.value.fact == .stdio(.written))
            #expect(fixture.transport.frames.withLock { $0 } == [ResponseFixture.answer])
        }
    }

    @Test(arguments: ["intent", "attempt", "observation"])
    func persistenceFailureNeverInventsADurableWriteOrStartsAnUnregisteredHandoff(phase: String) async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let owner = try fixture.owner(journal: ResponseJournal(base: fixture.persistence, fail: phase))
        let intentID = UUID(), attemptID = UUID()
        await #expect(throws: (any Error).self) { try await fixture.respond(owner, intent: intentID, attempt: attemptID) }
        #expect(fixture.transport.frames.withLock { $0.count } == (phase == "observation" ? 1 : 0))
        let reopened = ACPSessionPersistence(path: fixture.persistence.path)
        #expect(try await reopened.loadV2ResponseAttempt(id: attemptID)?.recovery == (phase == "observation" ? .uncertain : nil))
        if phase == "observation" {
            let replacement = try fixture.owner()
            await #expect(throws: (any Error).self) { try await fixture.respond(replacement, intent: intentID, attempt: attemptID) }
            #expect(fixture.transport.frames.withLock { $0.count } == 1)
        }
    }

    @Test func changedObservationProofCannotPublishInventedWriteCertainty() async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let owner = try fixture.owner(journal: ResponseJournal(base: fixture.persistence, corruptFact: true))
        do { _ = try await fixture.respond(owner)
        Issue.record("Accepted a changed observation proof") }
        catch let error as ACPV2ResponseOwner.Failure {
            if case .outcomePersistence(_, let fact, let message) = error {
                #expect(fact == .stdio(.written) && message.contains("invalidProof"))
            } else { Issue.record("Lost local write fact after rejecting the proof") }
        }
        #expect(fixture.transport.frames.withLock { $0 } == [ResponseFixture.answer])
    }

    @Test func leaseSeizedAtThePipeBoundaryCannotPersistLateWriteSuccess() async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let path = fixture.persistence.path
        fixture.transport.onWrite.withLock { $0 = { _ in
            _ = try? ACPSessionStore(path: path).seizeLease(sessionId: "response", instanceId: "B", pid: 2, now: 2, leaseToken: "new")
        } }
        let owner = try fixture.owner()
        let intentID = UUID(), attemptID = UUID()
        await #expect(throws: (any Error).self) { try await fixture.respond(owner, intent: intentID, attempt: attemptID) }
        #expect(try await fixture.persistence.loadV2ResponseAttempt(id: attemptID)?.recovery == .uncertain)
        #expect(try await fixture.persistence.loadV2ResponseObservationPage(attemptID: attemptID).records.isEmpty)
        #expect(fixture.transport.frames.withLock { $0 } == [ResponseFixture.answer])
    }

    @Test func initiatorCancellationWithdrawsAuthorityBeforeAnotherRegistration() async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.release()
        fixture.transport.terminate() }
        let journal = ResponseJournal(base: fixture.persistence, hold: "intent")
        let owner = try fixture.owner(journal: journal)
        let finished = Mutex(false)
        let intentID = UUID(), attemptID = UUID()
        let sending = Task {
            defer { finished.withLock { $0 = true } }
            return try await fixture.respond(owner, intent: intentID, attempt: attemptID)
        }
        defer { sending.cancel()
        Task { await journal.release() } }
        try await eventually { await journal.reached }
        fixture.onCurrentCheck = { sending.cancel() }
        await journal.release()
        try await eventually { finished.withLock { $0 } }
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(try await fixture.persistence.loadV2ResponseAttemptPage(intentID: intentID).records.isEmpty)
        #expect(!fixture.transport.entered.withLock { $0 })
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
    }

    @Test func observationCommitFailurePreservesTheUncommittedLocalWriteFact() async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let owner = try fixture.owner(journal: ResponseJournal(base: fixture.persistence, fail: "observation"))
        let attemptID = UUID()
        do {
            _ = try await fixture.respond(owner, attempt: attemptID)
            Issue.record("Missing outcome persistence failure")
        } catch let error as ACPV2ResponseOwner.Failure {
            if case .outcomePersistence(let id, let fact, let message) = error {
                #expect(id == attemptID && fact == .stdio(.written) && message.contains("injected"))
            } else { Issue.record("Returned written fact was discarded") }
        }
        #expect(fixture.transport.frames.withLock { $0 } == [ResponseFixture.answer])
        #expect(try await fixture.persistence.loadV2ResponseAttempt(id: attemptID)?.recovery == .uncertain)
    }

    @Test func explicitRetryCanReconcileAfterFailureBeforeRegistration() async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        let owner = try fixture.owner()
        let intentID = UUID(), attemptID = UUID()
        await #expect(throws: ACPV2ResponseOwner.Failure.unavailable) {
            try await owner.respond(request: fixture.request, intentID: intentID, attemptID: attemptID,
                operationKey: .init(rawValue: "answer"), frame: ResponseFixture.answer)
        }
        #expect(try await fixture.persistence.loadV2ResponseIntentPage(stream: fixture.stream).records.isEmpty)
        #expect(try await fixture.respond(owner, intent: intentID, attempt: attemptID).value.fact == .stdio(.written))
        #expect(fixture.transport.frames.withLock { $0 } == [ResponseFixture.answer])
    }

    @Test func onlyFactualNotWrittenAllowsAnExplicitNewKey() async throws {
        let fixture = try await ResponseFixture()
        defer { fixture.transport.terminate() }
        fixture.transport.outcome.withLock { $0 = .notWritten }
        let owner = try fixture.owner()
        let intentID = UUID()
        #expect(try await fixture.respond(owner, intent: intentID).value.fact == .stdio(.notWritten))
        fixture.transport.outcome.withLock { $0 = .written }
        #expect(try await fixture.respond(owner, intent: intentID, key: "new").value.fact == .stdio(.written))
        #expect(fixture.transport.frames.withLock { $0 } == [ResponseFixture.answer])
    }
}

@MainActor
private final class ResponseFixture {
    static let answer = Data(#" {"jsonrpc":"2.0","id":7,"result":{"n":1e999}} "#.utf8)
    let transport = ResponseTransport()
    let client: ACPStdioClient
    let persistence: ACPSessionPersistence
    let fence = ACPSessionLeaseFence(sessionId: "response", ownerInstance: "A", token: "owner")
    let stream: ACPV2InboundLedgerStream
    let delivery: ACPV2InboundDelivery
    let request: ACPV2InboundLedgerRecord
    let consumed: ResponseConsumption
    var current = true
    var onCurrentCheck: (() -> Void)?

    init() async throws {
        client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("response-owner-\(UUID()).sqlite").path)
        try await persistence.upsertSession(.init(id: "response", agentId: "fixture", title: "Saved", autoRun: false,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        _ = try await persistence.seizeLease(sessionId: "response", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        stream = try await persistence.registerV2InboundLedger(sessionId: "response", upstreamSessionId: "upstream",
            source: .stdio(connectionID: client.updateConnectionID), fence: fence)
        try client.start()
        let captured = Mutex<ACPV2InboundDelivery?>(nil)
        let input = client.incomingV2Inbound
        let reading = Task { for await value in input { captured.withLock { $0 = value }
        break } }
        defer { reading.cancel() }
        let count = ResponseConsumption()
        consumed = count
        transport.continuation.yield(.frame(Data(#"{"jsonrpc":"2.0","id":7,"method":"peer/request"}"#.utf8), onConsumed: { count.value.withLock { $0 += 1 } }))
        try await eventually { captured.withLock { $0 != nil } }
        delivery = try #require(captured.withLock { $0 })
        request = try await persistence.retainV2Inbound(delivery, to: stream, fence: fence).record
    }

    func owner(journal: (any ACPV2ResponseLedgerPersisting)? = nil) throws -> ACPV2ResponseOwner {
        try .init(stream: stream, fence: fence, attachment: .init(stdioClient: client), journal: journal ?? persistence,
            isCurrent: { [weak self] in self?.onCurrentCheck?()
            return self?.current == true })
    }
    func respond(_ owner: ACPV2ResponseOwner, intent: UUID = UUID(), attempt: UUID = UUID(), key: String = "answer") async throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseObservation> {
        try await owner.respond(request: request, delivery: delivery, intentID: intent, attemptID: attempt,
            operationKey: .init(rawValue: key), frame: Self.answer)
    }
}

private final class ResponseTransport: JSONRPCStdioTransporting, JSONRPCFrameWriting, Sendable {
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let frames = Mutex<[Data]>([])
    let onWrite = Mutex<(@Sendable (Data) -> Void)?>(nil)
    let outcome = Mutex<JSONRPCFrameWriteResult>(.written)
    let hold = Mutex(false)
    let entered = Mutex(false)
    private let gate = AsyncStream<Void>.makeStream()
    func release() { gate.continuation.yield(()) }

    init() {
        let input = AsyncStream<JSONRPCStdioTransport.Incoming>.makeStream()
        incoming = input.stream
        continuation = input.continuation
    }
    func start() throws {}
    func send(_ data: Data) throws { frames.withLock { $0.append(data) } }
    func writeFrame(_ data: Data, authorize: @escaping @Sendable () -> Bool) async -> JSONRPCFrameWriteResult {
        entered.withLock { $0 = true }
        if hold.withLock({ $0 }) {
            for await _ in gate.stream { break }
        }
        guard authorize() else { return .notWritten }
        let result = outcome.withLock { $0 }
        if result != .notWritten { frames.withLock { $0.append(data) } }
        onWrite.withLock { $0 }?(data)
        return result
    }
    func terminate() { continuation.finish() }
}

private final class ResponseConsumption: Sendable { let value = Mutex(0) }

actor ResponseJournal: ACPV2ResponseLedgerPersisting {
    let base: ACPSessionPersistence
    let hold: String?
    let fail: String?
    let corruptFact: Bool
    private(set) var reached = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(base: ACPSessionPersistence, hold: String? = nil, fail: String? = nil, corruptFact: Bool = false) { self.base = base
    self.hold = hold
    self.fail = fail
    self.corruptFact = corruptFact }
    func release() { waiter?.resume()
    waiter = nil }
    private func pause(_ phase: String) async {
        guard hold == phase, !reached else { return }
        reached = true
        await withCheckedContinuation { waiter = $0 }
    }
    private func check(_ phase: String) throws { if fail == phase { throw ACPV2ResponseOwner.Failure.persistence(message: "injected") } }
    func loadV2ResponseIntentPage(stream: ACPV2InboundLedgerStream, after: ACPV2ResponseLedgerContinuation?, maxRecords: Int, maxBytes: Int) async throws -> ACPV2ResponseLedgerPage<ACPV2ResponseIntent> {
        try check("inspection")
        await pause("inspection")
        return try await base.loadV2ResponseIntentPage(stream: stream, after: after, maxRecords: maxRecords, maxBytes: maxBytes)
    }
    func registerV2ResponseIntent(id: UUID, request: ACPV2InboundLedgerRecord, in stream: ACPV2InboundLedgerStream,
        frame: Data, fence: ACPSessionLeaseFence) async throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseIntent> {
        try check("intent")
        let result = try await base.registerV2ResponseIntent(id: id, request: request, in: stream, frame: frame, fence: fence)
        await pause("intent")
        return result
    }
    func registerV2ResponseAttempt(id: UUID, for intent: ACPV2ResponseIntent, operationKey: ACPV2ReplyOperationKey,
        fence: ACPSessionLeaseFence) async throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseAttempt> {
        try check("attempt")
        let result = try await base.registerV2ResponseAttempt(id: id, for: intent, operationKey: operationKey, fence: fence)
        await pause("attempt")
        return result
    }
    func retainV2ResponseObservation(id: UUID, for attempt: ACPV2ResponseAttempt, evidence: ACPV2ResponseEvidence,
        fence: ACPSessionLeaseFence) async throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseObservation> {
        try check("observation")
        let result = try await base.retainV2ResponseObservation(id: id, for: attempt, evidence: evidence, fence: fence)
        await pause("observation")
        if corruptFact { return .init(value: .init(id: result.value.id, attemptID: result.value.attemptID, sequence: result.value.sequence, fact: .stdio(.notWritten)), wasInserted: result.wasInserted) }
        return result
    }
}
