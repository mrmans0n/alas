import Foundation
import Testing
import AlasCore

// Manager membership, projection and command admission are main-actor APIs.
@MainActor
struct ACPSessionManagerTests {
    @Test func incompleteAppQualificationKeepsProductionAdmissionEmpty() async throws {
        let fixture = try PreviewManagerFixture()
        defer { fixture.manager.shutdownBackgroundTasks() }
        fixture.manager.prepareV2PreviewLaunchForTesting = nil
        fixture.manager.v2PreviewAdmissionRecordsForTesting = nil
        #expect(ACPV2PreviewEligibility.qualifiedAdapters.isEmpty)
        #expect(!fixture.manager.offersV2PreviewCreation)
        await #expect(throws: (any Error).self) { try await fixture.manager.createV2PreviewSession(agentId: "codex") }
        #expect(await fixture.service.opened.isEmpty)
        #expect(try fixture.store.recentSessions().isEmpty)
    }

    @Test(arguments: ["disabled", "changed", "startup", "reopen"])
    func explicitPreviewNeverFallsThroughTheLegacyFactories(failure: String) async throws {
        let fixture = try PreviewManagerFixture()
        defer { fixture.manager.shutdownBackgroundTasks() }
        if failure == "reopen" {
            _ = try fixture.store.createV2PreviewSession(row: fixture.row(), ownerInstance: "preview-fixture", pid: Int64(getpid()), now: 1, leaseToken: "saved")
            _ = await fixture.manager.persistedSessionRow(id: "saved")
            _ = fixture.manager.placeholderSession(id: "saved")
            await fixture.manager.hydrateIfNeeded(id: "saved")
            await fixture.manager.attach(to: "saved", freshlyCreated: false)
        } else {
            fixture.probe.enabled = failure != "disabled"
            fixture.probe.changeOnRevalidation = failure == "changed"
            if failure == "startup" { await fixture.service.failInitialization() }
            _ = try? await fixture.manager.createV2PreviewSession(agentId: "codex")
        }
        #expect(fixture.probe.legacyFactoryCalls == 0)
        #expect(await fixture.service.opened.count == (failure == "startup" ? 1 : 0))
        let rows = try fixture.store.recentSessions()
        #expect(rows.allSatisfy { $0.runtimeKind == .v2FreshPreview })
        if failure != "disabled" { #expect(rows.count == 1) }
        await fixture.manager.disposeAllLiveSessions()
    }

    @Test func npmBinSymlinksOpenTheirQualifiedPackageExecutable() async throws {
        let fixture = try PreviewManagerFixture(npmSymlink: true)
        defer { fixture.manager.shutdownBackgroundTasks() }
        let session = try await fixture.manager.createV2PreviewSession(agentId: "codex")
        #expect(fixture.manager.v2PreviewPresentation(for: session.id).status == .ready)
        #expect(await fixture.service.opened.first?.command == fixture.canonicalCommand)
        await fixture.manager.disposeAllLiveSessions()
    }

    @Test(arguments: ["dependency", "provider"])
    func finalLaunchIdentityFollowsHeldBrokerPreparation(change: String) async throws {
        let fixture = try PreviewManagerFixture(npmSymlink: true)
        defer { fixture.manager.shutdownBackgroundTasks()
        Task { await fixture.service.releasePreparation() } }
        await fixture.service.holdPreparation()
        let starting = Task { try await fixture.manager.createV2PreviewSession(agentId: "codex") }
        try await eventually { await fixture.service.preparationCount > 0 }
        if change == "dependency" {
            try Data("changed dependency".utf8).write(to: #require(fixture.dependencyURL))
        } else { fixture.probe.changeProviderOnRevalidation = true }
        await fixture.service.releasePreparation()
        let session = try await starting.value
        #expect(await fixture.service.opened.isEmpty)
        #expect(!fixture.manager.v2PreviewPresentation(for: session.id).canSend)
        #expect(session.lastError != nil)
        await fixture.manager.disposeAllLiveSessions()
    }

    @Test func gateChangesAffectOnlyFuturePreviewCreation() async throws {
        let fixture = try PreviewManagerFixture()
        defer { fixture.manager.shutdownBackgroundTasks() }
        let session = try await fixture.manager.createV2PreviewSession(agentId: "codex")
        #expect(session.runtimeKind == .v2FreshPreview)
        let mode = session.currentMode
        let model = session.currentModel
        await fixture.manager.enqueueModeSelection(for: session.id, modeId: "bypassPermissions").value
        await fixture.manager.enqueueModelSelection(for: session.id, modelId: "other").value
        #expect(session.currentMode == mode && session.currentModel == model)
        fixture.probe.enabled = false
        await #expect(throws: (any Error).self) { try await fixture.manager.createV2PreviewSession(agentId: "codex") }
        let sent = try await fixture.manager.sendV2PreviewText(for: session.id, text: "manual")
        if case .accepted = sent.recovery {} else { Issue.record("The live preview lost its manual send route") }
        #expect(await fixture.service.opened.count == 1)
        #expect(fixture.probe.legacyFactoryCalls == 0)
        await fixture.manager.disposeAllLiveSessions()
    }

    @Test(arguments: ["attach", "restart", "fork", "delegation", "peer", "submit", "queue", "takeover"], ["v2FreshPreview", "futureRuntime"])
    func previewRowsRejectLegacyResumeQueueAndProgrammaticDrive(action: String, kind: String) async throws {
        let fixture = try PreviewManagerFixture()
        defer { fixture.manager.shutdownBackgroundTasks() }
        var row = fixture.row()
        row.runtimeKind = .init(rawValue: kind)
        try fixture.store.upsertSession(row)
        _ = await fixture.manager.persistedSessionRow(id: row.id)
        let session = try #require(fixture.manager.placeholderSession(id: row.id))
        await fixture.manager.hydrateIfNeeded(id: row.id)
        #expect(session.runtimeKind == row.runtimeKind)
        switch action {
        case "attach": await fixture.manager.attach(to: row.id, freshlyCreated: false)
        case "restart": await fixture.manager.restartConnection(to: row.id)
        case "fork":
            await #expect(throws: (any Error).self) {
                try await fixture.manager.createFork(sourceSessionID: row.id, boundary: .init(stableID: "m", kind: .agent), targetAgentID: "codex", autoRunDefault: false)
            }
        case "delegation":
            #expect(await fixture.manager.enqueueDelegatedPrompt(text: "automatic", source: .init(sessionId: "parent", messageId: "m"), into: row.id) == false)
        case "peer":
            var accepted = true
            await fixture.manager.sendPrompt(for: row.id, text: "remote", attachments: [], onResult: { accepted = $0 })
            #expect(!accepted)
        case "submit":
            #expect(fixture.manager.submit(sessionId: row.id, text: "programmatic", attachments: [], intent: .auto, onCompleted: { _ in }) == false)
        case "queue": #expect(await fixture.manager.enqueuePrompt(id: UUID(), text: "queued", into: row.id) == false)
        default: #expect(await fixture.manager.takeOver(sessionId: row.id) == false)
        }
        #expect(session.queue.isEmpty)
        #expect(fixture.probe.legacyFactoryCalls == 0)
        #expect(await fixture.service.opened.isEmpty)
        #expect(try fixture.store.loadQueue(sessionId: row.id).isEmpty)
    }

    @Test(arguments: [false, true])
    func previewReopeningLoadsOnlySavedDisplay(failed: Bool) async throws {
        let fixture = try PreviewManagerFixture()
        defer { fixture.manager.shutdownBackgroundTasks() }
        let fence = try fixture.store.createV2PreviewSession(row: fixture.row(), ownerInstance: "preview-fixture", pid: Int64(getpid()), now: 1, leaseToken: "saved")
        let row = ACPMessage.agent(id: UUID(), StreamingText("saved final text"))
        let display = try ACPV2PreviewDisplaySnapshot(sessionId: "saved", installationID: UUID(), sequence: 1, status: failed ? .failed : .observing, messages: [row], failureMessage: failed ? "saved turn error" : nil)
        #expect(try fixture.store.persistV2PreviewDisplay(display, fence: fence, authorize: { true }))
        _ = await fixture.manager.persistedSessionRow(id: "saved")
        let session = try #require(fixture.manager.placeholderSession(id: "saved"))
        await fixture.manager.hydrateIfNeeded(id: "saved")
        await fixture.manager.attach(to: "saved", freshlyCreated: false)
        #expect(session.transcript.messages.map(\.stableIdentityKey) == [row.stableIdentityKey])
        #expect(session.lastError == (failed ? "saved turn error" : nil))
        #expect(fixture.manager.v2PreviewPresentation(for: "saved").viewOnly)
        #expect(fixture.manager.v2PreviewPermissions(for: "saved").isEmpty)
        #expect(fixture.probe.legacyFactoryCalls == 0)
        #expect(await fixture.service.opened.isEmpty)
    }

    @Test(arguments: ["match", "foreign", "generation", "lease", "adopted"])
    func orphanCleanupRequiresAnUnchangedSourceAndCurrentLease(reason: String) async throws {
        let fixture = try PreviewManagerFixture()
        defer { fixture.manager.shutdownBackgroundTasks() }
        let fence = try fixture.store.createV2PreviewSession(row: fixture.row(), ownerInstance: "preview-fixture", pid: Int64(getpid()), now: 1, leaseToken: "saved")
        if reason != "adopted" {
            #expect(try fixture.store.bindV2FreshBroker(state: .init(brokerId: .init(rawValue: "orphan"), generation: .init(rawValue: 7), acknowledgedCursor: .init(rawValue: 0), wireContext: .rawV2), fence: fence))
        }
        if reason == "lease" { try fixture.store.seizeLease(sessionId: "saved", instanceId: "Other", pid: 1, now: Int64(Date().timeIntervalSince1970), leaseToken: "other") }
        await fixture.service.seedOrphan(sessionId: reason == "foreign" ? "foreign" : "saved", generation: reason == "generation" ? 8 : 7)
        _ = await fixture.manager.persistedSessionRow(id: "saved")
        if reason == "match" { try await fixture.manager.endRemainingV2PreviewProcess(for: "saved") }
        else { await #expect(throws: (any Error).self) { try await fixture.manager.endRemainingV2PreviewProcess(for: "saved") } }
        #expect(await fixture.service.closed.count == (reason == "match" ? 1 : 0))
        #expect(await fixture.service.opened.isEmpty)
        #expect(fixture.probe.legacyFactoryCalls == 0)
        if reason == "foreign" || reason == "generation" {
            #expect(try fixture.store.loadLease(sessionId: "saved") == nil)
        }
    }

    @Test(arguments: [false, true])
    func shutdownEndsOnlyItsFreshPreviewSource(adopted: Bool) async throws {
        let fixture = try PreviewManagerFixture()
        await fixture.service.holdOpen(adopted: adopted)
        let starting = Task { try await fixture.manager.createV2PreviewSession(agentId: "codex") }
        await fixture.service.waitForOpen()
        fixture.manager.prepareForDisposal()
        let disposing = Task { await fixture.manager.disposeAllLiveSessions() }
        await fixture.service.releaseOpen()
        _ = try? await starting.value
        await disposing.value
        fixture.manager.shutdownBackgroundTasks()
        #expect(await fixture.service.closed.count == (adopted ? 0 : 1))
        #expect(fixture.probe.legacyFactoryCalls == 0)
    }
}

@MainActor
private final class PreviewManagerFixture {
    final class Probe { var enabled = true
    var changeOnRevalidation = false
    var changeProviderOnRevalidation = false
    var preparations = 0
    var legacyFactoryCalls = 0 }
    let probe = Probe()
    let service = PreviewManagerBrokerService()
    let store: ACPSessionStore
    let manager: ACPSessionManager
    let canonicalCommand: String
    let dependencyURL: URL?
    init(npmSymlink: Bool = false) throws {
        let command: String
        if npmSymlink {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-npm-bin-\(UUID())", isDirectory: true)
            let entry = root.appendingPathComponent("package/dist/index.js")
            let bin = root.appendingPathComponent("bin/codex-acp")
            try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
            try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: entry)
            let dependency = root.appendingPathComponent("package/dependency.js")
            try Data("original dependency".utf8).write(to: dependency)
            dependencyURL = dependency
            command = bin.path
            canonicalCommand = entry.resolvingSymlinksInPath().path
        } else { command = "/qualified/adapter"
        canonicalCommand = command
        dependencyURL = nil }
        let canonicalCommand = canonicalCommand
        let dependencyURL = dependencyURL
        let originalDependency = try dependencyURL.map { try ACPLaunchContentIdentity.fileDigest($0) }
        store = try ACPSessionStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("preview-manager-\(UUID()).sqlite").path)
        let probe = probe
        let service = service
        manager = ACPSessionManager(worktreeId: "preview-\(UUID())", worktreePath: "/private/tmp", store: store,
            instanceId: "preview-fixture", pid: Int64(getpid()), experimentalACP2Enabled: { probe.enabled },
            setupEvaluator: { _ in .ready }, connectionFactory: { _, _, _ in probe.legacyFactoryCalls += 1
            throw ACPClientError.notRunning },
            brokerServiceFactory: { service })
        manager.v2PreviewAdmissionRecordsForTesting = ACPV2PreviewEligibility.qualificationEvidence
        manager.prepareV2PreviewLaunchForTesting = { agentId in
            probe.preparations += 1
            let record = try #require(ACPV2PreviewEligibility.qualificationEvidence.first { $0.agentID == agentId })
            let spec = try #require(ACPLaunchCatalog.spec(for: agentId)).overridingCommand(command).mergingExtraEnv(["INITIAL_AGENT_MODE": "read-only"])
            let identity = ACPV2PreviewLaunchIdentity(agentID: agentId, packageName: record.packageName, packageVersion: record.packageVersion,
                packageDigest: try dependencyURL.map { try ACPLaunchContentIdentity.fileDigest($0) } == originalDependency ? record.packageDigest : "changed", helperDigest: probe.changeOnRevalidation && probe.preparations > 1 ? "changed" : record.helperDigest,
                providerID: probe.changeProviderOnRevalidation && probe.preparations > 1 ? "changed" : record.providerID, approvalMode: record.approvalMode, nodeDigest: record.nodeDigest, sourceCommit: record.sourceCommit,
                executable: URL(fileURLWithPath: canonicalCommand), packageRoot: URL(fileURLWithPath: "/qualified/package"),
                helper: URL(fileURLWithPath: "/qualified/helper"), nodeExecutable: URL(fileURLWithPath: "/qualified/node"), routingDigest: "fixture")
            return ACPV2PreviewPreparedLaunch(spec: spec, environment: ["INITIAL_AGENT_MODE": "read-only"], helperURL: identity.helper, identity: identity)
        }
    }
    func row() -> ACPSessionRow { .init(id: "saved", agentId: "codex", title: "Saved", autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false) }
}

