import Foundation
import Testing
import AlasCore

// Projection and runner APIs require the main actor.
@MainActor
struct ACPV2PreviewOwnerTests {
    @Test(arguments: [false, true])
    func previewRefusesBusyOrWithdrawnSendsWithoutRegistering(withdraw: Bool) async throws {
        let fixture = try await PreviewOwnerFixture()
        defer { fixture.owner.withdraw()
        Task { await fixture.client.detach() } }
        try await fixture.start()
        _ = try await fixture.owner.send(text: "first")
        let rows = fixture.session.transcript.messages.count
        let requests = await fixture.service.sentRequests.count
        if withdraw { fixture.owner.withdraw() }
        await #expect(throws: (any Error).self) { try await fixture.owner.send(text: "second") }
        #expect(fixture.session.transcript.messages.count == rows)
        #expect(await fixture.service.sentRequests.count == requests)
        #expect(fixture.owner.lastCompletion == nil)
    }

    @Test(arguments: ["completed", "failed", "lost"])
    func previewDoesNotCompleteOnPromptAcceptance(result: String) async throws {
        let fixture = try await PreviewOwnerFixture()
        defer { fixture.owner.withdraw()
        Task { await fixture.client.detach() } }
        try await fixture.start()
        _ = try await fixture.owner.send(text: "one")
        #expect(fixture.owner.lastCompletion == nil)
        await fixture.service.publishPreviewState(#"{"sessionUpdate":"state_update","state":"running"}"#)
        try await fixture.client.replayRawBrokerEvents()
        try await eventually { await MainActor.run { fixture.owner.foreground == .running } }
        if result == "lost" {
            await fixture.client.detach()
            try await eventually { await MainActor.run { fixture.owner.status == .interrupted } }
            #expect(fixture.owner.lastCompletion == nil)
        } else {
            await fixture.service.publishPreviewState(result == "completed"
                ? #"{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}"#
                : #"{"sessionUpdate":"state_update","state":"idle","stopReason":"error","error":{"code":-1,"message":"fixture"}}"#)
            try await fixture.client.replayRawBrokerEvents()
            try await eventually { await MainActor.run { fixture.owner.lastCompletion != nil } }
            if result == "completed" { #expect(fixture.owner.lastCompletion?.result == .completed) }
            else {
                #expect(fixture.owner.lastCompletion?.result != .completed)
                #expect(fixture.session.lastError == "fixture")
                await fixture.owner.flushDisplay()
                #expect(try await fixture.persistence.loadV2PreviewDisplay(sessionId: "s")?.failureMessage == "fixture")
            }
        }
    }

    @Test func withdrawalPreventsHeldDisplayAndReplyWorkFromRestoringAuthority() async throws {
        let gate = PreviewDisplayGate()
        let fixture = try await PreviewOwnerFixture(displayGate: gate)
        defer { fixture.owner.withdraw()
        Task { await fixture.client.detach() } }
        try await fixture.start()
        await gate.waitForEntry()
        fixture.owner.withdraw()
        await fixture.owner.flushDisplay()
        let terminal = try await fixture.persistence.loadV2PreviewDisplay(sessionId: "s")
        #expect(terminal?.status == .interrupted)
        await gate.release()
        try await eventually { await gate.authorizationAtRelease != nil }
        #expect(await gate.authorizationAtRelease == false)
        #expect(try await fixture.persistence.loadV2PreviewDisplay(sessionId: "s") == terminal)
        #expect(fixture.owner.presentation.canSend == false)
    }

    @Test(arguments: ["missing", "bypassPermissions"])
    func previewRefusesAnUnqualifiedLaunchModeBeforeOpening(mode: String) async throws {
        let fixture = try await PreviewOwnerFixture(launchMode: mode == "missing" ? nil : mode)
        defer { fixture.owner.withdraw()
        Task { await fixture.client.detach() } }
        await #expect(throws: (any Error).self) { try await fixture.start() }
        #expect(await fixture.service.openCount == 0)
    }

    @Test(arguments: ["default", "bypassPermissions", "unknown-shape"])
    func previewConfiguresOnlyTheQualifiedClaudeMode(mode: String) async throws {
        let fixture = try await PreviewOwnerFixture(agent: "claude")
        defer { fixture.owner.withdraw()
        Task { await fixture.client.detach() } }
        await fixture.service.setPreviewModeResponse("{\"configOptions\":[{\"configId\":\"mode\",\"type\":\"\(mode == "unknown-shape" ? "future" : "select")\",\"currentValue\":\"\(mode == "unknown-shape" ? "default" : mode)\",\"options\":[{\"value\":\"default\",\"name\":\"Default\"}]}]}")
        if mode == "default" {
            try await fixture.start()
            #expect(fixture.owner.status == .ready)
        } else {
            await #expect(throws: (any Error).self) { try await fixture.start() }
            #expect(fixture.owner.presentation.canSend == false)
        }
        #expect(await fixture.service.sentRequests.filter { $0.method == "session/set_config_option" }.count == 1)
    }

    @Test func failedPreviewStartupCanStillCloseItsFreshSource() async throws {
        let fixture = try await PreviewOwnerFixture(agent: "claude")
        await fixture.service.setPreviewModeResponse("{\"configOptions\":[]}")
        await #expect(throws: (any Error).self) { try await fixture.start() }
        #expect(fixture.owner.presentation.canEnd)
        #expect(!fixture.owner.presentation.canSend)
        await fixture.client.detach()
        try await fixture.owner.end()
        try await fixture.owner.end()
        #expect(await fixture.service.closeCount == 1)
        #expect(!fixture.owner.presentation.canEnd)
    }

    @Test func permissionButtonsLoseAuthorityBeforeAwaitingTheReply() async throws {
        let fixture = try await PreviewOwnerFixture()
        defer { fixture.owner.withdraw()
        Task { await fixture.service.releaseReply()
        await fixture.client.detach() } }
        try await fixture.start()
        _ = try await fixture.permission()
        let item = try #require(fixture.owner.permissions.first)
        await fixture.service.holdReply()
        let first = Task { try await fixture.owner.decide(itemID: item.id, optionID: "allow") }
        try await eventually { await fixture.service.exactReplies.count == 1 }
        #expect(fixture.owner.permissions.first?.phase == .sending)
        await #expect(throws: (any Error).self) { try await fixture.owner.decide(itemID: item.id, optionID: "allow") }
        let store = try ACPSessionStore(path: fixture.persistence.path)
        #expect(try store.db.query("SELECT id FROM acp_v2_response_attempts").count == 1)
        await fixture.service.releaseReply()
        _ = try await first.value
        #expect(await fixture.service.exactReplies.count == 1)
        #expect(fixture.owner.permissions.first?.phase == .unavailable)
    }

    @Test func retiredPermissionCannotAnswerAReusedWireID() async throws {
        let fixture = try await PreviewOwnerFixture()
        defer { fixture.owner.withdraw()
        Task { await fixture.service.releaseReply()
        await fixture.client.detach() } }
        try await fixture.start()
        _ = try await fixture.permission()
        let old = try #require(fixture.owner.permissions.first)
        await fixture.service.holdReply()
        let sending = Task { try await fixture.owner.decide(itemID: old.id, optionID: "allow") }
        try await eventually { await fixture.service.exactReplies.count == 1 }
        _ = try await fixture.permission(cursor: 6)
        try await eventually { await MainActor.run { fixture.owner.permissions.filter { $0.phase == .awaitingDecision }.count == 1 } }
        let current = try #require(fixture.owner.permissions.first { $0.phase == .awaitingDecision })
        #expect(current.id != old.id && current.ledgerOrdinal > old.ledgerOrdinal)
        await #expect(throws: (any Error).self) { try await fixture.owner.decide(itemID: old.id, optionID: "allow") }
        #expect(await fixture.service.exactReplies.count == 1)
        await fixture.service.releaseReply()
        _ = try? await sending.value
        _ = try await fixture.owner.decide(itemID: current.id, optionID: "allow")
        #expect(await fixture.service.exactReplies.map { $0.originCursor.rawValue } == [5, 6])
    }

    @Test(arguments: [false, true])
    func leaseLossAndRemoteCancellationRetireOnlyCurrentItems(loseLease: Bool) async throws {
        let fixture = try await PreviewOwnerFixture()
        defer { fixture.owner.withdraw()
        Task { await fixture.client.detach() } }
        try await fixture.start()
        let first = try await fixture.permission()
        _ = try await fixture.permission(wire: "q", cursor: 6, retaining: [first])
        let before = fixture.owner.permissions
        #expect(before.count == 2 && before[0].ledgerOrdinal < before[1].ledgerOrdinal)
        if loseLease {
            _ = try await fixture.persistence.seizeLease(sessionId: "s", instanceId: "Other", pid: 2, now: 2, leaseToken: "other")
            fixture.owner.withdraw()
            #expect(fixture.owner.permissions.allSatisfy { $0.phase == .unavailable })
        } else {
            await fixture.service.publishControl(Data(#"{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"p"}}"#.utf8), cursor: 7)
            try await fixture.client.replayRawBrokerEvents()
            try await eventually { await MainActor.run { fixture.owner.permissions.first?.phase == .unavailable } }
            #expect(fixture.owner.permissions.last?.phase == .awaitingDecision)
        }
        await #expect(throws: (any Error).self) { try await fixture.owner.decide(itemID: before[0].id, optionID: "allow") }
        if loseLease { #expect(await fixture.service.exactReplies.isEmpty) }
        else { _ = try await fixture.owner.decide(itemID: before[1].id, optionID: nil) }
    }

    @Test(arguments: ["future/request", "elicitation/create"])
    func unknownOrUnadvertisedRequestsNeverBecomePermissionOffers(method: String) async throws {
        let fixture = try await PreviewOwnerFixture()
        defer { fixture.owner.withdraw()
        Task { await fixture.client.detach() } }
        try await fixture.start()
        _ = try await fixture.permission(method: method)
        try await eventually { await fixture.service.exactReplies.count == 1 }
        #expect(fixture.owner.permissions.isEmpty)
        #expect(fixture.session.transcript.pendingPermission == nil)
    }

    @Test(arguments: ["fresh", "adopted", "foreign", "generation", "lease", "deadline-fresh", "deadline-adopted"])
    func endingLateStartupClosesOnlyItsFreshSource(source: String) async throws {
        let fixture = try await PreviewOwnerFixture(delayed: true, adopted: source.contains("adopted"))
        if source == "foreign" { await fixture.service.setLocalSessionID("foreign") }
        let starting = Task { try await fixture.start() }
        try await eventually { await fixture.service.openCount == 1 }
        if source == "generation" { await fixture.service.holdNextAttach() }
        let ending = Task { try await fixture.owner.end(deadline: .now.advanced(by: .seconds(source.hasPrefix("deadline") ? 1 : 15))) }
        try await eventually { await MainActor.run { fixture.owner.status == .ending } }
        if source == "lease" {
            _ = try await fixture.persistence.seizeLease(sessionId: "s", instanceId: "Other", pid: 2, now: 2, leaseToken: "other")
        }
        if source.hasPrefix("deadline") {
            _ = try? await ending.value
            #expect(fixture.owner.status == .interrupted)
        }
        await fixture.service.releaseOpen()
        if source == "generation" {
            await fixture.service.waitForHeldAttach()
            await fixture.service.changeGeneration()
            await fixture.service.releaseHeldAttach()
        }
        _ = try? await starting.value
        _ = try? await ending.value
        _ = try? await fixture.owner.end()
        #expect(await fixture.service.closeCount == (source == "fresh" || source == "deadline-fresh" ? 1 : 0))
        #expect(await fixture.service.closedGenerations.count <= 1)
        #expect(await fixture.service.sentRequests.allSatisfy { $0.method != "session/cancel" })
    }
}

@MainActor
private final class PreviewOwnerFixture {
    let service: RawBrokerFixture
    let client: ACPBrokerClient
    let session: ACPSession
    let persistence: ACPSessionPersistence
    let owner: ACPV2PreviewOwner

    init(delayed: Bool = false, adopted: Bool = false, agent: String = "codex", launchMode: String? = "read-only", displayGate: PreviewDisplayGate? = nil) async throws {
        service = RawBrokerFixture(delayOpen: delayed, acceptedMessageID: "u", holdRPCsAcrossCancellation: true)
        if !adopted { await service.setFreshBootstrapWithoutTraffic() }
        client = ACPBrokerClient(service: service, brokerId: .init(rawValue: "raw"), sessionId: "s", command: "fixture",
            args: [], cwd: "/tmp", env: launchMode.map { ["INITIAL_AGENT_MODE": $0] } ?? [:], operationKeyPrefix: "preview", wireContext: .rawV2)
        persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("preview-owner-\(UUID()).sqlite").path)
        let fence = try await persistence.createV2PreviewSession(row: .init(id: "s", agentId: agent, title: "Preview", autoRun: false,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false), ownerInstance: "A", pid: 1, now: 1, leaseToken: "owner")
        session = ACPSession(id: "s", agentId: agent, worktreeId: "w", title: "Preview", runtimeKind: .v2FreshPreview)
        let storage = persistence
        let writer: ACPV2PreviewOwner.DisplayWriter?
        if let gate = displayGate {
            writer = { snapshot, fence, authorize in
                try await gate.write(snapshot, fence: fence, persistence: storage, authorize: authorize)
            }
        } else { writer = nil }
        // This suite exercises the owner after admission. Real launch identity
        // admission is covered by the eligibility and manager suites.
        let qualification = ACPV2PreviewQualifiedAdapter(agentID: agent, packageName: "fixture", packageVersion: "test",
            packageDigest: "fixture", helperDigest: "fixture",
            providerID: agent == "claude" ? "anthropic-claude-ai" : "openai-chatgpt",
            approvalMode: agent == "claude" ? "default" : "read-only", nodeDigest: "fixture", nodeVersion: "fixture",
            sourceRepository: "fixture", sourceCommit: "fixture", packageIntegrity: "fixture",
            supportedCapabilities: ["freshSessionV2", "textPrompt", "permissionAllowOnce", "permissionCancel"])
        owner = ACPV2PreviewOwner(session: session, client: client, persistence: persistence, fence: fence,
            qualification: qualification,
            installationID: UUID(), isCurrent: { true }, onChange: {}, displayWriter: writer)
    }
    @discardableResult
    func permission(wire: String = "p", cursor: UInt64 = 5, method: String = "session/request_permission",
        retaining: [ACPBrokerPendingRequest] = []) async throws -> ACPBrokerPendingRequest {
        var pending = ACPBrokerPendingRequest(requestId: wire, adapterRequestId: .string(wire), kind: .permission, payload: .null)
        pending.rawFrame = .init(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(wire)\",\"method\":\"\(method)\",\"params\":{\"sessionId\":\"upstream\",\"title\":\"Choose\",\"options\":[{\"optionId\":\"allow\",\"name\":\"Allow once\",\"kind\":\"allow_once\"}]}}".utf8))
        pending.originCursor = .init(rawValue: cursor)
        await service.publishPendingSuccessor(pending, retaining: retaining)
        try await client.replayRawBrokerEvents()
        if method == "session/request_permission" {
            try await eventually { await MainActor.run { self.owner.permissions.filter { $0.phase == .awaitingDecision }.count >= retaining.count + 1 } }
        }
        return pending
    }

    func start() async throws {
        try await owner.start(params: .init(cwd: "/tmp", mcpServers: []), deadline: .now.advanced(by: .seconds(60)))
    }
}

private actor PreviewDisplayGate {
    private var captured = false
    private let entry = AsyncStream<Void>.makeStream()
    private let resumed = AsyncStream<Void>.makeStream()
    var authorizationAtRelease: Bool?
    func waitForEntry() async { var events = entry.stream.makeAsyncIterator()
    _ = await events.next() }
    func release() { resumed.continuation.yield(()) }
    func write(_ snapshot: ACPV2PreviewDisplaySnapshot, fence: ACPSessionLeaseFence, persistence: ACPSessionPersistence,
        authorize: @escaping @Sendable () -> Bool) async throws -> Bool {
        if !captured {
            captured = true
            entry.continuation.yield(())
            var events = resumed.stream.makeAsyncIterator()
            _ = await events.next()
            authorizationAtRelease = authorize()
        }
        return try await persistence.persistV2PreviewDisplay(snapshot, fence: fence, authorize: authorize)
    }
}
