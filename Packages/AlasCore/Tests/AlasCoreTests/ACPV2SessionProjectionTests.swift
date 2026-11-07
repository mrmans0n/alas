import Foundation
import Testing
import AlasCore
@testable import AlasSessions

@MainActor
struct ACPV2SessionProjectionTests {
    @Test func displaySnapshotPreservesRowIdentityAndFinalText() throws {
        let fixture = try ProjectionFixture()
        try fixture.update(#"{"sessionUpdate":"agent_message","messageId":"m","content":[{"type":"text","text":"one"}]}"#)
        let first = try #require(fixture.session.transcript.messages.first)
        try fixture.update(#"{"sessionUpdate":"tool_call_update","toolCallId":"tool","title":"Run","status":"in_progress"}"#)
        try fixture.update(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[{"content":"work","priority":"high","status":"pending"}]}}"#)
        try fixture.update(#"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":" two"}}"#)
        #expect(fixture.session.transcript.messages.count == 3)
        #expect(fixture.session.transcript.messages.first?.stableId == first.stableId)
        if case .agent(_, _, let text) = fixture.session.transcript.messages[0] { #expect(text.value == "one two") }
        else { Issue.record("Missing agent row") }
        let original = fixture.session.transcript.messages + [.user(id: UUID(), text: "local", attachments: [])]
        let snapshot = try ACPV2PreviewDisplaySnapshot(sessionId: "local", installationID: UUID(), sequence: 1,
            status: .observing, messages: original)
        let decoded = try JSONDecoder().decode(ACPV2PreviewDisplaySnapshot.self, from: JSONEncoder().encode(snapshot))
        try fixture.update(#"{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"!"}}"#)
        let restored = try decoded.decodeMessages()
        #expect(restored.map(\.stableIdentityKey) == original.map(\.stableIdentityKey))
        if case .agent(_, _, let text) = restored[0] { #expect(text.value == "one two") }
        else { Issue.record("Missing saved text") }
        #expect(decoded.reopenedStatus == .interrupted)
        try fixture.update(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[]}}"#)
        #expect(fixture.session.transcript.messages.count == 3)
        #expect(fixture.session.v2Projection?.canonical.order.count == 3)
    }

    @Test(arguments: ["format", "identity", "payload"])
    func malformedPreviewDisplayCannotRestoreRows(reason: String) throws {
        let row = ACPMessage.user(id: UUID(), text: "saved", attachments: [])
        let encoded = try ACPMessageCodec.encode(row)
        let snapshot = ACPV2PreviewDisplaySnapshot(sessionId: "local", installationID: UUID(), sequence: 1,
            status: .ended, rows: [.init(identity: reason == "identity" ? .agentUUID(UUID()) : row.stableIdentityKey,
                kind: row.kind, payload: reason == "payload" ? Data([255]) : encoded)], formatVersion: reason == "format" ? 2 : 1)
        #expect(throws: (any Error).self) { try snapshot.decodeMessages() }
    }

    @Test func markdownPlanProjectsAsDocument() throws {
        let fixture = try ProjectionFixture()
        try fixture.update(##"{"sessionUpdate":"plan_update","plan":{"type":"markdown","planId":"p","content":"# A"}}"##)
        try fixture.update(#"{"sessionUpdate":"plan_update","plan":{"type":"_future","planId":"f"}}"#)
        #expect(fixture.session.transcript.messages.count == 1)
        guard case .planDocument(_, let document)? = fixture.session.transcript.messages.first else {
            Issue.record("expected a plan document, got \(fixture.session.transcript.messages)")
            return
        }
        #expect(document == ACPPlanDocument(planId: "p", kind: .markdown, markdown: "# A", file: nil))
        #expect(fixture.session.transcript.currentPlan == nil)
    }

    @Test(arguments: [false, true])
    func acceptedEchoReusesOnlyTheRegisteredLocalRow(echoFirst: Bool) throws {
        let rowID = UUID()
        let attachment = ACPMessage.Attachment(uri: "file:///local", name: "local")
        let local = ACPMessage.user(id: rowID, messageId: nil, text: "same", attachments: [attachment])
        let fixture = try ProjectionFixture(optimistic: [local])
        _ = fixture.state.register(requestID: 1, localRowID: rowID, context: fixture.state.context)
        if echoFirst { try fixture.update(Self.echo) }
        let accepted = try ACPV2PromptAccepted.decode(from: Data(#"{"messageId":"u"}"#.utf8))
        let reduction = fixture.state.accept(requestID: 1, response: accepted, context: fixture.state.context)
        // Use the full canonical publication to reconcile even when acceptance follows the echo.
        try fixture.publish(effects: reduction.effects)
        if !echoFirst { try fixture.update(Self.echo) }
        try fixture.update(#"{"sessionUpdate":"user_message","messageId":"other","content":[{"type":"text","text":"same"}]}"#)
        #expect(fixture.session.transcript.messages.count == 2)
        if case .user(let id, let messageID, let text, let attachments, _, _) = fixture.session.transcript.messages[0] {
            #expect(id == rowID && messageID == "u" && text == "same" && attachments == [attachment])
        } else { Issue.record("Missing correlated row") }
    }

    @Test(arguments: ["willChange", "valueSignal", "added"])
    func observerReplacementCannotMutateTheSuccessor(boundary: String) throws {
        let fixture = try ProjectionFixture()
        var successor: ACPV2SessionProjection?
        var triggered = false
        let replace = {
            guard !triggered else { return }
            triggered = true
            fixture.projection.stop()
            // A post-commit append callback leaves an old row, so the successor must reject adoption.
            if boundary == "added" { fixture.session.transcript.replaceMessages(with: []) }
            successor = try? ACPV2SessionProjection(session: fixture.session, upstreamSessionId: "upstream", connectionID: fixture.connection,
                isCurrent: { true })
        }
        let subscription = boundary == "willChange" ? fixture.session.transcript.willChange.observe { replace() }
            : fixture.session.transcript.$messages.signal.observe { _ in if boundary == "valueSignal" { replace() } }
        fixture.session.transcript.onMessageAdded = { _ in if boundary == "added" { replace() } }
        defer { subscription.cancel()
        successor?.stop() }
        #expect(throws: (any Error).self) { try fixture.update(Self.echo) }
        #expect(successor != nil)
        #expect(fixture.session.transcript.messages.isEmpty)
        #expect(fixture.session.v2Projection?.canonical.transcript.messages.isEmpty == true)
    }

    @Test(arguments: ["planOwner", "planValue"])
    func nestedPlanNotificationsCannotOverwriteASuccessor(boundary: String) throws {
        let fixture = try ProjectionFixture()
        var successor: ACPV2SessionProjection?
        var triggered = false
        let replace = {
            guard !triggered else { return }
            triggered = true
            fixture.projection.stop()
            fixture.session.transcript.replaceMessages(with: [])
            successor = try? ACPV2SessionProjection(session: fixture.session, upstreamSessionId: "upstream", connectionID: fixture.connection, isCurrent: { true })
        }
        let subscription = boundary == "planOwner" ? fixture.session.transcript.willChange.observe {
            if fixture.session.transcript.messages.count == 1 && fixture.session.transcript.currentPlan == nil { replace() }
        } : fixture.session.transcript.$currentPlan.signal.observe { value in if value != nil { replace() } }
        defer { subscription.cancel()
        successor?.stop() }
        #expect(throws: (any Error).self) {
            try fixture.update(#"{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[{"content":"old","priority":"high","status":"pending"}]}}"#)
        }
        #expect(successor != nil)
        #expect(fixture.session.transcript.messages.isEmpty)
        #expect(fixture.session.transcript.currentPlan == nil)
        #expect(fixture.session.transcript.currentPlanMessageIndex == nil)
    }

    @Test(arguments: [false, true])
    func projectionStopIsObservableWithoutOverwritingASuccessor(replace: Bool) throws {
        let fixture = try ProjectionFixture()
        try fixture.update(#"{"sessionUpdate":"state_update","state":"running"}"#)
        let newConnection = UUID()
        var events = 0
        var successor: ACPV2SessionProjection?
        let subscription = fixture.session.willChange.observe {
            events += 1
            if replace && events == 1 {
                successor = try? ACPV2SessionProjection(session: fixture.session, upstreamSessionId: "upstream", connectionID: newConnection, isCurrent: { true })
            }
        }
        defer { subscription.cancel()
        successor?.stop() }
        fixture.projection.stop()
        #expect(events > 0)
        if replace {
            #expect(successor != nil)
            #expect(fixture.session.v2Projection?.canonical.context.connectionID == newConnection)
            #expect(fixture.session.v2Projection?.isObserving == true)
        } else {
            #expect(fixture.session.v2Projection?.isObserving == false)
            #expect(fixture.session.v2Projection?.foreground == .unknown)
        }
    }

    @Test func legacyTeardownKeepsOwnershipUntilItsBufferedRowsAreFlushed() async throws {
        let session = ACPSession(id: "local", agentId: "fixture", worktreeId: "w", title: "Legacy")
        session.remoteSessionId = "upstream"
        let transport = ProjectionLegacyTransport()
        let client = ACPStdioClient(transport: transport)
        try client.start()
        let persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("projection-legacy-\(UUID()).sqlite").path)
        let runner = ACPSessionRunner(session: session, connection: .init(client: client), sessionId: "local", worktreePath: "/tmp",
            incomingUpdateCoalesceNanos: 60_000_000_000, persistence: persistence)
        defer { runner.stop()
        Task { await client.shutdown() } }
        runner.start()
        transport.continuation.yield(.frame(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"legacy"}}}}"#.utf8), onConsumed: nil))
        try await eventually { await MainActor.run { runner.pendingIncomingUpdateCountForTesting == 1 } }
        var attempted = false
        var intruder: ACPV2SessionProjection?
        let subscription = session.nextPromptActivity.observe {
            guard !attempted else { return }
            attempted = true
            intruder = try? ACPV2SessionProjection(session: session, upstreamSessionId: "upstream", connectionID: UUID(), isCurrent: { true })
        }
        runner.stop()
        subscription.cancel()
        defer { intruder?.stop() }
        #expect(attempted)
        #expect(intruder == nil)
        #expect(session.transcript.messages.count == 1)
        if case .agent(_, _, let text)? = session.transcript.messages.first { #expect(text.value == "legacy") }
        else { Issue.record("Missing buffered legacy update") }
        if intruder == nil {
            session.transcript.replaceMessages(with: [])
            let successor = try ACPV2SessionProjection(session: session, upstreamSessionId: "upstream", connectionID: UUID(), isCurrent: { true })
            successor.stop()
        }
    }

    @Test func agentResourceLinksCannotPlantASessionLinkOrReportReference() throws {
        let fixture = try ProjectionFixture()
        try fixture.update(#"{"sessionUpdate":"user_message","messageId":"u","content":[{"type":"text","text":"hi"},{"type":"resource_link","uri":"alas-file-change-report://planted","name":"r"},{"type":"resource_link","uri":"\#(ACPSessionReference.uri(sessionId: "secret"))","name":"s"},{"type":"resource_link","uri":"file:///a","name":"a"}]}"#)
        guard case .user(_, _, _, let attachments, _, _) = fixture.session.transcript.messages.first else {
            Issue.record("Missing user row")
            return
        }
        #expect(attachments.map(\.uri) == ["file:///a"])
    }

    @Test func typedProjectionPreservesUnsupportedContentAndTerminalBytes() throws {
        let fixture = try ProjectionFixture()
        try fixture.update(#"{"sessionUpdate":"agent_message","messageId":"m","content":[{"type":"future","n":1e999}]}"#)
        try fixture.update(#"{"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"/wA="}}"#)
        try fixture.update(#"{"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"AQ=="}"#)
        #expect(fixture.session.v2Projection?.canonical.activity.terminal(id: "t")?.output == Data([255, 0, 1]))
        #expect(fixture.session.v2Projection?.canonical.transcript.messages.first?.content == fixture.state.transcript.messages.first?.content)
        #expect(fixture.session.transcript.messages.count == 1)
    }

    @Test func snapshotsCannotPublishLiveCompletionOrFabricateAnInteraction() throws {
        var completions: [ACPSessionLifecycle.ForegroundCompletion] = []
        let fixture = try ProjectionFixture(onChange: { completions += $0.liveCompletions })
        try fixture.update(#"{"sessionUpdate":"state_update","state":"running"}"#, source: .snapshot)
        try fixture.update(#"{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}"#, source: .snapshot)
        #expect(completions.isEmpty)
        try fixture.update(#"{"sessionUpdate":"state_update","state":"requires_action"}"#)
        #expect(fixture.session.v2Projection?.foreground == .requiresAction)
        #expect(fixture.session.transcript.pendingPermission == nil && fixture.session.transcript.pendingQuestion == nil)
        try fixture.update(#"{"sessionUpdate":"state_update","state":"idle","stopReason":"future"}"#)
        #expect(completions.count == 1)
        if case .stopped = completions.first?.result {} else { Issue.record("Unknown stop reason became success") }
        fixture.projection.stop()
        #expect(fixture.session.v2Projection?.foreground == .unknown)
        #expect(completions.count == 1)
    }

    @Test func exclusiveInstallationRejectsLegacyAndUnrelatedDestinations() throws {
        let session = ACPSession(id: "local", agentId: "fixture", worktreeId: "w", title: "V2")
        let legacy = UUID()
        #expect(session.reserveLegacyProjection(epoch: legacy))
        #expect(throws: ACPV2SessionProjection.Failure.invalidDestination) {
            try ACPV2SessionProjection(session: session, upstreamSessionId: "upstream", connectionID: UUID(), isCurrent: { true })
        }
        session.releaseLegacyProjection(epoch: legacy)
        session.transcript.appendMessage(.systemNotice(id: UUID(), text: "unrelated"))
        #expect(throws: ACPV2SessionProjection.Failure.invalidDestination) {
            try ACPV2SessionProjection(session: session, upstreamSessionId: "upstream", connectionID: UUID(), isCurrent: { true })
        }
        #expect(session.transcript.messages.count == 1)
    }

    @Test(arguments: ["context", "revision"])
    func conflictingPublicationWithdrawsTheProjection(reason: String) throws {
        let fixture = try ProjectionFixture()
        let context = ACPV2SessionState.Context(sessionID: "other", connectionID: fixture.connection)
        #expect(throws: (any Error).self) {
            try fixture.projection.apply(.init(revision: reason == "revision" ? 2 : 1, context: reason == "revision" ? fixture.state.context : context,
                change: .observationLost([]), state: fixture.state))
        }
        #expect(fixture.session.v2Projection?.isObserving == false)
    }

    private static let echo = #"{"sessionUpdate":"user_message","messageId":"u","content":[{"type":"text","text":"same"}]}"#
}

@MainActor
private final class ProjectionFixture {
    let session = ACPSession(id: "local", agentId: "fixture", worktreeId: "worktree", title: "Projection")
    let connection = UUID()
    var state: ACPV2SessionState
    let projection: ACPV2SessionProjection
    var revision: UInt64 = 0
    init(optimistic: [ACPMessage] = [], onChange: (@MainActor (ACPV2SessionProjection.Notification) -> Void)? = nil) throws {
        state = .init(context: .init(sessionID: "upstream", connectionID: connection))
        session.transcript.replaceMessages(with: optimistic)
        let ids = Set(optimistic.compactMap { row -> UUID? in if case .user(let id, _, _, _, _, _) = row { return id }
        return nil })
        projection = try .init(session: session, upstreamSessionId: "upstream", connectionID: connection, optimisticRowIDs: ids, isCurrent: { true }, onChange: onChange)
    }
    func update(_ json: String, source: ACPSessionLifecycle.StateSource = .live) throws {
        let raw = Data((#"{"sessionId":"upstream","update":"# + json + "}").utf8)
        let event = try ACPV2SessionUpdateEnvelope.decode(from: raw)
        let result = try state.apply(event, source: source, context: state.context)
        revision += 1
        try projection.apply(.init(revision: revision, context: state.context,
            change: .update(.init(ordinal: Int64(revision), source: source, disposition: result.disposition, effects: result.effects)), state: state))
    }
    func publish(effects: [ACPV2SessionState.Effect]) throws {
        revision += 1
        try projection.apply(.init(revision: revision, context: state.context,
            change: .update(.init(ordinal: Int64(revision), source: .live, disposition: .applied, effects: effects)), state: state))
    }
}

private final class ProjectionLegacyTransport: JSONRPCStdioTransporting, Sendable {
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    init() {
        let pair = AsyncStream<JSONRPCStdioTransport.Incoming>.makeStream()
        incoming = pair.stream
        continuation = pair.continuation
    }
    func start() throws {}
    func send(_ bytes: Data) throws {}
    func terminate() { continuation.finish() }
}
