import Foundation

/// Remote authority is separate from the Mac's local SQLite lease. A helper
/// token is immutable for an attachment, even if a newer attachment takes over.
@MainActor
final class ACPRemoteSessionCoordinator {
    typealias Request = @Sendable (_ method: String, _ encodedParams: Data) async throws -> Data
    private struct Authority {
        var lease: RemoteSessionLease
        var fence: RemoteSessionFence?
        var confirmed: Bool
    }
    private struct Publication {
        let persistence: ACPSessionPersistence
        let status: @MainActor () -> String
        let onLeaseLost: @MainActor () async -> Void
    }
    let owner: RemoteSessionOwner
    private let request: Request
    private var authorities: [String: Authority] = [:]
    private var epochs: [String: UUID] = [:]
    private var claims: [String: Task<RemoteSessionClaimResult, Error>] = [:]
    private var reads: [String: Task<Void, Error>] = [:]
    private var readEpochs: [String: UUID] = [:]
    private var publications: [String: Publication] = [:]
    private var drains: [String: Task<Void, Never>] = [:]
    private var drainEpochs: [String: UUID] = [:]
    private var locallySharedRecords: Set<String> = []
    private var pending: [String: ACPSessionReplicaExport] = [:]
    private var dirty: Set<String> = []
    private var changeTask: Task<Void, Never>?

    init(owner: RemoteSessionOwner, request: @escaping Request) {
        self.owner = owner
        self.request = request
    }

    convenience init(host: String, owner: RemoteSessionOwner) {
        self.init(owner: owner) { method, params in
            let client = await RemoteHelperClientPool.shared.client(for: host)
            return try await client.remoteSessionRequest(method: method, encodedParams: params)
        }
    }

    private func call<P: Encodable, R: Decodable>(_ method: String, _ params: P, as: R.Type = R.self) async throws -> R {
        let data = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(R.self, from: await request(method, data))
    }

    func requireCapability() async throws {
        let result: RemoteHelperHelloResult = try await call("hello", RemoteHelperHelloParams())
        guard result.capabilities.proc == true, result.capabilities.sessionCoordination == 1 else { throw RemoteSessionUnavailable.helperRequired }
    }

    func lease(sessionId: String) -> RemoteSessionLease? { authorities[sessionId]?.lease }
    func fence(sessionId: String) -> RemoteSessionFence? { authorities[sessionId]?.fence }
    func isPublishing(sessionId: String) -> Bool { publications[sessionId] != nil }
    func hasAuthority(sessionId: String) -> Bool {
        guard let state = authorities[sessionId] else { return false }
        return state.confirmed && state.fence != nil && state.lease.owner == owner
    }
    func isForeignMirror(sessionId: String) -> Bool {
        guard let lease = authorities[sessionId]?.lease else { return false }
        return lease.isFresh && lease.owner != nil && lease.owner != owner
    }
    func isForeignMachine(sessionId: String) -> Bool {
        guard let lease = authorities[sessionId]?.lease, lease.isFresh, let other = lease.owner else { return false }
        return other.serverId != owner.serverId
    }
    func markUnavailable(sessionId: String) { authorities[sessionId]?.confirmed = false }

    func claim(sessionId: String, key: RemoteSessionKey, proposedProcId: String, requestedToken: String, seize: Bool = false) async throws -> RemoteSessionClaimResult {
        let epoch = UUID()
        epochs[sessionId] = epoch
        let predecessor = claims[sessionId]
        let task = Task { @MainActor in
            if let predecessor { _ = try? await predecessor.value }
            try Task.checkCancellation()
            guard self.epochs[sessionId] == epoch else { throw CancellationError() }
            return try await self.performClaim(sessionId: sessionId, key: key, proposedProcId: proposedProcId, requestedToken: requestedToken, seize: seize, epoch: epoch)
        }
        claims[sessionId] = task
        defer { if epochs[sessionId] == epoch { claims.removeValue(forKey: sessionId) } }
        return try await task.value
    }

