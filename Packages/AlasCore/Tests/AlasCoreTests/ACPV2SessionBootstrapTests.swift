import Foundation
import Synchronization
import Testing
import AlasCore
@testable import AlasSessions
@testable import AlasFoundation

@MainActor
struct ACPV2SessionBootstrapTests {
    @Test func runtimeInstallationHookRunsBeforeStartupAndCanWithdrawIt() async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        var installed = false
        var inbound = 0
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence, persistence: persistence,
            deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { _ in },
            onInbound: { _ in inbound += 1 }, onRuntimeCreated: { runtime in #expect(runtime.status == .idle)
            installed = true
            runtime.stop() })
        defer { bootstrap.stop()
        transport.terminate() }
        _ = try await bootstrap.initialize()
        await #expect(throws: (any Error).self) { try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        #expect(installed && inbound == 0)
    }

    @Test func setupAndReplayPopulateProjectionWithoutLiveCompletion() async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let session = ACPSession(id: "local", agentId: "fixture", worktreeId: "w", title: "Projection")
        var ended = 0
        var defaults = 0
        let projection = try ACPV2SessionProjection(session: session, upstreamSessionId: "upstream", connectionID: client.updateConnectionID,
            isCurrent: { true }, onChange: { notification in
                ended += notification.liveCompletions.count
                if case .setupDefault = notification.publication.change { defaults += 1 }
            })
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { _ in }, onCanonicalChange: projection.apply)
        defer { projection.stop()
        bootstrap.stop()
        transport.terminate() }
        _ = try await bootstrap.initialize()
        let installed = try await bootstrap.createSession(.init(cwd: "/w", mcpServers: []))
        #expect(defaults == 1 && ended == 0)
        #expect(session.v2Projection?.foreground == .idle)
        #expect(installed.runtime.state.lifecycle.lastForegroundCompletion == nil)
    }

    @Test func freshSetupKeepsRawEvidenceAndRequiresAdvertisedSessionMethods() throws {
        let bytes = Data(#" {"sessionId":"upstream","configOptions":[{"type":"future","n":1e999}],"availableCommands":[],"future":true} "#.utf8)
        let result = try ACPV2SessionNewResult.decode(bytes)
        #expect(result.sessionId == "upstream" && result.rawBytes == bytes)
        for raw in [#"{}"#, #"{"sessionId":null}"#, #"{"sessionId":""}"#, #"{"sessionId":1}"#] {
            #expect(throws: (any Error).self) { try ACPV2SessionNewResult.decode(Data(raw.utf8)) }
        }
        let params = ACPV2SessionNewParams(cwd: "/workspace", mcpServers: [])
        for marker in ["null", "true", "{}"] {
            let initialization = try JSONDecoder().decode(ACPV2InitializeResult.self,
                from: Data("{\"protocolVersion\":2,\"info\":{\"name\":\"agent\",\"version\":\"1\"},\"capabilities\":{\"session\":\(marker)}}".utf8))
            if marker == "{}" { try params.validate(capabilities: initialization) }
            else { #expect(throws: (any Error).self) { try params.validate(capabilities: initialization) } }
        }
    }

    @Test(arguments: ["ok", "lease", "bound", "sql", "lease-owner-bytes", "lease-token-bytes"])
    func freshBindingCommitsUnderTheLeaseWithoutOverwritingHistory(reason: String) async throws {
        let persistence = try await Self.persistence()
        let fence = reason == "lease-owner-bytes" ? ACPSessionLeaseFence(sessionId: "local", ownerInstance: "e\u{301}", token: "owner")
            : (reason == "lease-token-bytes" ? ACPSessionLeaseFence(sessionId: "local", ownerInstance: "A", token: "e\u{301}") : Self.fence)
        let store = try ACPSessionStore(path: persistence.path)
        if reason == "lease" { _ = try await persistence.seizeLease(sessionId: "local", instanceId: "B", pid: 2, now: 2, leaseToken: "new") }
        if reason == "lease-owner-bytes" { _ = try await persistence.seizeLease(sessionId: "local", instanceId: "é", pid: 2, now: 2, leaseToken: "owner") }
        if reason == "lease-token-bytes" { _ = try await persistence.seizeLease(sessionId: "local", instanceId: "A", pid: 2, now: 2, leaseToken: "é") }
        if reason == "bound" { try store.db.exec("UPDATE sessions SET remote_session_id='existing'") }
        if reason == "sql" { try store.db.exec("CREATE TRIGGER fail_binding AFTER UPDATE ON sessions BEGIN SELECT RAISE(ABORT,'injected'); END") }
        if reason == "ok" {
            let receipt = try await persistence.bindV2FreshSession(upstreamSessionId: "upstream", source: .stdio(connectionID: UUID()), fence: fence)
            #expect(receipt.upstreamSessionId == "upstream")
            #expect(try ACPSessionStore(path: persistence.path).loadSession(id: "local")?.remoteSessionId == "upstream")
            await #expect(throws: (any Error).self) { try await persistence.bindV2FreshSession(upstreamSessionId: "other", source: receipt.source, fence: fence) }
        } else {
            await #expect(throws: (any Error).self) { try await persistence.bindV2FreshSession(upstreamSessionId: "upstream", source: .stdio(connectionID: UUID()), fence: fence) }
            #expect(try store.loadSession(id: "local")?.remoteSessionId == (reason == "bound" ? "existing" : nil))
        }
    }

    @Test func bootstrapClaimsAreConcreteSingleUseAndProtectTheActualHandoff() async throws {
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        defer { transport.terminate() }
        let claim = try client.claimV2Bootstrap()
        #expect(throws: (any Error).self) { try client.claimV2Bootstrap() }
        func request() -> ACPV2BootstrapRequest { .initialize(.init(info: .init(name: "alas", version: "test"))) }
        await #expect(throws: (any Error).self) { try await client.send(.init(method: "initialize")) }
        let other = ACPStdioClient(transport: BootstrapTransport(), sessionUpdateProtocolVersion: .v2)
        await #expect(throws: (any Error).self) { try await other.sendV2Bootstrap(request(), claim: claim, authorize: { true }) }
        _ = try await client.sendV2Bootstrap(request(), claim: claim, authorize: { true })
        await #expect(throws: (any Error).self) { try await client.sendV2Bootstrap(request(), claim: claim, authorize: { true }) }
        await #expect(throws: (any Error).self) {
            try await client.sendV2Bootstrap(.newSession(.init(cwd: "/w", mcpServers: [])), claim: claim, authorize: { claim.invalidate()
            return true })
        }
        #expect(transport.frames.withLock { $0.count } == 1)
    }

    @Test func anEarlierSetupSendCannotBeAdoptedByABootstrap() async throws {
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        defer { transport.terminate() }
        _ = try await client.send(.init(method: "initialize", params: ACPV2InitializeParams(info: .init(name: "alas", version: "test"))))
        #expect(throws: (any Error).self) { try client.claimV2Bootstrap() }
        #expect(transport.frames.withLock { $0.count } == 1)
    }
    @Test func setupCommitsBeforeAcknowledgmentAndInstallsOriginalQueuedCaptures() async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let consumed = BootstrapCount()
        let path = persistence.path
        transport.onSend.withLock { $0 = { method, id, io in
            if method == "initialize" { io.reply(id, result: BootstrapTransport.initialization)
            return }
            io.emit(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"state_update","state":"running"}}}"#)
            io.emit(#"{"jsonrpc":"2.0","id":7,"method":"peer/request"}"#, onConsumed: { consumed.value.withLock { $0 += 1 } })
            io.reply(id, result: #"{"sessionId":"upstream","configOptions":[{"future":true}]}"#, onConsumed: {
                #expect((try? ACPSessionStore(path: path).loadSession(id: "local")?.remoteSessionId) == "upstream")
                consumed.value.withLock { $0 += 1 }
            })
        } }
        var offers: [ACPV2AttachmentRuntime.Request] = []
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { offers.append($0) })
        defer { bootstrap.stop()
        transport.terminate() }
        let initialized = try await bootstrap.initialize()
        #expect(initialized.response.rawDelivery != nil)
        let installed = try await bootstrap.createSession(.init(cwd: "/workspace", mcpServers: []))
        #expect(installed.result.sessionId == "upstream" && installed.runtime.status == .ready)
        try await eventually { await MainActor.run { offers.count == 1 } }
        #expect(installed.runtime.state.lifecycle.lastForegroundCompletion == nil)
        try await eventually { await MainActor.run { installed.runtime.state.latestStateObservation?.event.sessionID == "upstream" } }
        let offer = try #require(offers.first)
        #expect(try await installed.runtime.respond(to: offer, intentID: UUID(), attemptID: UUID(), operationKey: .init(rawValue: "answer"), frame: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)).value.fact == .stdio(.written))
        try await eventually { consumed.value.withLock { $0 } == 2 }
        await #expect(throws: (any Error).self) { try await bootstrap.createSession(.init(cwd: "/workspace", mcpServers: [])) }
        #expect(transport.frames.withLock { $0.count } == 3)
    }

    @Test(arguments: ["v1", "malformed", "future"])
    func initializationCannotFallBackOrDispatchSessionWorkImplicitly(result: String) async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        transport.onSend.withLock { $0 = { _, id, io in
            io.reply(id, result: result == "v1" ? #"{"protocolVersion":1}"# : (result == "malformed" ? "{}" : #"{"protocolVersion":3}"#))
        } }
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { _ in })
        defer { bootstrap.stop()
        transport.terminate() }
        if result == "v1" {
            _ = try await bootstrap.initialize()
            #expect(bootstrap.status == .replacementRequired)
        } else { await #expect(throws: (any Error).self) { try await bootstrap.initialize() } }
        #expect(bootstrap.initializationResponse?.rawDelivery != nil)
        await #expect(throws: (any Error).self) { try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        await #expect(throws: (any Error).self) { try await bootstrap.initialize() }
        #expect(transport.frames.withLock { $0.count } == 1)
    }

    @Test(arguments: ["stop", "cancel", "deadline"])
    func lostSetupAuthoritySettlesBlockedCallersWithoutAnotherDispatch(loss: String) async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let deadline = BootstrapDeadlineGate()
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), waitUntilDeadline: { await deadline.wait() },
            isCurrent: { true }, onRequest: { _ in })
        defer { bootstrap.stop()
        transport.terminate()
        Task { await deadline.release() } }
        _ = try await bootstrap.initialize()
        transport.onSend.withLock { $0 = { _, _, _ in } }
        let finished = BootstrapCount()
        let sending = Task { defer { finished.value.withLock { $0 += 1 } }
        return try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        defer { sending.cancel() }
        try await eventually { transport.frames.withLock { $0.count } == 2 }
        if loss == "cancel" { sending.cancel() }
        else if loss == "deadline" { await deadline.release() }
        else { bootstrap.stop() }
        try await eventually { finished.value.withLock { $0 } == 1 }
        await #expect(throws: (any Error).self) { try await sending.value }
        transport.reply(2, result: #"{"sessionId":"late"}"#)
        #expect(try await persistence.loadSession(id: "local")?.remoteSessionId == nil)
        await #expect(throws: (any Error).self) { try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        #expect(transport.frames.withLock { $0.count } == 2)
    }
    @Test(arguments: ["malformed", "lease", "sql"])
    func unusableSetupCannotConsumeItsResponseOrInstallARuntime(reason: String) async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let consumed = BootstrapCount()
        let path = persistence.path
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { _ in Issue.record("Offered before setup") })
        defer { bootstrap.stop()
        transport.terminate() }
        _ = try await bootstrap.initialize()
        transport.onSend.withLock { $0 = { _, id, io in
            let store = try ACPSessionStore(path: path)
            if reason == "lease" { _ = try store.seizeLease(sessionId: "local", instanceId: "B", pid: 2, now: 2, leaseToken: "new") }
            if reason == "sql" { try store.db.exec("CREATE TRIGGER fail_setup AFTER UPDATE ON sessions BEGIN SELECT RAISE(ABORT,'injected'); END") }
            io.reply(id, result: reason == "malformed" ? #"{"sessionId":false}"# : #"{"sessionId":"upstream"}"#, onConsumed: { consumed.value.withLock { $0 += 1 } })
        } }
        await #expect(throws: (any Error).self) { try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        #expect(bootstrap.runtime == nil && consumed.value.withLock { $0 } == 0)
        #expect(bootstrap.setupResponse?.rawDelivery != nil)
        #expect(try await persistence.loadSession(id: "local")?.remoteSessionId == nil)
    }

    @Test(arguments: ["binding", "restoration"])
    func stopDuringInstallationCannotPublishOrAcknowledgeLateSuccess(phase: String) async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let binding = BootstrapBindingGate(base: persistence)
        let updates = RuntimeUpdateGate(base: persistence, operation: .replay)
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), bindingJournal: phase == "binding" ? binding : nil,
            journals: .init(persistence: persistence, updates: phase == "restoration" ? updates : nil), isCurrent: { true }, onRequest: { _ in })
        defer { bootstrap.stop()
        transport.terminate()
        Task { await binding.release()
        await updates.release() } }
        _ = try await bootstrap.initialize()
        let count = BootstrapCount()
        let sending = Task { defer { count.value.withLock { $0 += 1 } }
        return try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        defer { sending.cancel() }
        if phase == "binding" { try await eventually { await binding.entered } }
        else { try await eventually { await updates.entered } }
        bootstrap.stop()
        try await eventually { count.value.withLock { $0 } == 1 }
        await #expect(throws: (any Error).self) { try await sending.value }
        await binding.release()
        await updates.release()
        #expect(bootstrap.status == .stopped)
        #expect(bootstrap.runtime?.status != .ready)
        #expect(try await persistence.loadSession(id: "local")?.remoteSessionId == "upstream")
        #expect(transport.frames.withLock { $0.count } == 2)
    }
    @Test func aFreshSessionDefaultsToIdleWithoutInventingCompletion() async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { _ in })
        defer { bootstrap.stop()
        transport.terminate() }
        _ = try await bootstrap.initialize()
        let installed = try await bootstrap.createSession(.init(cwd: "/w", mcpServers: []))
        #expect(installed.runtime.state.lifecycle.foreground == .idle)
        #expect(installed.runtime.state.lifecycle.lastForegroundCompletion == nil)
    }

    @Test func cancellationInsideAnEarlyOfferWithdrawsReceiptConsumptionSynchronously() async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let consumed = BootstrapCount(), finished = BootstrapCount()
        let updates = RuntimeUpdateGate(base: persistence, operation: .replay)
        var sending: Task<ACPV2SessionBootstrap.Installed, Error>?
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), journals: .init(persistence: persistence, updates: updates),
            isCurrent: { true }, onRequest: { _ in sending?.cancel() })
        defer { bootstrap.stop()
        transport.terminate()
        sending?.cancel()
        Task { await updates.release() } }
        _ = try await bootstrap.initialize()
        transport.onSend.withLock { $0 = { _, id, io in
            io.emit(#"{"jsonrpc":"2.0","id":7,"method":"peer/request"}"#, onConsumed: { consumed.value.withLock { $0 += 1 } })
            io.reply(id, result: #"{"sessionId":"upstream"}"#)
        } }
        sending = Task { defer { finished.value.withLock { $0 += 1 } }
        return try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        try await eventually { finished.value.withLock { $0 } == 1 }
        await #expect(throws: (any Error).self) { try await #require(sending).value }
        #expect(consumed.value.withLock { $0 } == 0)
    }

    @Test func installedRuntimeObservationLossWithdrawsTheBootstrapStatus() async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { _ in })
        defer { bootstrap.stop()
        transport.terminate() }
        _ = try await bootstrap.initialize()
        _ = try await bootstrap.createSession(.init(cwd: "/w", mcpServers: []))
        transport.terminate()
        try await eventually { await MainActor.run { bootstrap.status != .ready } }
        #expect(bootstrap.runtime?.status == .observationLost)
    }

    @Test(arguments: ["/workspace", "C:\\workspace", "C:/workspace", "relative", "C:relative"])
    func freshSetupRecognizesNativeAbsoluteWorkspacePaths(cwd: String) throws {
        let initialized = try JSONDecoder().decode(ACPV2InitializeResult.self, from: Data(BootstrapTransport.initialization.utf8))
        let params = ACPV2SessionNewParams(cwd: cwd, mcpServers: [])
        if cwd == "relative" || cwd == "C:relative" { #expect(throws: (any Error).self) { try params.validate(capabilities: initialized) } }
        else { try params.validate(capabilities: initialized) }
    }

    @Test(arguments: ["initialize", "create", "final-ready-check"])
    func authorityChecksCannotLeaveAnActivePhaseOrPublishLateSuccess(phase: String) async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        var onCurrent: (() -> Void)?
        var sending: Task<Void, Error>?
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { onCurrent?()
            return true }, onRequest: { _ in })
        defer { bootstrap.stop()
        transport.terminate()
        sending?.cancel() }
        if phase != "initialize" { _ = try await bootstrap.initialize() }
        onCurrent = {
            if phase == "final-ready-check" {
                if bootstrap.status == .ready { bootstrap.runtime?.stop() }
            } else { sending?.cancel() }
        }
        sending = Task {
            if phase == "initialize" { _ = try await bootstrap.initialize() }
            else { _ = try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        }
        await #expect(throws: (any Error).self) { try await #require(sending).value }
        #expect(bootstrap.status != .initializing && bootstrap.status != .creating)
        #expect(transport.frames.withLock { $0.count } == (phase == "initialize" ? 0 : (phase == "create" ? 1 : 2)))
    }

    @Test func aCommitInAnotherDatabaseCannotAuthorizeSetupConsumption() async throws {
        let intended = try await Self.persistence(), other = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let consumed = BootstrapCount()
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: intended, deadline: .now.advanced(by: .seconds(60)), bindingJournal: other,
            isCurrent: { true }, onRequest: { _ in })
        defer { bootstrap.stop()
        transport.terminate() }
        _ = try await bootstrap.initialize()
        transport.onSend.withLock { $0 = { _, id, io in io.reply(id, result: #"{"sessionId":"upstream"}"#, onConsumed: { consumed.value.withLock { $0 += 1 } }) } }
        await #expect(throws: (any Error).self) { try await bootstrap.createSession(.init(cwd: "/w", mcpServers: [])) }
        #expect(consumed.value.withLock { $0 } == 0 && bootstrap.runtime == nil)
        #expect(try await intended.loadSession(id: "local")?.remoteSessionId == nil)
        #expect(try await other.loadSession(id: "local")?.remoteSessionId == "upstream")
    }

    @Test(arguments: ["", "relative-tool", "/usr/bin/tool", "C:/bin/tool"])
    func invalidMCPExecutablesAreCorrectableBeforeTheSetupAttempt(command: String) async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        transport.onSend.withLock { $0 = { _, id, io in
            io.reply(id, result: #"{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"mcp":{"stdio":{}}}}}"#)
        } }
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { _ in })
        defer { bootstrap.stop()
        transport.terminate() }
        _ = try await bootstrap.initialize()
        transport.onSend.withLock { $0 = nil }
        let params = ACPV2SessionNewParams(cwd: "/w", mcpServers: [.stdio(name: "tools", command: command, args: [], env: [])])
        if command.isEmpty || command == "relative-tool" {
            await #expect(throws: ACPV2SessionSetupError.invalidInput) { try await bootstrap.createSession(params) }
            #expect(bootstrap.status == .initialized && transport.frames.withLock { $0.count } == 1)
            _ = try await bootstrap.createSession(.init(cwd: "/w", mcpServers: []))
        } else { _ = try await bootstrap.createSession(params) }
        #expect(bootstrap.status == .ready)
    }

    @Test func cancelledBootstrapCannotWriteAfterWaitingBehindAnotherSerializedFrame() async throws {
        let persistence = try await Self.persistence()
        let transport = BootstrapSerializedTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let first = Task { await transport.writeFrame(BootstrapSerializedTransport.blocker, authorize: { true }) }
        defer { transport.release.signal()
        transport.terminate() }
        try await eventually { transport.blocked.withLock { $0 } }
        let bootstrap = try ACPV2SessionBootstrap(attachment: .init(stdioClient: client), fence: Self.fence,
            persistence: persistence, deadline: .now.advanced(by: .seconds(60)), isCurrent: { true }, onRequest: { _ in })
        defer { bootstrap.stop() }
        let finished = BootstrapCount()
        let sending = Task { defer { finished.value.withLock { $0 += 1 } }
        return try await bootstrap.initialize() }
        defer { sending.cancel() }
        try await eventually { transport.attempted.withLock { $0 } }
        sending.cancel()
        try await eventually { finished.value.withLock { $0 } == 1 }
        await #expect(throws: (any Error).self) { try await sending.value }
        transport.release.signal()
        #expect(await first.value == .written)
        try await eventually { transport.settled.withLock { $0 } }
        #expect(transport.bytes.withLock { $0 } == [BootstrapSerializedTransport.blocker])
    }

    static let fence = ACPSessionLeaseFence(sessionId: "local", ownerInstance: "A", token: "owner")
    static func persistence() async throws -> ACPSessionPersistence {
        let persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-\(UUID()).sqlite").path)
        try await persistence.upsertSession(.init(id: "local", agentId: "fixture", title: "Bootstrap", autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        _ = try await persistence.seizeLease(sessionId: "local", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        return persistence
    }
}

final class BootstrapTransport: JSONRPCStdioTransporting, JSONRPCFrameWriting, Sendable {
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let frames = Mutex<[Data]>([])
    let onSend = Mutex<(@Sendable (String, Int, BootstrapTransport) throws -> Void)?>(nil)
    init() {
        let input = AsyncStream<JSONRPCStdioTransport.Incoming>.makeStream()
        incoming = input.stream
        continuation = input.continuation
    }
    func start() throws {}
    func send(_ bytes: Data) throws {
        frames.withLock { $0.append(bytes) }
        let fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let method = try #require(fields["method"] as? String), id = try #require(fields["id"] as? Int)
        if let hook = onSend.withLock({ $0 }) { try hook(method, id, self)
        return }
        reply(id, result: method == "initialize" ? Self.initialization : #"{"sessionId":"upstream"}"#)
    }
    func emit(_ frame: String, onConsumed: ACPDurableConsumptionAcknowledgement? = nil) {
        continuation.yield(.frame(Data(frame.utf8), onConsumed: onConsumed))
    }
    func reply(_ id: Int, result: String, onConsumed: ACPDurableConsumptionAcknowledgement? = nil) {
        emit("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}", onConsumed: onConsumed)
    }
    func writeFrame(_ bytes: Data, authorize: @escaping @Sendable () -> Bool) async -> JSONRPCFrameWriteResult {
        guard authorize() else { return .notWritten }
        if let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], fields["method"] != nil {
            do { try send(bytes) } catch { return .writeUncertain(String(describing: error)) }
        } else { frames.withLock { $0.append(bytes) } }
        return .written
    }
    func terminate() { continuation.finish() }
    static let initialization = #"{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}},"authMethods":[]}"#
}
private final class BootstrapCount: Sendable { let value = Mutex(0) }
private actor BootstrapDeadlineGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if released { return }
    await withCheckedContinuation { waiters.append($0) } }
    func release() { released = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() } }
}
private actor BootstrapBindingGate: ACPV2FreshSessionBindingPersisting {
    let base: ACPSessionPersistence
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(base: ACPSessionPersistence) { self.base = base }
    func release() { waiter?.resume()
    waiter = nil }
    func bindV2FreshSession(upstreamSessionId: String, source: ACPV2InboundLedgerSource, fence: ACPSessionLeaseFence) async throws -> ACPV2FreshSessionBinding {
        let result = try await base.bindV2FreshSession(upstreamSessionId: upstreamSessionId, source: source, fence: fence)
        entered = true
        await withCheckedContinuation { waiter = $0 }
        return result
    }
}

