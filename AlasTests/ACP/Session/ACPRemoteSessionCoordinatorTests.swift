import Foundation
import Testing
@testable import Alas

/// In-memory wire endpoint; process arbitration and snapshot isolation are
/// exercised against two real helper processes in the Rust integration suite.
actor ReplicaEndpoint {
    private var key = RemoteSessionKey(worktreePath: "/work", agentId: "claude", remoteSessionId: "conversation")
    private var owner: RemoteSessionOwner?
    private var fence: RemoteSessionFence?
    private var procId = ""
    private var status = "idle"
    private var revision: Int64 = 0
    private var entries: [String: RemoteSessionReplicaEntry] = [:]
    private var nextPage: RemoteSessionReadResult?
    private var failContinuation = false
    private var coordinationSupported = true
    private let recordId: String

    init(recordId: String = "record") { self.recordId = recordId }

    func disconnectDuringRead(_ value: Bool) { failContinuation = value }
    func setCoordinationSupported(_ value: Bool) { coordinationSupported = value }
    private func encoded<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
    private var lease: RemoteSessionLease {
        .init(recordId: recordId, key: key, procId: procId, owner: owner, status: status, isFresh: owner != nil, revision: revision)
    }
    private func validate(_ supplied: RemoteSessionFence) throws {
        guard supplied == fence else { throw RemoteHelperClientError.jsonrpc(.init(code: -32081, message: "lease lost", data: nil)) }
    }
    func request(_ method: String, _ data: Data) throws -> Data {
        switch method {
        case "hello":
            return try encoded(RemoteHelperHelloResult(name: "alas-helper", protocolVersion: 1, binaryVersion: "0.6.0", capabilities: .init(watchKinds: [], fs: .init(read: true, write: true, stat: true, lineCounts: nil, list: nil), search: nil, proc: true, acp: nil, ping: true, sessionCoordination: coordinationSupported ? 1 : nil)))
        case "lease/claim", "lease/seize":
            let params = try decode(RemoteSessionClaimParams.self, data)
            if owner == nil || (owner == params.owner && (fence?.token == params.requestedToken || params.previousFence == fence)) || method == "lease/seize" {
                key = params.key; owner = params.owner
                if procId.isEmpty { procId = params.proposedProcId }
                fence = .init(recordId: recordId, token: params.requestedToken)
                return try encoded(RemoteSessionClaimResult(lease: lease, fence: fence))
            }
            return try encoded(RemoteSessionClaimResult(lease: lease, fence: nil))
        case "lease/bind":
            let params = try decode(RemoteSessionBindParams.self, data)
            try validate(params.fence)
            guard key.remoteSessionId == nil || key.remoteSessionId == params.remoteSessionId else {
                throw RemoteHelperClientError.jsonrpc(.init(code: -32082, message: "already bound", data: nil))
            }
            key = .init(worktreePath: key.worktreePath, agentId: key.agentId, remoteSessionId: params.remoteSessionId)
            return try encoded(lease)
        case "lease/observe":
            let params = try decode(RemoteSessionObserveParams.self, data)
            let matches = params.key.remoteSessionId != nil && params.key.remoteSessionId == key.remoteSessionId && params.key.agentId == key.agentId
            return try encoded(RemoteSessionObserveResult(lease: !matches || (owner == nil && revision == 0) ? nil : lease))
        case "lease/heartbeat":
            let params = try decode(RemoteSessionHeartbeatParams.self, data)
            try validate(params.fence); status = params.status
            return try encoded(lease)
        case "replica/publish":
            let params = try decode(RemoteSessionPublishParams.self, data)
            try validate(params.fence)
            revision += 1; status = params.status
            for entry in params.entries {
                entries[entry.kind.rawValue + "/" + entry.key] = .init(kind: entry.kind, key: entry.key, payload: entry.payload, revision: revision)
            }
            return try encoded(RemoteSessionPublishResult(revision: revision))
        case "replica/read":
            let params = try decode(RemoteSessionReadParams.self, data)
            if params.pageToken != nil {
                if failContinuation { throw NSError(domain: "ReplicaEndpoint", code: 1) }
                return try encoded(nextPage!)
            }
            let delta = entries.values.filter { $0.revision > params.afterRevision }.sorted { ($0.kind.rawValue, $0.key) < ($1.kind.rawValue, $1.key) }
            if delta.count > 1 {
                nextPage = .init(cutoffRevision: revision, entries: Array(delta.dropFirst()), nextPageToken: nil)
                return try encoded(RemoteSessionReadResult(cutoffRevision: revision, entries: Array(delta.prefix(1)), nextPageToken: "page"))
            }
            return try encoded(RemoteSessionReadResult(cutoffRevision: revision, entries: delta, nextPageToken: nil))
        case "replica/cancel": nextPage = nil; return try encoded(RemoteSessionMutationResult(ok: true))
        case "lease/release":
            try validate(decode(RemoteSessionReleaseParams.self, data).fence)
            owner = nil; fence = nil
            return try encoded(RemoteSessionMutationResult(ok: true))
        case "proc/kill":
            let params = try decode(RemoteHelperProcKillParams.self, data)
            guard let fence = params.leaseFence else { throw RemoteSessionUnavailable.ownershipLost }
            try validate(fence)
            return try encoded(RemoteHelperProcKillResult(ok: true))
        default: throw NSError(domain: "UnsupportedMethod", code: 1)
        }
    }
}

