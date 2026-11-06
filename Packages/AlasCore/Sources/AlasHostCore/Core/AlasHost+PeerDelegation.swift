import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasACP

extension HostDelegationRequest {
    var verb: PeerDelegationVerb {
        switch self {
        case .discover: .discover
        case .start: .start
        case .send: .send
        case .read: .read
        case .status: .status
        case .interrupt: .interrupt
        case .outbox: .outbox
        }
    }
}

/// What a paired Mac's agents ask of this one. Consent follows the device that
/// asks, under `PeerDelegationGate`; a child belongs to the peer's server id,
/// so a re-paired Mac keeps its children and needs consent again for new work.
extension DelegationAPI {
    /// What a page of the outbox may encode to: a host reply's budget, less
    /// the message around the entries.
    static let outboxPageBudget = RemoteServerMessage.sendBudget - 4_096
    /// The most an encoded character can cost, as `\u0001`.
    private static let maxEncodedBytesPerByte = 6
    /// As many as one `session_wait` may name: each id costs a store read and
    /// possibly loading a transcript, and needs no consent.
    nonisolated static let maxStatusSessions = ACPDelegatedSessionWaitRequest.maxSessions
    /// A child id is stored, and echoed in every reply about the child, so it
    /// must stay small for an outbox entry to fit a frame. A UUID fits.
    nonisolated static let maxChildIDLength = 128

    nonisolated static let accessOffRefusal = "Agents on that Mac may not use this one. Allow them in this Mac's Remote settings."
    nonisolated static let notAPeerRefusal = "Only a paired Mac may delegate to this host."
    nonisolated static let unknownPeerRefusal = "This Mac does not know that Mac's identity. Pair them again to allow this."

    /// `device` is the one the transport identified for `caller`, if any.
    func serve(_ request: HostDelegationRequest, device: RemoteDevice?, caller: HostCaller) async throws -> HostResponse {
        guard PeerDelegationGate.allows(request.verb, device: device), let device else {
            throw HostError.failed(message: device?.kind == .alasInstance ? Self.accessOffRefusal : Self.notAPeerRefusal)
        }
        guard let peerServerId = device.peerServerId, !peerServerId.isEmpty else {
            throw HostError.failed(message: Self.unknownPeerRefusal)
        }
        caller.log("delegation", "\(request.verb) from \(peerServerId)")
        switch request {
        case .discover(let repository):
            return .delegation(.discovered(await discover(repository: repository, access: device.agentAccess)))
        case .start(let start):
            return .delegation(try await self.start(start, peerServerId: peerServerId, access: device.agentAccess))
        case .send(let sessionID, let prompt):
            let origin = try await peerOrigin(ofChild: sessionID, peerServerId: peerServerId)
            // Taken first: a turn this prompt starts begins no earlier.
            let acceptedAt = Int64(Date().timeIntervalSince1970 * 1000)
            _ = try Self.payload(await core.orchestration.send(
                origin: origin, request: ACPDelegatedSessionMessageRequest(targetSessionId: sessionID, prompt: prompt)
            ))
            return .delegation(.sent(acceptedAt: acceptedAt))
        case .read(let sessionID, let offset, let limit, let maxChars):
            return .delegation(.read(data: try await read(
                ACPDelegatedSessionReadRequest(
                    targetSessionId: sessionID,
                    offset: offset.map { max($0, 0) },
                    limit: min(max(limit ?? ACPDelegatedSessionReadRequest.defaultLimit, 1), ACPDelegatedSessionReadRequest.maxLimit),
                    maxChars: min(max(maxChars ?? ACPDelegatedSessionReadRequest.defaultMaxChars, 1), ACPDelegatedSessionReadRequest.maxMaxChars)
                ),
                peerServerId: peerServerId
            )))
        case .status(let sessionIDs):
            guard sessionIDs.count <= Self.maxStatusSessions else {
                throw HostError.invalidRequest(reason: "A status names at most \(Self.maxStatusSessions) sessions.")
            }
            return .delegation(.status(data: try await status(sessionIDs: sessionIDs, peerServerId: peerServerId)))
        case .interrupt(let sessionID):
            let origin = try await peerOrigin(ofChild: sessionID, peerServerId: peerServerId)
            let data = try Self.payload(await core.orchestration.interrupt(origin: origin, targetSessionId: sessionID))
            let answer = try JSONDecoder().decode(ACPOrchestrationInterruptResponse.self, from: data)
            return .delegation(.interrupted(cancelRequested: answer.cancelRequested))
        case .outbox(let after):
            let persistence = core.orchestrationPersistence
            try await persistence.acknowledgeOutbox(peerServerId: peerServerId, through: after)
            // Stored text never encodes smaller, so this holds whatever fits.
            let stored = try await persistence.outbox(peerServerId: peerServerId, after: after, maxBytes: Self.outboxPageBudget)
            let page = Self.outboxPage(stored.entries, hasMore: stored.hasMore, budget: Self.outboxPageBudget)
            return .delegation(.outbox(entries: page.entries, hasMore: page.hasMore))
        }
    }

    /// Each child's state as `session_wait` reports it, right now. An id that
    /// is not a child of this peer is reported as gone rather than failing the
    /// others; see `ACPSessionOrchestrationCoordinator.peerStatus`.
    public func status(sessionIDs: [String], peerServerId: String) async throws -> Data {
        try Self.payload(await core.orchestration.peerStatus(peerServerId: peerServerId, sessionIDs: sessionIDs))
    }