private actor PreviewManagerBrokerService: ACPBrokerServicing {
    private var metadata: ACPBrokerMetadata?
    private var cursor: UInt64 = 0
    private var acknowledged: UInt64 = 0
    private var events: [ACPBrokerEvent] = []
    private var failInitialize = false
    private var held = false
    private var adopted = false
    private let openedSignal = AsyncStream<Void>.makeStream()
    private var openWaiter: CheckedContinuation<Void, Never>?
    var opened: [ACPBrokerOpenParams] = []
    var closed: [ACPBrokerCloseParams] = []
    func failInitialization() { failInitialize = true }
    func holdOpen(adopted: Bool) { held = true
    self.adopted = adopted }
    func waitForOpen() async { var values = openedSignal.stream.makeAsyncIterator()
    _ = await values.next() }
    func releaseOpen() { held = false
    openWaiter?.resume()
    openWaiter = nil }
    func seedOrphan(sessionId: String, generation: UInt64) {
        var value = ACPBrokerMetadata(brokerId: .init(rawValue: "orphan"), generation: .init(rawValue: generation), alasSessionId: sessionId,
            adapterProgram: "/qualified/adapter", adapterArgs: [], cwd: "/private/tmp", envKeys: [], createdAtMillis: 0)
        value.wireContext = .rawV2
        metadata = value
    }
    private func snapshot() throws -> ACPBrokerSnapshot {
        guard let metadata else { throw ACPClientError.notRunning }
        return .init(metadata: metadata, initializeResult: nil, remoteSessionResult: nil, turnState: .unknown("unknown"),
            acknowledgedCursor: .init(rawValue: acknowledged), journalTail: .init(rawValue: cursor), pendingRequests: [], operations: [])
    }
    private var preparationHeld = false
    private var preparationWaiter: CheckedContinuation<Void, Never>?
    var preparationCount = 0
    func holdPreparation() { preparationHeld = true }
    func releasePreparation() { preparationHeld = false
    preparationWaiter?.resume()
    preparationWaiter = nil }
    private func prepareOpen() async {
        preparationCount += 1
        if preparationHeld { await withCheckedContinuation { preparationWaiter = $0 } }
    }
    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        await prepareOpen()
        return try await performOpen(params)
    }
    func open(_ params: ACPBrokerOpenParams, authorizeBeforeSend: @escaping @Sendable () async throws -> Void) async throws -> ACPBrokerOpenResult {
        await prepareOpen()
        try await authorizeBeforeSend()
        return try await performOpen(params)
    }
    private func performOpen(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        opened.append(params)
        var value = ACPBrokerMetadata(brokerId: params.brokerId, generation: .init(rawValue: 7), alasSessionId: params.sessionId,
            adapterProgram: params.command, adapterArgs: params.args, cwd: params.cwd, envKeys: Array(params.env.keys), createdAtMillis: 0)
        value.wireContext = .rawV2
        metadata = value
        openedSignal.continuation.yield(())
        if held { await withCheckedContinuation { openWaiter = $0 } }
        return .init(snapshot: try snapshot(), adopted: adopted)
    }
    func attach(_ params: ACPBrokerAttachParams) throws -> ACPBrokerAttachResult {
        guard params.wireContext == .rawV2, params.generation == metadata?.generation else { throw ACPClientError.notRunning }
        return .init(snapshot: try snapshot(), events: events.filter { $0.cursor > (params.replayAfterCursor ?? params.acknowledgedCursor) })
    }
    func send(_ params: ACPBrokerSendParams) throws -> ACPBrokerSendResult {
        if failInitialize, params.method == "initialize" { throw ACPClientError.notRunning }
        cursor += 1
        events.append(.init(cursor: .init(rawValue: cursor), kind: .operationStarted(operationKey: params.operationKey, adapterRequestId: .init(rawValue: 9), method: params.method)))
        let result = params.method == "initialize" ? #"{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}}"#
            : params.method == "session/new" ? #"{"sessionId":"upstream"}"# : #"{"messageId":"manual"}"#
        let frame = ACPBrokerRawJSONPayload(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":\(result)}".utf8))
        var outcome = ACPBrokerRPCOutcome(result: nil, error: nil)
        outcome.rawFrame = frame
        cursor += 1
        events.append(.init(cursor: .init(rawValue: cursor), kind: .operationCompleted(operationKey: params.operationKey, outcome: outcome)))
        var sent = ACPBrokerSendResult(requestId: .init(rawValue: 9), replayed: false, error: nil)
        sent.rawFrame = frame
        return sent
    }
    func ack(_ params: ACPBrokerAckParams) -> ACPBrokerSimpleOK { acknowledged = params.cursor.rawValue
    return .init(ok: true) }
    func detach(_ params: ACPBrokerDetachParams) -> ACPBrokerSimpleOK { .init(ok: true) }
    func close(_ params: ACPBrokerCloseParams) throws -> ACPBrokerSimpleOK {
        guard params.wireContext == .rawV2, params.brokerId == metadata?.brokerId, params.generation == metadata?.generation else { throw ACPClientError.notRunning }
        closed.append(params)
        return .init(ok: true)
    }
    func notify(_ params: ACPBrokerNotifyParams) -> ACPBrokerSimpleOK { .init(ok: true) }
    func respond(_ params: ACPBrokerRespondParams) -> ACPBrokerSimpleOK { .init(ok: true) }
}