    private func performClaim(sessionId: String, key: RemoteSessionKey, proposedProcId: String, requestedToken: String, seize: Bool, epoch: UUID) async throws -> RemoteSessionClaimResult {
        try await requireCapability()
        let params = RemoteSessionClaimParams(key: .init(worktreePath: RemotePath.realPath(key.worktreePath), agentId: key.agentId, remoteSessionId: key.remoteSessionId), owner: owner, proposedProcId: proposedProcId, requestedToken: requestedToken, previousFence: seize ? nil : authorities[sessionId]?.fence)
        if key.remoteSessionId != nil {
            let previous: RemoteSessionObserveResult = try await call("lease/observe", RemoteSessionObserveParams(key: params.key))
            if previous.lease?.owner?.serverId == owner.serverId {
                if let recordId = previous.lease?.recordId { locallySharedRecords.insert(recordId) }
            } else if let recordId = previous.lease?.recordId { locallySharedRecords.remove(recordId) }
        }
        let result: RemoteSessionClaimResult = try await call(seize ? "lease/seize" : "lease/claim", params)
        guard epochs[sessionId] == epoch else {
            if let fence = result.fence { try? await release(fence: fence) }
            throw CancellationError()
        }
        if publications[sessionId] != nil, fence(sessionId: sessionId) != result.fence {
            stopPublishing(sessionId: sessionId)
        }
        authorities[sessionId] = Authority(lease: result.lease, fence: result.fence, confirmed: result.fence != nil)
        return result
    }

    func bind(sessionId: String, remoteSessionId: String) async throws {
        guard let fence = fence(sessionId: sessionId) else { throw RemoteSessionUnavailable.ownershipLost }
        let result: RemoteSessionLease = try await call("lease/bind", RemoteSessionBindParams(fence: fence, remoteSessionId: remoteSessionId))
        guard self.fence(sessionId: sessionId) == fence else { throw CancellationError() }
        authorities[sessionId]?.lease = result
    }

    func heartbeat(sessionId: String, status: String) async throws -> Bool {
        guard let fence = fence(sessionId: sessionId) else { return false }
        do {
            let result: RemoteSessionLease = try await call("lease/heartbeat", RemoteSessionHeartbeatParams(fence: fence, status: status))
            guard self.fence(sessionId: sessionId) == fence else { return false }
            authorities[sessionId]?.lease = result
            authorities[sessionId]?.confirmed = true
            wake(sessionId: sessionId)
            return true
        } catch {
            if self.fence(sessionId: sessionId) == fence { markUnavailable(sessionId: sessionId) }
            throw error
        }
    }

    func observe(sessionId: String, key: RemoteSessionKey) async throws -> RemoteSessionLease? {
        let epoch = epochs[sessionId]
        let result: RemoteSessionObserveResult = try await call("lease/observe", RemoteSessionObserveParams(key: .init(worktreePath: RemotePath.realPath(key.worktreePath), agentId: key.agentId, remoteSessionId: key.remoteSessionId)))
        guard epochs[sessionId] == epoch else { throw CancellationError() }
        if let lease = result.lease {
            if lease.owner?.serverId == owner.serverId, lease.owner?.instanceId != owner.instanceId {
                locallySharedRecords.insert(lease.recordId)
            } else if lease.owner?.serverId != owner.serverId { locallySharedRecords.remove(lease.recordId) }
            if var authority = authorities[sessionId], authority.lease.recordId == lease.recordId {
                authority.lease = lease
                if lease.owner != owner || !lease.isFresh { authority.confirmed = false }
                authorities[sessionId] = authority
            } else { authorities[sessionId] = Authority(lease: lease, fence: nil, confirmed: false) }
        } else { authorities.removeValue(forKey: sessionId) }
        return result.lease
    }

    func release(fence: RemoteSessionFence) async throws {
        let _: RemoteSessionMutationResult = try await call("lease/release", RemoteSessionReleaseParams(fence: fence))
    }

    func release(sessionId: String, expectedFence: RemoteSessionFence) async {
        guard fence(sessionId: sessionId) == expectedFence else { try? await release(fence: expectedFence)
        return }
        stopPublishing(sessionId: sessionId)
        try? await release(fence: expectedFence)
        if fence(sessionId: sessionId) == expectedFence {
            authorities[sessionId]?.fence = nil
            authorities[sessionId]?.confirmed = false
        }
    }

    func killProc(sessionId: String, expectedFence: RemoteSessionFence) async throws {
        guard fence(sessionId: sessionId) == expectedFence, let lease = lease(sessionId: sessionId) else { throw RemoteSessionUnavailable.ownershipLost }
        let _: RemoteHelperProcKillResult = try await call("proc/kill", RemoteHelperProcKillParams(procId: lease.procId, leaseFence: expectedFence))
    }

    func stopAndRelease(procId: String, expectedFence: RemoteSessionFence) async {
        let _: RemoteHelperProcKillResult? = try? await call("proc/kill", RemoteHelperProcKillParams(procId: procId, leaseFence: expectedFence))
        try? await release(fence: expectedFence)
    }