    /// One page of this peer's child's transcript, as `session_read` returns it.
    public func read(_ request: ACPDelegatedSessionReadRequest, peerServerId: String) async throws -> Data {
        let origin = try await peerOrigin(ofChild: request.targetSessionId, peerServerId: peerServerId)
        return try Self.payload(await core.orchestration.read(origin: origin, request: request))
    }

    /// The local git projects `start` could use, those whose origin is
    /// `repository` when named, with their unarchived worktrees and the agents
    /// a peer's list shows. Only a named repository reads git.
    private func discover(repository: String?, access: RemoteDeviceAgentAccess) async -> HostDelegationDiscovery {
        var projects = core.projects.projects.filter { $0.host == nil && !$0.isFolder }
        if let repository {
            let wanted = GitRemoteIdentity.normalized(repository) ?? repository
            var matching: [ProjectConfig] = []
            for project in projects where await Self.originIdentity(of: project) == wanted {
                matching.append(project)
            }
            projects = matching
        }
        let ids = Set(projects.map(\.id))
        return HostDelegationDiscovery(
            access: access,
            projects: ProjectsAPI(core: core).list().filter { ids.contains($0.id) },
            worktrees: WorktreesAPI(core: core).list().filter { ids.contains($0.worktree.projectId) },
            agents: core.remoteAgentOptions()
        )
    }

    private static func originIdentity(of project: ProjectConfig) async -> String? {
        let remotes = try? await GitService().remotes(worktreePath: URL(fileURLWithPath: project.path))
        return remotes?.first { $0.name == "origin" && $0.direction == .fetch }.flatMap { GitRemoteIdentity.normalized($0.url) }
    }

    private func start(
        _ start: HostDelegationStart, peerServerId: String, access: RemoteDeviceAgentAccess
    ) async throws -> HostDelegationResponse {
        guard Self.isValidChildID(start.childID) else {
            throw HostError.invalidRequest(reason: "That is not a child session id.")
        }
        let projectID: String
        let target: ACPPeerChildTarget
        switch start.target {
        case .worktree(let ref):
            (projectID, target) = (ref.projectID, .worktree(path: ref.path))
        case .newWorktree(let project, let branch, let base, let expectedBaseSHA):
            (projectID, target) = (project, .newWorktree(branch: branch, base: base, expectedBaseSHA: expectedBaseSHA))
        }
        let result = await core.orchestration.startForPeer(ACPPeerChildStart(
            childID: start.childID,
            peerServerId: peerServerId,
            projectID: projectID,
            target: target,
            agentID: start.agentID,
            modelSelection: ACPDelegatedModelSelection(model: start.modelID, reasoning: start.reasoning),
            role: start.role,
            autoRun: PeerDelegationGate.effectiveAutoRun(parent: start.autoRun, access: access),
            prompt: start.prompt
        ))
        switch result {
        case .started(let sessionID, let state): return .started(sessionID: sessionID, state: state)
        case .refused(let reason): throw HostError.failed(message: reason)
        }
    }

    /// Letters, digits, `-` and `_`, which also keeps out a sentinel's `peer:`.
    private static func isValidChildID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxChildIDLength && id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                true
            default:
                false
            }
        }
    }

    /// The coordinator's rules for a direct parent, which a peer's sentinel
    /// is, once the child is known to be this peer's. Any other row, or none,
    /// answers alike, so a peer cannot probe for another's children.
    private func peerOrigin(ofChild sessionID: String, peerServerId: String) async throws -> ACPOrchestrationSessionOrigin {
        guard let record = try await core.orchestrationPersistence.delegation(childSessionId: sessionID),
              ACPPeerParent.serverId(from: record.parentSessionId) == peerServerId
        else { throw SessionRefusal.notFound }
        return ACPOrchestrationSessionOrigin(
            sessionId: record.parentSessionId, projectId: record.projectId,
            worktreeId: record.childWorktreeId ?? record.parentWorktreeId
        )
    }

    /// The first entries that encode within `budget`, as JSON-encoded replies
    /// are sent. A first entry that alone exceeds it is cut, with a note.
    static func outboxPage(
        _ entries: [ACPPeerOutboxEntry], hasMore: Bool, budget: Int
    ) -> (entries: [ACPPeerOutboxEntry], hasMore: Bool) {
        let encoder = JSONEncoder()
        var page: [ACPPeerOutboxEntry] = []
        var remaining = budget
        for entry in entries {
            // The comma between entries is the one byte.
            let size = (try? encoder.encode(entry).count).map { $0 + 1 } ?? .max
            guard size <= remaining else { break }
            page.append(entry)
            remaining -= size
        }
        if page.isEmpty, let first = entries.first { page = [truncated(first, budget: budget)] }
        return (page, hasMore || page.count < entries.count)
    }

    private static func truncated(_ entry: ACPPeerOutboxEntry, budget: Int) -> ACPPeerOutboxEntry {
        let note = "\n\n[This message was too long to send in full. Read the rest with session_read on \(entry.childSessionId).]"
        // The envelope and note are small; what is kept may be all escapes.
        let kept = (budget / 2) / maxEncodedBytesPerByte
        return ACPPeerOutboxEntry(
            seq: entry.seq, messageId: entry.messageId, childSessionId: entry.childSessionId,
            prompt: String(decoding: entry.prompt.utf8.prefix(kept), as: UTF8.self) + note,
            kind: entry.kind, createdAt: entry.createdAt
        )
    }

    /// The JSON a `session_*` response carries as its one line, or its error.
    private static func payload(_ response: AlasCLIResponse) throws -> Data {
        switch response {
        case .text(let lines):
            return Data(lines.joined(separator: "\n").utf8)
        case .ok:
            return Data()
        case .error(let message), .errorWithExitCode(let message, _):
            throw HostError.failed(message: message)
        }
    }
}
