import Foundation
import Synchronization
import Testing
import AlasCore
@testable import AlasSessions

@MainActor
struct ACPV2RequestDecisionCoordinatorTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["unanswered", "beforeHandoff", "written", "writtenThenCancelled"])
    func stdioIDReuseFollowsTransportAuthorityWhileResponsePersistenceIsPending(phase: String) async throws {
        let wasWritten = phase.hasPrefix("written")
        let fixture = try await DecisionFixture(hold: wasWritten ? "observation" : (phase == "beforeHandoff" ? "attempt" : nil))
        let events = AsyncStream<ACPV2RequestDecisionCoordinator.Event>.makeStream()
        fixture.control.onEvent = { events.continuation.yield($0) }
        defer { events.continuation.finish()
        fixture.stop()
        Task { await fixture.journal.release() } }
        var incoming = events.stream.makeAsyncIterator()
        fixture.permission()
        guard case .offer(let first)? = await incoming.next() else { Issue.record("Missing initial offer")
        return }
        if fixture.runtime.status != .ready {
            for await status in fixture.runtime.observations { if status == .ready { break } }
        }
        try #require(fixture.runtime.status == .ready)
        let finished = Mutex(false)
        var sending: Task<ACPV2ResponseOwner.Receipt, Error>?
        defer { sending?.cancel() }
        if phase != "unanswered" {
            sending = Task { defer { finished.withLock { $0 = true } }
            return try await fixture.coordinator.decide(first, decision: .selectPermission(optionID: "allow")) }
            await fixture.journal.waitUntilReached()
        }
        fixture.permission()
        if wasWritten {
            #expect(!finished.withLock { $0 })
            guard case .offer(let successor)? = await incoming.next() else { Issue.record("Missing reused-ID offer")
            return }
            #expect(fixture.consumed.value.withLock { $0 } == 2)
            #expect(successor.record.receiptID != first.record.receiptID && successor.record.ordinal != first.record.ordinal)
            if phase == "writtenThenCancelled" {
                fixture.emit("$/cancel_request", params: .object(["requestId": .number("7")]))
                var response: Result<ACPV2ResponseOwner.Receipt, any Error>?
                while let event = await incoming.next() {
                    if case .response(let handle, let result) = event, handle.record == successor.record { response = result
                    break }
                }
                #expect(try #require(response).get().value.fact == .stdio(.written))
            } else { #expect(try await fixture.coordinator.decide(successor, decision: .cancelPermission).value.fact == .stdio(.written)) }
            #expect(fixture.transport.frames.withLock { $0.count } == 2)
            await fixture.journal.release()
            #expect(try await #require(sending).value.value.fact == .stdio(.written))
        } else {
            guard case .withdrawn(let handle)? = await incoming.next() else { Issue.record("Missing overlap withdrawal")
            return }
            #expect(handle.record == first.record)
            #expect(fixture.control.handles.count == 1)
            await #expect(throws: (any Error).self) { try await fixture.coordinator.decide(first, decision: .cancelPermission) }
            await fixture.journal.release()
            if let sending { await #expect(throws: (any Error).self) { try await sending.value } }
            #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        }
    }

    @Test func ownershipLossAtDispatchSettlesTheAlreadyRegisteredWaiter() async throws {
        let fixture = try await DecisionFixture()
        defer { fixture.stop() }
        fixture.form()
        let handle = try await fixture.firstHandle()
        var checks = 2
        fixture.control.onValidate = { fixture.control.onCurrent = { checks -= 1
        return checks >= 0 } }
        let finished = Mutex(false)
        let sending = Task { defer { finished.withLock { $0 = true } }
        return try await fixture.coordinator.decide(handle, decision: .acceptElicitation(content: .object([:]))) }
        defer { sending.cancel() }
        try await eventually { finished.withLock { $0 } }
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
    }

    @Test func callerCancellationWithdrawsQueuedWriterBeforeTheActorHop() async throws {
        let persistence = try await ACPV2SessionBootstrapTests.persistence()
        let transport = BootstrapSerializedTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let control = DecisionControl()
        let coordinator = ACPV2RequestDecisionCoordinator(upstreamSessionId: "s", support: .init(), isCurrent: { true },
            onEvent: { control.events.append($0) })
        let runtime = try ACPV2AttachmentRuntime(sessionId: "local", upstreamSessionId: "s", attachment: .init(stdioClient: client),
            fence: ACPV2SessionBootstrapTests.fence, journals: .init(persistence: persistence), isCurrent: { true }, onRequest: { _ in },
            onInbound: coordinator.receive, onLifecycleChange: coordinator.runtimeDidChange)
        defer { coordinator.stop()
        runtime.stop()
        transport.release.signal()
        transport.terminate() }
        try coordinator.bind(to: runtime)
        _ = runtime.start()
        transport.emit(Data(#"{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"s","title":"Choose","options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}"#.utf8))
        try await eventually { await MainActor.run { runtime.status == .ready && control.handles.count == 1 } }
        let blocker = Task { await transport.writeFrame(BootstrapSerializedTransport.blocker, authorize: { true }) }
        try await eventually { transport.blocked.withLock { $0 } }
        let handle = try #require(control.handles.first)
        let sending = Task { try await coordinator.decide(handle, decision: .selectPermission(optionID: "allow")) }
        defer { sending.cancel() }
        try await eventually { transport.attempted.withLock { $0 } }
        sending.cancel()
        transport.release.signal()
        // Keep this actor turn until the serialized writer checks authorization.
        // A queued actor-hop cancellation must not be the only thing preventing output.
        #expect(transport.waitForAuthorizationCheck() == false)
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(await blocker.value == .written)
        #expect(transport.bytes.withLock { $0 } == [BootstrapSerializedTransport.blocker])
        #expect(runtime.status == .ready)
    }

    @Test(arguments: ["answer-intent", "answer-attempt", "answer-observation", "cancel", "restoring"])
    func answerAndCancellationRespectTheFirstSynchronousClaim(first: String) async throws {
        let answerFirst = first.hasPrefix("answer-")
        let fixture = try await DecisionFixture(hold: answerFirst ? String(first.dropFirst(7)) : nil, restoreBlocked: first == "restoring")
        defer { fixture.stop()
        Task { await fixture.journal.release()
        await fixture.restoreGate.release() } }
        fixture.permission()
        let handle = try await fixture.firstHandle()
        var sending: Task<ACPV2ResponseOwner.Receipt, Error>?
        defer { sending?.cancel() }
        if answerFirst {
            sending = Task { try await fixture.coordinator.decide(handle, decision: .selectPermission(optionID: "allow")) }
            try await eventually { await fixture.journal.reached }
        }
        fixture.emit("$/cancel_request", params: .object(["requestId": .number("7")]))
        try await eventually { fixture.consumed.value.withLock { $0 } == 2 }
        if answerFirst { await fixture.journal.release()
        _ = try await sending?.value }
        else {
            await #expect(throws: (any Error).self) { try await fixture.coordinator.decide(handle, decision: .selectPermission(optionID: "allow")) }
            if first == "restoring" { #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
            await fixture.restoreGate.release() }
        }
        try await eventually { fixture.transport.frames.withLock { $0.count } == 1 }
        let frame = try #require(fixture.transport.frames.withLock { $0.first })
        guard case .object(let fields) = try LSPJSONValue.decode(from: frame) else { return }
        let outcome: LSPJSONValue = answerFirst ? .object(["outcome": .string("selected"), "optionId": .string("allow")]) : .object(["outcome": .string("cancelled")])
        #expect(fields["result"] == .object(["outcome": outcome]))
    }

    @Test(arguments: [false, true])
    func cancelRequestNeverTargetsTheOppositeDirectionOrALaterReuse(oppositeDirection: Bool) async throws {
        let fixture = try await DecisionFixture()
        defer { fixture.stop() }
        if oppositeDirection {
            try await eventually { await MainActor.run { fixture.runtime.status == .ready } }
            let finished = Mutex(false)
            let submitting = Task { defer { finished.withLock { $0 = true } }
            return try await fixture.runtime.submit(id: UUID(), localRowID: UUID(), params: .init(sessionId: "s", prompt: [])) }
            defer { submitting.cancel() }
            try await eventually { fixture.transport.frames.withLock { $0.count } == 1 }
            let bytes = try #require(fixture.transport.frames.withLock { $0.first })
            guard case .object(let fields) = try LSPJSONValue.decode(from: bytes), let rpcID = fields["id"] else { Issue.record("Missing outgoing ID")
            return }
            fixture.permission(id: rpcID)
            _ = try await fixture.firstHandle()
            fixture.emit("$/cancel_request", params: .object(["requestId": rpcID]))
            try await eventually { fixture.transport.frames.withLock { $0.count } == 2 }
            #expect(!finished.withLock { $0 })
            fixture.transport.emit(try LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": rpcID, "result": .object(["messageId": .string("user")])]).encodedData())
            #expect(try await submitting.value.outcome != nil)
            return
        }
        fixture.emit("$/cancel_request", params: .object(["requestId": .number("7")]))
        fixture.permission(id: .string("7"))
        let first = try await fixture.firstHandle()
        fixture.emit("$/cancel_request", params: .object(["requestId": .number("7")]))
        try await eventually { fixture.consumed.value.withLock { $0 } == 3 }
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        _ = try await fixture.coordinator.decide(first, decision: .selectPermission(optionID: "allow"))
        fixture.emit("$/cancel_request", params: .object(["requestId": .string("7")]))
        try await eventually { fixture.consumed.value.withLock { $0 } == 4 }
        fixture.permission(id: .string("7"))
        try await eventually { await MainActor.run { fixture.control.handles.count == 2 } }
        _ = try await fixture.coordinator.decide(fixture.control.handles[1], decision: .cancelPermission)
        #expect(fixture.transport.frames.withLock { $0.count } == 2)
    }

    @Test(arguments: ["pending", "observation", "failure", "notWritten", "uncertain"])
    func urlCompletionIsIndependentOfConsentAndReplyPersistence(phase: String) async throws {
        let fixture = try await DecisionFixture(hold: phase == "observation" ? "observation" : nil, fail: phase == "failure" ? "observation" : nil)
        defer { fixture.stop()
        Task { await fixture.journal.release() } }
        fixture.emit("elicitation/create", id: .number("7"), params: .object(["sessionId": .string("s"), "mode": .string("url"),
            "message": .string("Sign in"), "elicitationId": .string("flow"), "url": .string("https://example.test/login")]))
        let handle = try await fixture.firstHandle()
        if phase == "pending" || phase == "uncertain" {
            fixture.emit("elicitation/complete", params: .object(["elicitationId": .string("flow")]))
            try await eventually { fixture.consumed.value.withLock { $0 } == 2 }
            #expect(fixture.coordinator.urlWorkflows.first?.consent == .pending)
            #expect(fixture.coordinator.urlWorkflows.first?.completion != nil)
            #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        }
        if phase == "notWritten" { fixture.transport.result.withLock { $0 = .notWritten } }
        if phase == "uncertain" { fixture.transport.result.withLock { $0 = .writeUncertain("injected") } }
        let sending = Task { try await fixture.coordinator.decide(handle, decision: .acceptElicitation(content: nil)) }
        defer { sending.cancel() }
        if phase == "observation" { try await eventually { await fixture.journal.reached } }
        if phase == "uncertain" {
            await #expect(throws: (any Error).self) { try await sending.value }
            #expect(fixture.coordinator.urlWorkflows.first?.completion != nil)
            #expect(fixture.runtime.status != .ready)
            if case .success? = fixture.coordinator.urlWorkflows.first?.response { Issue.record("Fabricated durable success") }
            return
        }
        fixture.emit("elicitation/complete", params: .object(["elicitationId": .string("flow")]))
        fixture.emit("elicitation/complete", params: .object(["elicitationId": .string("flow")]))
        fixture.emit("elicitation/complete", params: .object(["elicitationId": .string("unknown")]))
        try await eventually { fixture.consumed.value.withLock { $0 } == (["pending", "uncertain"].contains(phase) ? 5 : 4) }
        #expect(fixture.coordinator.urlWorkflows.count == 1)
        let workflow = try #require(fixture.coordinator.urlWorkflows.first)
        #expect(workflow.completion != nil)
        #expect(workflow.consent == .accepted)
        #expect(fixture.runtime.state.lifecycle.lastForegroundCompletion == nil)
        if phase == "observation" { #expect(workflow.response == nil)
        await fixture.journal.release() }
        if phase == "failure" {
            do { _ = try await sending.value
            Issue.record("Missing persistence failure") }
            catch let failure as ACPV2ResponseOwner.Failure {
                guard case .outcomePersistence(_, .stdio(.written), _) = failure else { Issue.record("Lost local write fact")
                return }
            }
        } else {
            let fact = try await sending.value.value.fact
            if phase == "notWritten" { #expect(fact == .stdio(.notWritten)) }
            else if phase == "uncertain" { guard case .uncertain = fact else { Issue.record("Lost uncertainty")
            return } }
            else { #expect(fact == .stdio(.written)) }
        }
        fixture.emit("elicitation/create", id: .number("8"), params: .object(["sessionId": .string("s"), "mode": .string("url"),
            "message": .string("Again"), "elicitationId": .string("flow"), "url": .string("https://example.test")]))
        try await eventually { fixture.consumed.value.withLock { $0 } == (phase == "pending" ? 6 : 5) }
        #expect(fixture.control.handles.count == 1)
        #expect(fixture.transport.frames.withLock { $0.count } == (phase == "notWritten" ? 0 : 1))
        try await eventually { await MainActor.run { fixture.control.events.contains { if case .rejection = $0 { return true }
        return false } } }
        let rejected = try #require(fixture.control.events.compactMap { if case .rejection(let handle) = $0 { return handle }
        return nil }.first)
        await #expect(throws: (any Error).self) { try await fixture.coordinator.decide(rejected, decision: .acceptElicitation(content: nil)) }
        fixture.transport.result.withLock { $0 = nil }
        if phase == "failure" {
            await #expect(throws: (any Error).self) { try await fixture.coordinator.decide(rejected, decision: .reject(.invalidParams)) }
        } else { _ = try await fixture.coordinator.decide(rejected, decision: .reject(.invalidParams)) }
        #expect(fixture.coordinator.urlWorkflows.count == 1)
        #expect(fixture.transport.frames.withLock { $0.count } == (phase == "notWritten" ? 1 : 2))
    }

    @Test(arguments: ["method", "mode", "malformed"])
    func explicitProtocolRejectionsUseTheSameDurableOwner(reason: String) async throws {
        let fixture = try await DecisionFixture()
        defer { fixture.stop() }
        fixture.emit(reason == "method" ? "future/request" : "elicitation/create", id: .number("7"),
            params: reason == "mode" ? .object(["sessionId": .string("s"), "mode": .string("future")]) : .object([:]))
        try await eventually { await MainActor.run { fixture.control.events.contains { if case .rejection = $0 { return true }
        return false } } }
        let handle = try #require(fixture.control.events.compactMap { if case .rejection(let value) = $0 { return value }
        return nil }.first)
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        _ = try await fixture.coordinator.decide(handle, decision: .reject(reason == "method" ? .methodNotFound : .invalidParams))
        let bytes = try #require(fixture.transport.frames.withLock { $0.first })
        guard case .object(let fields) = try LSPJSONValue.decode(from: bytes), case .object(let error)? = fields["error"] else { return }
        #expect(error["code"] == .number(reason == "method" ? "-32601" : "-32602"))
    }

    @Test func decisionsCommitOneOriginalReplyAndNeverAcknowledgeTwice() async throws {
        let fixture = try await DecisionFixture()
        defer { fixture.stop() }
        fixture.permission()
        let handle = try await fixture.firstHandle()
        let stream = try #require(fixture.runtime.inboundStream)
        let path = fixture.persistence.path
        let durable = Mutex(false)
        fixture.transport.onWrite.withLock { $0 = { bytes in
            let store = try? ACPSessionStore(path: path)
            let intents = try? store?.loadV2ResponseIntentPage(stream: stream).records
            if let intent = intents?.first, let attempts = try? store?.loadV2ResponseAttemptPage(intentID: intent.id).records {
                durable.withLock { $0 = attempts.count == 1 && intent.frame == bytes }
            }
        } }
        try await eventually { fixture.consumed.value.withLock { $0 } == 1 }
        let result = try await fixture.coordinator.decide(handle, decision: .selectPermission(optionID: "allow"))
        #expect(result.value.fact == .stdio(.written) && durable.withLock { $0 })
        await #expect(throws: (any Error).self) { try await fixture.coordinator.decide(handle, decision: .cancelPermission) }
        #expect(fixture.transport.frames.withLock { $0.count } == 1)
        #expect(fixture.consumed.value.withLock { $0 } == 1)
        let frame = try #require(fixture.transport.frames.withLock { $0.first })
        guard case .object(let envelope) = try LSPJSONValue.decode(from: frame) else { Issue.record("Missing frame")
        return }
        #expect(envelope["id"] == .number("7"))
        #expect(envelope["result"] == .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("allow")])]))
    }

    @Test(arguments: ["option", "form", "notReady"])
    func invalidAnswersAreCorrectableBeforeTheDecisionClaim(reason: String) async throws {
        let fixture = try await DecisionFixture(restoreBlocked: reason == "notReady")
        defer { fixture.stop()
        Task { await fixture.restoreGate.release() } }
        if reason == "form" { fixture.form() } else { fixture.permission() }
        let handle = try await fixture.firstHandle()
        await #expect(throws: (any Error).self) {
            try await fixture.coordinator.decide(handle, decision: reason == "form" ? .acceptElicitation(content: .object(["x": .string("a")])) : .selectPermission(optionID: reason == "option" ? "foreign" : "allow"))
        }
        let stream = try #require(fixture.runtime.inboundStream)
        #expect(try await fixture.persistence.loadV2ResponseIntentPage(stream: stream).records.isEmpty)
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        await fixture.restoreGate.release()
        try await eventually { await MainActor.run { fixture.runtime.status == .ready } }
        let result = try await fixture.coordinator.decide(handle, decision: reason == "form" ? .declineElicitation : .selectPermission(optionID: "allow"))
        #expect(result.value.fact == .stdio(.written))
    }

    @Test(arguments: ["duplicate", "validator", "offer"])
    func duplicateAndReentrantAnswersCannotCreateAnotherAttempt(phase: String) async throws {
        let fixture = try await DecisionFixture(hold: phase == "duplicate" ? "intent" : nil)
        defer { fixture.stop()
        Task { await fixture.journal.release() } }
        if phase == "offer" { fixture.control.onEvent = { [weak fixture] event in if case .offer = event { fixture?.coordinator.stop() } } }
        if phase == "validator" { fixture.control.onValidate = { [weak fixture] in fixture?.coordinator.stop() }
        fixture.form() }
        else { fixture.permission() }
        let handle = try await fixture.firstHandle()
        if phase == "duplicate" {
            let first = Task { try await fixture.coordinator.decide(handle, decision: .selectPermission(optionID: "allow")) }
            defer { first.cancel() }
            try await eventually { await fixture.journal.reached }
            await #expect(throws: (any Error).self) { try await fixture.coordinator.decide(handle, decision: .cancelPermission) }
            await fixture.journal.release()
            #expect(try await first.value.value.fact == .stdio(.written))
            #expect(fixture.transport.frames.withLock { $0.count } == 1)
        } else {
            await #expect(throws: (any Error).self) { try await fixture.coordinator.decide(handle, decision: phase == "validator" ? .acceptElicitation(content: .object([:])) : .cancelPermission) }
            #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
        }
    }

    @Test(arguments: ["chosen", "stop", "cancel"])
    func durableChosenOriginsDoNotBecomeFreshDecisionOffers(duringInspection: String) async throws {
        let fixture = try await DecisionFixture(hold: "inspection")
        defer { fixture.stop()
        Task { await fixture.journal.release() } }
        fixture.permission()
        try await eventually { await fixture.journal.reached }
        let stream = try #require(fixture.runtime.inboundStream)
        let record = try #require(try await fixture.persistence.loadV2InboundLedgerPage(stream: stream).records.first)
        _ = try await fixture.persistence.registerV2ResponseIntent(id: UUID(), request: record, in: stream,
            frame: Data(#"{"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"cancelled"}}}"#.utf8), fence: fixture.fence)
        if duringInspection == "cancel" {
            fixture.emit("$/cancel_request", params: .object(["requestId": .number("7")]))
            try await eventually { fixture.consumed.value.withLock { $0 } == 2 }
        }
        if duringInspection == "stop" { fixture.coordinator.stop() }
        await fixture.journal.release()
        if duringInspection != "stop" { try await eventually { await MainActor.run { fixture.control.unavailableCount == 1 } } }
        #expect(fixture.control.handles.isEmpty)
        #expect(fixture.transport.frames.withLock { $0 }.isEmpty)
    }

    @Test(arguments: ["intent", "attempt", "observation"], [false, true])
    func withdrawalSettlesBlockedDecisionWaitersWithoutLateSuccess(phase: String, callerCancels: Bool) async throws {
        let fixture = try await DecisionFixture(hold: phase)
        defer { fixture.stop()
        Task { await fixture.journal.release() } }
        fixture.permission()
        let handle = try await fixture.firstHandle()
        let finished = Mutex(false)
        let sending = Task { defer { finished.withLock { $0 = true } }
        return try await fixture.coordinator.decide(handle, decision: .selectPermission(optionID: "allow")) }
        defer { sending.cancel() }
        try await eventually { await fixture.journal.reached }
        if callerCancels { sending.cancel() } else { fixture.coordinator.stop() }
        try await eventually { finished.withLock { $0 } }
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(fixture.transport.frames.withLock { $0.count } == (phase == "observation" ? 1 : 0))
        await fixture.journal.release()
    }
}

@MainActor
final class DecisionFixture {
    let transport = DecisionTransport()
    let client: ACPStdioClient
    let persistence: ACPSessionPersistence
    let fence = ACPSessionLeaseFence(sessionId: "local", ownerInstance: "A", token: "owner")
    let control = DecisionControl()
    let consumed = DecisionCount()
    let journal: ResponseJournal
    let restoreGate: RuntimeUpdateGate
    let runtime: ACPV2AttachmentRuntime
    let coordinator: ACPV2RequestDecisionCoordinator
    init(hold: String? = nil, fail: String? = nil, restoreBlocked: Bool = false, start: Bool = true) async throws {
        persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("decisions-\(UUID()).sqlite").path)
        try await persistence.upsertSession(.init(id: "local", agentId: "fixture", title: "Decisions", autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        _ = try await persistence.seizeLease(sessionId: "local", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        journal = .init(base: persistence, hold: hold, fail: fail)
        restoreGate = .init(base: persistence, operation: .replay)
        client = .init(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let control = control
        coordinator = .init(upstreamSessionId: "s", support: .init(elicitation: true, form: true, url: true),
            formValidator: { schema, content in if let callback = control.onValidate { callback()
            return .valid }
            return ACPV2FormAnswerValidator.validate(schema: schema, content: content) },
            isCurrent: { control.current && (control.onCurrent?() ?? true) }, onEvent: { event in control.events.append(event)
            control.onEvent?(event) })
        let coordinator = coordinator
        runtime = try .init(sessionId: "local", upstreamSessionId: "s", attachment: .init(stdioClient: client), fence: fence,
            journals: .init(persistence: persistence, updates: restoreBlocked ? restoreGate : nil, responses: journal), isCurrent: { control.current }, onRequest: { _ in },
            onInbound: { [weak coordinator] event in try coordinator?.receive(event) },
            onLifecycleChange: { [weak coordinator] event in coordinator?.runtimeDidChange(event) })
        try coordinator.bind(to: runtime)
        if start { _ = runtime.start() }
    }
    func stop() { control.onEvent = nil
    control.onValidate = nil
    coordinator.stop()
    runtime.stop()
    transport.terminate() }
    func firstHandle() async throws -> ACPV2RequestDecisionCoordinator.Handle {
        try await eventually { await MainActor.run { !self.control.handles.isEmpty } }
        return try #require(control.handles.first)
    }
    func permission(id: LSPJSONValue = .number("7")) {
        emit("session/request_permission", id: id, params: .object(["sessionId": .string("s"), "title": .string("Choose"), "options": .array([
            .object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")]),
            .object(["optionId": .string("reject"), "name": .string("Reject"), "kind": .string("reject_once")]),
        ])]))
    }
    func form(id: LSPJSONValue = .number("7")) {
        emit("elicitation/create", id: id, params: .object(["sessionId": .string("s"), "mode": .string("form"), "message": .string("Question"),
            "requestedSchema": .object(["type": .string("object"), "properties": .object(["x": .object(["type": .string("string"), "pattern": .string("^a")])])])]))
    }
    func emit(_ method: String, id: LSPJSONValue? = nil, params: LSPJSONValue) {
        var fields: [String: LSPJSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
        fields["id"] = id
        let count = consumed
        transport.emit(try! LSPJSONValue.object(fields).encodedData(), consumed: { count.value.withLock { $0 += 1 } })
    }
}
@MainActor
final class DecisionControl {
    var current = true
    var events: [ACPV2RequestDecisionCoordinator.Event] = []
    var onEvent: ((ACPV2RequestDecisionCoordinator.Event) -> Void)?
    var onValidate: (() -> Void)?
    var onCurrent: (() -> Bool)?
    var handles: [ACPV2RequestDecisionCoordinator.Handle] { events.compactMap { if case .offer(let handle) = $0 { return handle }
    return nil } }
    var unavailableCount: Int { events.filter { if case .unavailable = $0 { return true }
    return false }.count }
}
final class DecisionCount: Sendable { let value = Mutex(0) }
final class DecisionTransport: JSONRPCStdioTransporting, JSONRPCFrameWriting, Sendable {
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let frames = Mutex<[Data]>([])
    let result = Mutex<JSONRPCFrameWriteResult?>(nil)
    let onWrite = Mutex<(@Sendable (Data) -> Void)?>(nil)
    init() { let input = AsyncStream<JSONRPCStdioTransport.Incoming>.makeStream()
    incoming = input.stream
    continuation = input.continuation }
    func start() throws {}
    func emit(_ frame: Data, consumed: ACPDurableConsumptionAcknowledgement? = nil) { continuation.yield(.frame(frame, onConsumed: consumed)) }
    func send(_ data: Data) throws { frames.withLock { $0.append(data) } }
    func writeFrame(_ data: Data, authorize: @escaping @Sendable () -> Bool) async -> JSONRPCFrameWriteResult {
        guard authorize() else { return .notWritten }
        if case .notWritten? = result.withLock({ $0 }) { return .notWritten }
        onWrite.withLock { $0 }?(data)
        frames.withLock { $0.append(data) }
        return result.withLock { $0 } ?? .written
    }
    func terminate() { continuation.finish() }
}