// The coordinator and its cached authority are main-actor-only app state.
@MainActor
struct ACPRemoteSessionCoordinatorTests {
    @Test("a foreign Mac imports streamed edits and takeover continues from its independent store")
    func independentStoresMirrorAndContinueAfterTakeover() async throws {
        let endpoint = ReplicaEndpoint()
        let writer = coordinator(endpoint, server: "mac-a")
        let reader = coordinator(endpoint, server: "mac-b")
        defer { writer.shutdown(); reader.shutdown() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = ACPSessionPersistence(path: folder.appendingPathComponent("a.sqlite").path)
        let b = ACPSessionPersistence(path: folder.appendingPathComponent("b.sqlite").path)
        try await a.upsertSession(row("local-a"))
        try await b.upsertSession(row("local-b"))
        let queued = QueuedPrompt(blocks: [.text("continue later")])
        try await a.upsertQueue(sessionId: "local-a", items: [queued])
        let draft = ACPComposerDraft(segments: [.text("reader's private draft")])
        try await b.upsertComposerDraft(sessionId: "local-b", draft: draft, updatedAt: 1)
        _ = try await writer.claim(sessionId: "local-a", key: key, proposedProcId: "acp-local-a", requestedToken: "a")
        try await writer.startPublishing(sessionId: "local-a", persistence: a, status: { "idle" }, onLeaseLost: {})
        _ = try await a.persistMessages([message("local-a", text: "stream starts")], fence: nil)
        await writer.flush(sessionId: "local-a")
        let claim = try await reader.claim(sessionId: "local-b", key: key, proposedProcId: "acp-local-b", requestedToken: "b")
        #expect(claim.fence == nil)
        #expect(!reader.hasAuthority(sessionId: "local-b"))
        try await reader.syncMirror(sessionId: "local-b", lease: claim.lease, persistence: b, isCurrent: { true })
        #expect(try await b.mirrorSnapshot(sessionId: "local-b").wireMessages == [wire("stream starts")])
        #expect(try await b.loadQueue(sessionId: "local-b") == [queued])
        #expect(try await b.loadComposerDraftRecord(sessionId: "local-b")?.draft == draft)
        _ = try await a.persistMessages([message("local-a", text: "stream completes")], fence: nil)
        await writer.flush(sessionId: "local-a")
        let observed = try #require(try await reader.observe(sessionId: "local-b", key: key))
        try await reader.syncMirror(sessionId: "local-b", lease: observed, persistence: b, isCurrent: { true })
        #expect(try await b.mirrorSnapshot(sessionId: "local-b").wireMessages == [wire("stream completes")])
        let takeover = try await reader.claim(sessionId: "local-b", key: key, proposedProcId: "acp-local-b", requestedToken: "successor", seize: true)
        #expect(takeover.lease.procId == "acp-local-a")
        do { _ = try await writer.heartbeat(sessionId: "local-a", status: "busy"); Issue.record("stale writer heartbeat succeeded") }
        catch { #expect(error.isRemoteSessionLeaseLoss) }
        #expect(!writer.hasAuthority(sessionId: "local-a"))
        writer.stopPublishing(sessionId: "local-a")
        try await reader.startPublishing(sessionId: "local-b", persistence: b, status: { "idle" }, onLeaseLost: {})
        _ = try await b.persistMessages([message("local-b", text: "successor continues")], fence: nil)
        await reader.flush(sessionId: "local-b")
        let successor = try #require(try await writer.observe(sessionId: "local-a", key: key))
        try await writer.syncMirror(sessionId: "local-a", lease: successor, persistence: a, isCurrent: { true })
        #expect(try await a.mirrorSnapshot(sessionId: "local-a").wireMessages == [wire("successor continues")])
    }

    @Test("a disconnected paginated read cannot replace the last complete local transcript")
    func incompleteReplicaReadDoesNotAdvanceLocalState() async throws {
        let endpoint = ReplicaEndpoint()
        let writer = coordinator(endpoint, server: "a")
        let reader = coordinator(endpoint, server: "b")
        defer { writer.shutdown(); reader.shutdown() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = ACPSessionPersistence(path: folder.appendingPathComponent("a.sqlite").path)
        let b = ACPSessionPersistence(path: folder.appendingPathComponent("b.sqlite").path)
        try await a.upsertSession(row("a")); try await b.upsertSession(row("b"))
        _ = try await b.persistMessages([message("b", text: "last complete transcript")], fence: nil)
        _ = try await writer.claim(sessionId: "a", key: key, proposedProcId: "acp-a", requestedToken: "a")
        try await writer.startPublishing(sessionId: "a", persistence: a, status: { "idle" }, onLeaseLost: {})
        _ = try await a.persistMessages([message("a", text: "remote transcript")], fence: nil)
        await writer.flush(sessionId: "a")
        let observed = try #require(try await reader.observe(sessionId: "b", key: key))
        await endpoint.disconnectDuringRead(true)
        do { try await reader.syncMirror(sessionId: "b", lease: observed, persistence: b, isCurrent: { true }); Issue.record("incomplete read committed") }
        catch { #expect(try await b.mirrorSnapshot(sessionId: "b").wireMessages == [wire("last complete transcript")]) }
        #expect(try await b.replicaRevision(sessionId: "b", recordId: "record") == 0)
        await endpoint.disconnectDuringRead(false)
        try await reader.syncMirror(sessionId: "b", lease: observed, persistence: b, isCurrent: { true })
        #expect(try await b.mirrorSnapshot(sessionId: "b").wireMessages == [wire("remote transcript")])
    }

    @Test("same-machine mirrors use the shared local transcript instead of a lagging remote replica")
    func sameMachineDoesNotOverwriteUnpublishedLocalRows() async throws {
        let endpoint = ReplicaEndpoint()
        let writer = coordinator(endpoint, server: "mac", instance: "writer")
        let reader = coordinator(endpoint, server: "mac", instance: "reader")
        defer { writer.shutdown(); reader.shutdown() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = ACPSessionPersistence(path: folder.appendingPathComponent("shared.sqlite").path)
        try await persistence.upsertSession(row("session"))
        _ = try await writer.claim(sessionId: "session", key: key, proposedProcId: "acp-session", requestedToken: "writer")
        try await writer.startPublishing(sessionId: "session", persistence: persistence, status: { "idle" }, onLeaseLost: {})
        _ = try await persistence.persistMessages([message("session", text: "published")], fence: nil)
        await writer.flush(sessionId: "session")
        writer.stopPublishing(sessionId: "session")
        _ = try await persistence.persistMessages([message("session", text: "newer local row")], fence: nil)
        let observed = try #require(try await reader.observe(sessionId: "session", key: key))
        try await reader.syncMirror(sessionId: "session", lease: observed, persistence: persistence, isCurrent: { true })
        #expect(try await persistence.mirrorSnapshot(sessionId: "session").wireMessages == [wire("newer local row")])
    }

    @Test("replacing this Mac's unavailable writer preserves unpublished rows and resumes publication")
    func replacementWriterPreservesUnpublishedRows() async throws {
        let endpoint = ReplicaEndpoint()
        let writer = coordinator(endpoint, server: "mac")
        let reader = coordinator(endpoint, server: "other")
        defer { writer.shutdown(); reader.shutdown() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = ACPSessionPersistence(path: folder.appendingPathComponent("local.sqlite").path)
        let mirror = ACPSessionPersistence(path: folder.appendingPathComponent("mirror.sqlite").path)
        try await local.upsertSession(row("session")); try await mirror.upsertSession(row("mirror"))
        _ = try await writer.claim(sessionId: "session", key: key, proposedProcId: "acp-session", requestedToken: "first")
        try await writer.startPublishing(sessionId: "session", persistence: local, status: { "idle" }, onLeaseLost: {})
        _ = try await local.persistMessages([message("session", text: "published")], fence: nil)
        await writer.flush(sessionId: "session")
        writer.markUnavailable(sessionId: "session")
        _ = try await local.persistMessages([message("session", text: "committed while offline")], fence: nil)
        let replacement = try await writer.claim(sessionId: "session", key: key, proposedProcId: "acp-session", requestedToken: "replacement", seize: true)
        try await writer.syncMirror(sessionId: "session", lease: replacement.lease, persistence: local, isCurrent: { true })
        #expect(try await local.mirrorSnapshot(sessionId: "session").wireMessages == [wire("committed while offline")])
        try await writer.startPublishing(sessionId: "session", persistence: local, status: { "idle" }, onLeaseLost: {})
        await writer.flush(sessionId: "session")
        let observed = try #require(try await reader.observe(sessionId: "mirror", key: key))
        try await reader.syncMirror(sessionId: "mirror", lease: observed, persistence: mirror, isCurrent: { true })
        #expect(try await mirror.mirrorSnapshot(sessionId: "mirror").wireMessages == [wire("committed while offline")])
    }

    private var key: RemoteSessionKey { .init(worktreePath: "/work", agentId: "claude", remoteSessionId: "conversation") }
    private func coordinator(_ endpoint: ReplicaEndpoint, server: String, instance: String = "instance") -> ACPRemoteSessionCoordinator {
        .init(owner: .init(serverId: server, instanceId: instance)) { method, data in try await endpoint.request(method, data) }
    }
    private func row(_ id: String) -> ACPSessionRow {
        .init(id: id, agentId: "claude", title: "Session", remoteSessionId: "conversation", currentModel: nil, currentMode: nil, autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false)
    }
    private func message(_ id: String, text: String) -> ACPStoredMessage {
        .init(id: "msg-\(id)-0", sessionId: id, kind: "agent", seq: 0, payload: try! JSONSerialization.data(withJSONObject: ["text": text]), createdAt: 1)
    }
    private func wire(_ text: String) -> ACPMessageWire { .agent(messageId: nil, text: text, phase: nil, metadata: nil) }
}