final class BootstrapSerializedTransport: JSONRPCStdioTransporting, JSONRPCFrameWriting, @unchecked Sendable {
    static let blocker = Data("blocker".utf8)
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    private let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    let blocked = Mutex(false), attempted = Mutex(false), settled = Mutex(false)
    let bytes = Mutex<[Data]>([])
    let onWrite = Mutex<(@Sendable (Data) -> Void)?>(nil)
    let release = DispatchSemaphore(value: 0)
    private let writeSettled = DispatchSemaphore(value: 0)
    func waitForWriteSettlement() -> Bool { writeSettled.wait(timeout: .now() + 10) == .success }
    func resetWriteProbe() {
        attempted.withLock { $0 = false }
        settled.withLock { $0 = false }
        while writeSettled.wait(timeout: .now()) == .success {}
    }
    private var writer: JSONRPCFrameWriter!
    init() {
        let input = AsyncStream<JSONRPCStdioTransport.Incoming>.makeStream()
        incoming = input.stream
        continuation = input.continuation
        writer = JSONRPCFrameWriter { [unowned self] frame in
            if frame == Self.blocker { self.blocked.withLock { $0 = true }
            self.release.wait() }
            self.bytes.withLock { $0.append(frame) }
            self.onWrite.withLock { $0 }?(frame)
        }
    }
    func emit(_ bytes: Data) { continuation.yield(.frame(bytes, onConsumed: nil)) }
    func start() throws {}
    func send(_ frame: Data) throws {
        attempted.withLock { $0 = true }
        defer { settled.withLock { $0 = true } }
        try writer.send(frame)
    }
    func writeFrame(_ frame: Data, authorize: @escaping @Sendable () -> Bool) async -> JSONRPCFrameWriteResult {
        if frame != Self.blocker { attempted.withLock { $0 = true } }
        let result = await writer.writeFrame(frame, authorize: authorize)
        if frame != Self.blocker { settled.withLock { $0 = true }
        writeSettled.signal() }
        return result
    }
    func terminate() { writer.close()
    continuation.finish() }
}
