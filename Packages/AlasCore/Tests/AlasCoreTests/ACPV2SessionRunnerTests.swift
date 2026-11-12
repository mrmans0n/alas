import Foundation
import Synchronization
import Testing
import AlasCore
@testable import AlasSessions

@MainActor
struct ACPV2SessionRunnerTests {
    @Test func malformedPromptOutcomeWithdrawsWithoutAnotherCapture() async throws {
        let fixture = try await RunnerFixture()
        defer { fixture.stop() }
        _ = try await fixture.start()
        fixture.transport.onSend.withLock { $0 = { _, id, io in io.reply(id, result: "{}") } }
        await #expect(throws: (any Error).self) {
            try await fixture.runner.submit(id: UUID(), row: .user(id: UUID(), messageId: nil, text: "hello", attachments: []), params: .init(sessionId: "upstream", prompt: []))
        }
        try await eventually { await MainActor.run { fixture.runner.status != .ready } }
        #expect(fixture.session.v2Projection?.isObserving == false)
        #expect(fixture.control.completions.isEmpty)
    }

    @Test func callerCancellationReachesThePhysicalReplyBeforeActorSettlement() async throws {
        let persistence = try await ACPV2SessionBootstrapTests.persistence()
        let transport = BootstrapSerializedTransport()
        transport.onWrite.withLock { $0 = { bytes in
            guard let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let method = fields["method"] as? String, let id = fields["id"] as? Int else { return }
            let result = method == "initialize" ? BootstrapTransport.initialization : #"{"sessionId":"upstream"}"#
            transport.emit(Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}".utf8))
        } }
        let session = ACPSession(id: "local", agentId: "fixture", worktreeId: "w", title: "Writer")
        let control = RunnerControl()
        let runner = try ACPV2SessionRunner(session: session, client: .init(transport: transport, sessionUpdateProtocolVersion: .v2),
            persistence: persistence, fence: ACPV2SessionBootstrapTests.fence, info: .init(name: "alas", version: "test"), isCurrent: { true }, onEvent: {
                if case .interaction(.offer(let handle)) = $0 { control.handles.append(handle) }
            })
        defer { runner.stop()
        transport.release.signal()
        transport.onWrite.withLock { $0 = nil }
        transport.terminate() }
        _ = try await runner.start(params: .init(cwd: "/w", mcpServers: []), deadline: .now.advanced(by: .seconds(60)))
        transport.emit(Data(Self.permission.utf8))
        try await eventually { await MainActor.run { control.handles.count == 1 } }
        transport.resetWriteProbe()
        let blocker = Task { await transport.writeFrame(BootstrapSerializedTransport.blocker, authorize: { true }) }
        try await eventually { transport.blocked.withLock { $0 } }
        let handle = control.handles[0]
        let sending = Task { try await runner.decide(handle, decision: .selectPermission(optionID: "yes")) }
        defer { sending.cancel() }
        try await eventually { transport.attempted.withLock { $0 } }
        sending.cancel()
        transport.release.signal()
        // Hold the actor until physical authorization has observed cancellation.
        #expect(transport.waitForAuthorizationCheck() == false)
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(await blocker.value == .written)
        #expect(transport.bytes.withLock { $0.count == 3 && $0.last == BootstrapSerializedTransport.blocker })
        #expect(runner.status == .ready)
    }

    @Test(arguments: ["stop", "ownership", "caller"])
    func withdrawalSettlesOperationsBeforeBlockedDependenciesResume(action: String) async throws {
        let fixture = try await RunnerFixture(holdSubmission: true)
        let gate = try #require(fixture.submissionGate)
        defer { fixture.stop()
        gate.release() }
        _ = try await fixture.start()
        let finished = Mutex(false)
        let sending = Task {
            defer { finished.withLock { $0 = true } }
            return try await fixture.runner.submit(id: UUID(), row: .user(id: UUID(), messageId: nil, text: "blocked", attachments: []), params: .init(sessionId: "upstream", prompt: []))
        }
        defer { sending.cancel() }
        try await eventually { gate.entered.withLock { $0 } }
        if action == "stop" { fixture.runner.stop() }
        else if action == "ownership" { fixture.runner.invalidateOwnership() }
        else { sending.cancel() }
        try await eventually { finished.withLock { $0 } }
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(fixture.transport.frames.withLock { $0.count } == 2)
        #expect(fixture.control.completions.isEmpty)
        if action != "caller" { #expect(fixture.session.v2Projection?.isObserving == false) }
    }

    @Test func validatorWithdrawalCannotAnswerOrMutateASuccessor() async throws {
        let fixture = try await RunnerFixture(form: true)
        defer { fixture.stop() }
        _ = try await fixture.start()
        fixture.transport.emit(Self.form)
        try await eventually { await MainActor.run { fixture.control.handles.count == 1 } }
        let handle = fixture.control.handles[0]
        fixture.control.onValidate = { fixture.runner.invalidateOwnership() }
        await #expect(throws: (any Error).self) { try await fixture.runner.decide(handle, decision: .acceptElicitation(content: .object([:]))) }
        #expect(fixture.runner.status == .ownershipLost)
        #expect(fixture.transport.frames.withLock { $0.count } == 2)
        fixture.session.transcript.replaceMessages(with: [])
        let successor = try ACPV2SessionProjection(session: fixture.session, upstreamSessionId: "next", connectionID: UUID(), isCurrent: { true })
        defer { successor.stop() }
        let epoch = fixture.session.v2Projection?.epoch
        fixture.runner.stop()
        #expect(fixture.session.v2Projection?.epoch == epoch && fixture.session.v2Projection?.isObserving == true)
        fixture.control.onValidate = nil
    }

    @Test func explicitBusyAndInvalidInputCannotInsertAnotherOptimisticRow() async throws {
        let fixture = try await RunnerFixture(holdSubmission: true)
        let gate = try #require(fixture.submissionGate)
        defer { fixture.stop()
        gate.release() }
        _ = try await fixture.start()
        let sending = Task { try await fixture.runner.submit(id: UUID(), row: .user(id: UUID(), messageId: nil, text: "one", attachments: []), params: .init(sessionId: "upstream", prompt: [])) }
        defer { sending.cancel() }
        try await eventually { gate.entered.withLock { $0 } }
        await #expect(throws: ACPV2SessionRunner.Failure.busy) { try await fixture.runner.submit(id: UUID(), row: .user(id: UUID(), messageId: nil, text: "two", attachments: []), params: .init(sessionId: "upstream", prompt: [])) }
        #expect(fixture.session.transcript.messages.count == 1)
        fixture.runner.stop()
    }

    @Test func sourceEndAfterBufferedRunningWithdrawsForegroundWithoutSuccess() async throws {
        let fixture = try await RunnerFixture()
        defer { fixture.stop() }
        _ = try await fixture.start()
        fixture.transport.emit(Self.running)
        fixture.transport.terminate()
        try await eventually { await MainActor.run { fixture.runner.status == .observationLost } }
        #expect(fixture.session.v2Projection?.foreground == .unknown)
        #expect(fixture.control.completions.isEmpty)
    }

    @Test(arguments: [false, true])
    func freshRunnerInstallsBeforeBufferedMethodsAndNeverResetsLiveState(v1: Bool) async throws {
        let fixture = try await RunnerFixture()
        defer { fixture.stop() }
        fixture.transport.onSend.withLock { $0 = { method, id, io in
            if method == "initialize" { io.reply(id, result: v1 ? #"{"protocolVersion":1}"# : BootstrapTransport.initialization) }
            else {
                io.emit(Self.running)
                io.emit(Self.permission)
                io.reply(id, result: #"{"sessionId":"upstream"}"#)
            }
        } }
        if v1 {
            await #expect(throws: (any Error).self) { try await fixture.start() }
            #expect(fixture.runner.status == .replacementRequired)
            #expect(fixture.transport.frames.withLock { $0.count } == 1)
        } else {
            _ = try await fixture.start()
            try await eventually { await MainActor.run { fixture.control.handles.count == 1 && fixture.session.v2Projection?.foreground == .running } }
            #expect(fixture.runner.status == .ready)
            #expect(fixture.control.completions.isEmpty)
            #expect(fixture.session.transcript.messages.count == 1)
        }
    }

    @Test(arguments: ["none", "form", "url", "both"])
    func runnerAdvertisesExactlyItsInstalledInteractionHandlers(mode: String) async throws {
        let fixture = try await RunnerFixture(form: mode == "form" || mode == "both", url: mode == "url" || mode == "both")
        defer { fixture.stop() }
        _ = try await fixture.start()
        let frame = try #require(fixture.transport.frames.withLock { $0.first })
        guard case .object(let fields) = try LSPJSONValue.decode(from: frame), case .object(let params)? = fields["params"], case .object(let capabilities)? = params["capabilities"] else { Issue.record("Missing capabilities")
        return }
        if mode == "none" { #expect(capabilities.isEmpty) }
        else {
            guard case .object(let elicitation)? = capabilities["elicitation"] else { Issue.record("Missing elicitation")
            return }
            #expect((elicitation["form"] == .object([:])) == (mode == "form" || mode == "both"))
            #expect((elicitation["url"] == .object([:])) == (mode == "url" || mode == "both"))
            #expect(capabilities.count == 1)
        }
        fixture.transport.emit(Self.form)
        fixture.transport.emit(Self.url)
        try await eventually { await MainActor.run { fixture.control.decisions.count == 2 } }
        #expect(fixture.control.formOffers == (mode == "form" || mode == "both" ? 1 : 0))
        #expect(fixture.control.urlOffers == (mode == "url" || mode == "both" ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func explicitSubmitCorrelatesOptimisticRowsWithoutCompletingForeground(echoFirst: Bool) async throws {
        let fixture = try await RunnerFixture()
        defer { fixture.stop() }
        await #expect(throws: ACPV2SessionRunner.Failure.notReady) {
            try await fixture.runner.submit(id: UUID(), row: .user(id: UUID(), messageId: nil, text: "hello", attachments: []), params: .init(sessionId: "upstream", prompt: []))
        }
        #expect(fixture.session.transcript.messages.isEmpty)
        _ = try await fixture.start()
        fixture.transport.onSend.withLock { $0 = { method, id, io in
            #expect(method == "session/prompt")
            let echo = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"user_message","messageId":"u","content":[{"type":"text","text":"hello"}]}}}"#
            if echoFirst { io.emit(echo) }
            io.reply(id, result: #"{"messageId":"u"}"#)
            if !echoFirst { io.emit(echo) }
        } }
        let rowID = UUID()
        let result = try await fixture.runner.submit(id: UUID(), row: .user(id: rowID, messageId: nil, text: "hello", attachments: []), params: .init(sessionId: "upstream", prompt: []))
        #expect(result.registration.localRowID == rowID && fixture.control.completions.isEmpty)
        try await eventually { await MainActor.run {
            if case .user(let id, let messageID, _, _, _, _)? = fixture.session.transcript.messages.first { return id == rowID && messageID == "u" }
            return false
        } }
        #expect(fixture.session.transcript.messages.count == 1)
        fixture.transport.emit(Self.running)
        fixture.transport.emit(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}}}"#)
        try await eventually { await MainActor.run { fixture.control.completions.count == 1 } }
    }

    nonisolated static let running = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"state_update","state":"running"}}}"#
    nonisolated static let permission = #"{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"upstream","title":"Approve","options":[{"optionId":"yes","name":"Yes","kind":"allow_once"}],"subject":{"type":"tool_call","toolCall":{"toolCallId":"t","title":"Run"}}}}"#
    nonisolated static let form = #"{"jsonrpc":"2.0","id":8,"method":"elicitation/create","params":{"sessionId":"upstream","mode":"form","message":"Question","requestedSchema":{"type":"object"}}}"#
    nonisolated static let url = #"{"jsonrpc":"2.0","id":9,"method":"elicitation/create","params":{"sessionId":"upstream","mode":"url","message":"Visit","elicitationId":"e","url":"https://example.com"}}"#
}