    func delete(sessionId: String, expectedFence: RemoteSessionFence) async throws {
        guard let fence = fence(sessionId: sessionId), fence == expectedFence,
              hasAuthority(sessionId: sessionId) else { throw RemoteSessionUnavailable.ownershipLost }
        let _: RemoteSessionMutationResult = try await call("lease/delete", RemoteSessionReleaseParams(fence: fence))
        guard self.fence(sessionId: sessionId) == fence else { return }
        stopPublishing(sessionId: sessionId)
        authorities.removeValue(forKey: sessionId)
    }

    func startPublishing(sessionId: String, persistence: ACPSessionPersistence, localFence: ACPSessionLeaseFence? = nil, status: @escaping @MainActor () -> String, onLeaseLost: @escaping @MainActor () async -> Void) async throws {
        guard let lease = lease(sessionId: sessionId), let expectedFence = fence(sessionId: sessionId), hasAuthority(sessionId: sessionId) else { throw RemoteSessionUnavailable.ownershipLost }
        if changeTask == nil {
            // Register before suspension so concurrent child attachments
            // cannot replace the database's one outbox observer.
            changeTask = Task { @MainActor [weak self] in
                guard let events = try? await persistence.replicaChangeEvents() else { return }
                for await _ in events {
                    guard !Task.isCancelled, let self else { return }
                    for id in self.publications.keys { self.wake(sessionId: id) }
                }
            }
        }
        try await persistence.enableReplicaExport(sessionId: sessionId, recordId: lease.recordId, localFence: localFence)
        guard fence(sessionId: sessionId) == expectedFence, hasAuthority(sessionId: sessionId) else { throw CancellationError() }
        publications[sessionId] = Publication(persistence: persistence, status: status, onLeaseLost: onLeaseLost)
        wake(sessionId: sessionId)
    }

    func wake(sessionId: String) {
        guard publications[sessionId] != nil else { return }
        dirty.insert(sessionId)
        guard drains[sessionId] == nil, hasAuthority(sessionId: sessionId), let fence = fence(sessionId: sessionId) else { return }
        let epoch = UUID()
        drainEpochs[sessionId] = epoch
        drains[sessionId] = Task { @MainActor [weak self] in
            await self?.drain(sessionId: sessionId, expectedFence: fence, epoch: epoch)
        }
    }

    private func drain(sessionId: String, expectedFence: RemoteSessionFence, epoch: UUID) async {
        defer {
            if drainEpochs[sessionId] == epoch {
                drains.removeValue(forKey: sessionId)
                drainEpochs.removeValue(forKey: sessionId)
                if dirty.contains(sessionId), hasAuthority(sessionId: sessionId) { wake(sessionId: sessionId) }
            }
        }
        while !Task.isCancelled, fence(sessionId: sessionId) == expectedFence, hasAuthority(sessionId: sessionId), let publication = publications[sessionId] {
            dirty.remove(sessionId)
            do {
                let export: ACPSessionReplicaExport?
                if let inFlight = pending[sessionId] { export = inFlight }
                else { export = try await publication.persistence.replicaChanges(sessionId: sessionId, limit: 256) }
                guard !Task.isCancelled, fence(sessionId: sessionId) == expectedFence else { return }
                guard let export else {
                    // Status transitions can happen without any transcript rows.
                    let _: RemoteSessionLease = try await call("lease/heartbeat", RemoteSessionHeartbeatParams(fence: expectedFence, status: publication.status()))
                    if dirty.contains(sessionId) { continue }
                    return
                }
                pending[sessionId] = export
                let _: RemoteSessionPublishResult = try await call("replica/publish", RemoteSessionPublishParams(fence: expectedFence, batchId: export.batchId, entries: export.entries, status: publication.status()))
                guard !Task.isCancelled, fence(sessionId: sessionId) == expectedFence else { return }
                try await publication.persistence.acknowledgeReplicaChanges(sessionId: sessionId, export: export)
                guard !Task.isCancelled, fence(sessionId: sessionId) == expectedFence else { return }
                pending.removeValue(forKey: sessionId)
            } catch {
                guard fence(sessionId: sessionId) == expectedFence else { return }
                markUnavailable(sessionId: sessionId)
                if error.isRemoteSessionLeaseLoss {
                    stopPublishing(sessionId: sessionId)
                    Task { @MainActor in await publication.onLeaseLost() }
                }
                return
            }
        }
    }