@MainActor
private final class RunnerControl {
    var handles: [ACPV2RequestDecisionCoordinator.Handle] = []
    var decisions: [ACPV2RequestDecisionCoordinator.Handle] = []
    var completions: [ACPSessionLifecycle.ForegroundCompletion] = []
    var formOffers = 0
    var urlOffers = 0
    var current = true
    var onValidate: (() -> Void)?
}

@MainActor
private final class RunnerFixture {
    let session = ACPSession(id: "local", agentId: "fixture", worktreeId: "w", title: "Runner")
    let transport = BootstrapTransport()
    let control = RunnerControl()
    let persistence: ACPSessionPersistence
    let runner: ACPV2SessionRunner
    let submissionGate: RuntimeSubmissionGate?
    init(form: Bool = false, url: Bool = false, holdSubmission: Bool = false) async throws {
        persistence = try await ACPV2SessionBootstrapTests.persistence()
        submissionGate = holdSubmission ? RuntimeSubmissionGate(base: persistence) : nil
        let control = control
        let formHandler: (@MainActor (ACPV2RequestDecisionCoordinator.Handle) -> Void)?
        let urlHandler: (@MainActor (ACPV2RequestDecisionCoordinator.Handle) -> Void)?
        if form { formHandler = { _ in control.formOffers += 1 } } else { formHandler = nil }
        if url { urlHandler = { _ in control.urlOffers += 1 } } else { urlHandler = nil }
        let handlers = ACPV2SessionRunner.InteractionHandlers(form: formHandler, url: urlHandler, validator: {
            control.onValidate?()
            return ACPV2FormAnswerValidator.validate(schema: $0, content: $1)
        })
        runner = try ACPV2SessionRunner(session: session, client: ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2),
            persistence: persistence, fence: ACPV2SessionBootstrapTests.fence, info: .init(name: "alas", version: "test"), interactions: handlers,
            journals: .init(persistence: persistence, submissions: submissionGate), isCurrent: { control.current }, onEvent: { event in
                switch event {
                case .interaction(.offer(let handle)): control.handles.append(handle)
                control.decisions.append(handle)
                case .interaction(.rejection(let handle)): control.decisions.append(handle)
                case .completion(let completion): control.completions.append(completion)
                default: break
                }
            })
    }
    func start() async throws -> ACPV2SessionNewResult {
        try await runner.start(params: .init(cwd: "/w", mcpServers: []), deadline: .now.advanced(by: .seconds(60)))
    }
    func stop() { runner.stop()
    transport.terminate() }
}