    /// A destructive lifecycle transition requires a confirmed, fully drained fence.
    @discardableResult
    func flush(sessionId: String) async -> Bool {
        guard let expectedFence = fence(sessionId: sessionId) else { return false }
        await drains[sessionId]?.value
        guard fence(sessionId: sessionId) == expectedFence else { return false }
        guard let publication = publications[sessionId] else { return hasAuthority(sessionId: sessionId) }
        if !hasAuthority(sessionId: sessionId) {
            do {
                guard try await heartbeat(sessionId: sessionId, status: publication.status()) else { return false }
            } catch {
                if fence(sessionId: sessionId) == expectedFence, error.isRemoteSessionLeaseLoss {
                    stopPublishing(sessionId: sessionId)
                    Task { await publication.onLeaseLost() }
                }
                return false
            }
        }
        guard fence(sessionId: sessionId) == expectedFence else { return false }
        wake(sessionId: sessionId)
        while let drain = drains[sessionId] {
            await drain.value
            guard fence(sessionId: sessionId) == expectedFence, hasAuthority(sessionId: sessionId) else { return false }
        }
        return fence(sessionId: sessionId) == expectedFence && hasAuthority(sessionId: sessionId)
            && pending[sessionId] == nil && !dirty.contains(sessionId)
    }

    func stopPublishing(sessionId: String) {
        publications.removeValue(forKey: sessionId)
        drains.removeValue(forKey: sessionId)?.cancel()
        drainEpochs.removeValue(forKey: sessionId)
        pending.removeValue(forKey: sessionId)
        dirty.remove(sessionId)
    }

    func syncMirror(sessionId: String, lease: RemoteSessionLease, persistence: ACPSessionPersistence, localFence: ACPSessionLeaseFence? = nil, isCurrent: @escaping @MainActor () -> Bool) async throws {
        let epoch = epochs[sessionId]
        let readEpoch = UUID()
        let predecessor = reads[sessionId]
        let task = Task { @MainActor in
            if let predecessor { _ = try? await predecessor.value }
            try Task.checkCancellation()
            guard self.epochs[sessionId] == epoch, isCurrent(), !self.isPublishing(sessionId: sessionId) else { throw CancellationError() }
            try await self.performMirrorSync(sessionId: sessionId, lease: lease, persistence: persistence, localFence: localFence, epoch: epoch, isCurrent: isCurrent)
        }
        reads[sessionId] = task
        readEpochs[sessionId] = readEpoch
        defer {
            if readEpochs[sessionId] == readEpoch { reads.removeValue(forKey: sessionId)
            readEpochs.removeValue(forKey: sessionId) }
        }
        try await task.value
    }

    private func performMirrorSync(sessionId: String, lease: RemoteSessionLease, persistence: ACPSessionPersistence, localFence: ACPSessionLeaseFence?, epoch: UUID?, isCurrent: @escaping @MainActor () -> Bool) async throws {
        // Another process on this Mac already persists into our shared database.
        if lease.owner?.serverId == owner.serverId, lease.owner?.instanceId != owner.instanceId { return }
        if locallySharedRecords.contains(lease.recordId) { return }
        guard lease.revision > 0 else { return }
        let after = try await persistence.replicaRevision(sessionId: sessionId, recordId: lease.recordId)
        guard lease.revision > after else { return }
        try await persistence.discardReplicaImport(sessionId: sessionId)
        var pageToken: String?
        do {
            repeat {
                try Task.checkCancellation()
                let page: RemoteSessionReadResult = try await call("replica/read", RemoteSessionReadParams(recordId: lease.recordId, afterRevision: after, pageToken: pageToken))
                pageToken = page.nextPageToken
                guard epochs[sessionId] == epoch, isCurrent() else { throw CancellationError() }
                try await persistence.stageReplicaPage(sessionId: sessionId, recordId: lease.recordId, page: page)
            } while pageToken != nil
            guard epochs[sessionId] == epoch, isCurrent(), !isPublishing(sessionId: sessionId) else { throw CancellationError() }
            _ = try await persistence.commitReplicaImport(importGuard: .init(sessionId: sessionId, expectedLocalFence: localFence))
        } catch {
            if let pageToken {
                let _: RemoteSessionMutationResult? = try? await call("replica/cancel", RemoteSessionCancelReadParams(pageToken: pageToken))
            }
            try? await persistence.discardReplicaImport(sessionId: sessionId)
            throw error
        }
    }

    func invalidateMirror(sessionId: String) { epochs[sessionId] = UUID() }

    func shutdown() {
        changeTask?.cancel()
        changeTask = nil
        for task in drains.values { task.cancel() }
        for task in claims.values { task.cancel() }
        for task in reads.values { task.cancel() }
        reads.removeAll()
        readEpochs.removeAll()
        claims.removeAll()
        drains.removeAll()
        publications.removeAll()
        pending.removeAll()
        dirty.removeAll()
        for id in epochs.keys { epochs[id] = UUID() }
        for id in authorities.keys { authorities[id]?.confirmed = false }
    }
}
