import Foundation

/// Wire protocol version advertised in `hello`. Bump only for changes an
/// older client or server cannot tolerate; additive optional fields do not
/// count.
enum RemoteProtocolVersion {
    static let current = 1
}

/// One of the sending Mac's peers, as reported in `hello` so a client can
/// render the gateway's peer list without a separate request. `state` is
/// `"online"` only when that peer's sessions are actually reachable through
/// this Mac; `"unverified"` marks a record that connects but is not pinned
/// to a proven key, and the rest mirror `RemotePeerConnection.State`.
struct RemoteHelloPeer: Codable, Equatable, Sendable {
    let serverId: String
    let name: String
    let state: String
}

/// What a Mac says about itself in the first frame of every socket.
struct RemoteServerIdentity: Equatable, Sendable {
    let serverId: String
    let name: String
    let peers: [RemoteHelloPeer]

    init(serverId: String, name: String, peers: [RemoteHelloPeer] = []) {
        self.serverId = serverId
        self.name = name
        self.peers = peers
    }
}

struct RemoteModelInfo: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct RemoteAttachment: Codable, Equatable, Sendable {
    let name: String?
    let mimeType: String
    let dataBase64: String
}

struct RemoteSessionConfig: Codable, Equatable, Sendable {
    let sessionId: String
    let models: [RemoteModelInfo]
    let modes: [RemoteModelInfo]
    let currentModel: String?
    let currentMode: String?
    let autoRunEnabled: Bool
    let acceptsImages: Bool
}

/// Client → server. `type` discriminates.
enum RemoteClientMessage: Equatable, Sendable {
    /// Sent by Alas peer connections after the server's `hello`. Browsers
    /// never send it and servers never wait for it.
    ///
    /// `challenge` is a fresh nonce the connecting peer minted for THIS
    /// socket. A peer whose record is pinned to key material sends one and
    /// refuses to go online until the answering `identityProof` verifies
    /// against that key; a browser, and a peer with nothing pinned yet,
    /// omits it and the server signs nothing.
    case helloAck(protocolVersion: Int, challenge: String? = nil)
    case listSessions
    case listWorktrees
    case listAgents
    case listProjects
    case listBranches(projectId: String)
    case createWorktreeSession(
        projectId: String, base: String, branch: String, agentId: String,
        modelId: String? = nil, effortId: String? = nil)
    case createSession(worktreeId: String, agentId: String, modelId: String? = nil, effortId: String? = nil)
    case subscribe(sessionId: String)
    case unsubscribe(sessionId: String)
    case permissionDecision(sessionId: String, requestId: Int, optionId: String, persistScope: String?)
    case questionAnswer(sessionId: String, requestId: Int, answers: [RemoteQuestionAnswer])
    case planResponse(sessionId: String, requestId: JSONRPCID, action: String, reason: String?)
    case elicitationResponse(
        sessionId: String,
        requestId: String,
        action: String,
        content: [String: ACPElicitationValue]?
    )
    case takeOver(sessionId: String)
    case sendPrompt(sessionId: String, text: String, attachments: [RemoteAttachment], intent: String)
    case stop(sessionId: String)
    case setModel(sessionId: String, modelId: String)
    case setMode(sessionId: String, modeId: String)
    case setAutoRun(sessionId: String, enabled: Bool)
    case renameSession(sessionId: String, title: String)
    case fetchOlder(sessionId: String, beforeIndex: Int, limit: Int)
    case queueForceSend(sessionId: String, itemId: String)
    case queueRemove(sessionId: String, itemId: String)
    case queueRetry(sessionId: String, itemId: String)
    case queueEdit(sessionId: String, itemId: String)
    case queueClear(sessionId: String)
    case listChanges(
        sessionId: String,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode? = nil
    )
    case fileDiff(
        sessionId: String,
        path: String,
        stage: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode? = nil
    )
    case listFiles(
        sessionId: String,
        path: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode? = nil
    )
    case listCommitFiles(sessionId: String, sha: String)
    case commitFileDiff(sessionId: String, sha: String, path: String)
    case readFile(sessionId: String, path: String)
    /// The phone's answer to a visual aid question. `action` is "answer" or
    /// "dismiss"; the gateway validates the choices against the question.
    case visualAidResponse(sessionId: String, visualId: String, action: String, selectedOptionIds: [String], note: String?)
    /// Peer console traffic; see `PeerConsoleRequest`.
    case console(PeerConsoleRequest)
}

extension RemoteClientMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, sessionId, requestId, optionId, persistScope, answers, action, reason, content, text, attachments, modelId, effortId, modeId, enabled, title, worktreeId, agentId, beforeIndex, limit, itemId, intent, projectId, base, branch, path, stage, comparisonMode, protocolVersion, challenge, sha, visualId, selectedOptionIds, note, console }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "helloAck":
            self = .helloAck(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                challenge: try c.decodeIfPresent(String.self, forKey: .challenge))
        case "listSessions": self = .listSessions
        case "listWorktrees": self = .listWorktrees
        case "listAgents": self = .listAgents
        case "listProjects": self = .listProjects
        case "listBranches":
            self = .listBranches(projectId: try c.decode(String.self, forKey: .projectId))
        case "createWorktreeSession":
            self = .createWorktreeSession(
                projectId: try c.decode(String.self, forKey: .projectId),
                base: try c.decode(String.self, forKey: .base),
                branch: try c.decode(String.self, forKey: .branch),
                agentId: try c.decode(String.self, forKey: .agentId),
                modelId: try c.decodeIfPresent(String.self, forKey: .modelId),
                effortId: try c.decodeIfPresent(String.self, forKey: .effortId))
        case "createSession":
            self = .createSession(
                worktreeId: try c.decode(String.self, forKey: .worktreeId),
                agentId: try c.decode(String.self, forKey: .agentId),
                modelId: try c.decodeIfPresent(String.self, forKey: .modelId),
                effortId: try c.decodeIfPresent(String.self, forKey: .effortId))
        case "subscribe": self = .subscribe(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "unsubscribe": self = .unsubscribe(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "permissionDecision":
            self = .permissionDecision(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(Int.self, forKey: .requestId),
                optionId: try c.decode(String.self, forKey: .optionId),
                persistScope: try c.decodeIfPresent(String.self, forKey: .persistScope))
        case "questionAnswer":
            self = .questionAnswer(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(Int.self, forKey: .requestId),
                answers: try c.decode([RemoteQuestionAnswer].self, forKey: .answers))
        case "visualAidResponse":
            self = .visualAidResponse(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                visualId: try c.decode(String.self, forKey: .visualId),
                action: try c.decode(String.self, forKey: .action),
                selectedOptionIds: try c.decodeIfPresent([String].self, forKey: .selectedOptionIds) ?? [],
                note: try c.decodeIfPresent(String.self, forKey: .note))
        case "planResponse":
            self = .planResponse(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(JSONRPCID.self, forKey: .requestId),
                action: try c.decode(String.self, forKey: .action),
                reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "elicitationResponse":
            self = .elicitationResponse(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(String.self, forKey: .requestId),
                action: try c.decode(String.self, forKey: .action),
                content: try c.decodeIfPresent(
                    [String: ACPElicitationValue].self,
                    forKey: .content
                )
            )
        case "takeOver":
            self = .takeOver(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "sendPrompt":
            self = .sendPrompt(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                text: try c.decode(String.self, forKey: .text),
                attachments: try c.decodeIfPresent([RemoteAttachment].self, forKey: .attachments) ?? [],
                // Absent on clients cached before queue parity shipped; those
                // clients only ever meant "auto".
                intent: try c.decodeIfPresent(String.self, forKey: .intent) ?? "auto")
        case "stop":
            self = .stop(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "setModel":
            self = .setModel(sessionId: try c.decode(String.self, forKey: .sessionId), modelId: try c.decode(String.self, forKey: .modelId))
        case "setMode":
            self = .setMode(sessionId: try c.decode(String.self, forKey: .sessionId), modeId: try c.decode(String.self, forKey: .modeId))
        case "setAutoRun":
            self = .setAutoRun(sessionId: try c.decode(String.self, forKey: .sessionId), enabled: try c.decode(Bool.self, forKey: .enabled))
        case "renameSession":
            self = .renameSession(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                title: try c.decode(String.self, forKey: .title))
        case "fetchOlder":
            self = .fetchOlder(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                beforeIndex: try c.decode(Int.self, forKey: .beforeIndex),
                limit: try c.decode(Int.self, forKey: .limit))
        case "queueForceSend":
            self = .queueForceSend(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId))
        case "queueRemove":
            self = .queueRemove(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId))
        case "queueRetry":
            self = .queueRetry(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId))
        case "queueEdit":
            self = .queueEdit(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId))
        case "queueClear":
            self = .queueClear(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "listChanges":
            self = .listChanges(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                comparisonMode: try c.decodeIfPresent(
                    AppConfig.Changes.ChangesComparisonMode.self,
                    forKey: .comparisonMode
                )
            )
        case "fileDiff":
            self = .fileDiff(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                stage: try c.decodeIfPresent(String.self, forKey: .stage),
                comparisonMode: try c.decodeIfPresent(
                    AppConfig.Changes.ChangesComparisonMode.self,
                    forKey: .comparisonMode
                )
            )
        case "listFiles":
            self = .listFiles(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                comparisonMode: try c.decodeIfPresent(
                    AppConfig.Changes.ChangesComparisonMode.self,
                    forKey: .comparisonMode
                )
            )
        case "listCommitFiles":
            self = .listCommitFiles(sessionId: try c.decode(String.self, forKey: .sessionId),
                                    sha: try c.decode(String.self, forKey: .sha))
        case "commitFileDiff":
            self = .commitFileDiff(sessionId: try c.decode(String.self, forKey: .sessionId),
                                   sha: try c.decode(String.self, forKey: .sha),
                                   path: try c.decode(String.self, forKey: .path))
        case "readFile":
            self = .readFile(sessionId: try c.decode(String.self, forKey: .sessionId),
                             path: try c.decode(String.self, forKey: .path))
        case "console":
            self = .console(try c.decode(PeerConsoleRequest.self, forKey: .console))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .helloAck(let protocolVersion, let challenge):
            try c.encode("helloAck", forKey: .type)
            try c.encodeIfPresent(challenge, forKey: .challenge)
            try c.encode(protocolVersion, forKey: .protocolVersion)
        case .listSessions: try c.encode("listSessions", forKey: .type)
        case .listWorktrees:
            try c.encode("listWorktrees", forKey: .type)
        case .listAgents:
            try c.encode("listAgents", forKey: .type)
        case .listProjects:
            try c.encode("listProjects", forKey: .type)
        case .listBranches(let projectId):
            try c.encode("listBranches", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
        case .createWorktreeSession(let projectId, let base, let branch, let agentId, let modelId, let effortId):
            try c.encode("createWorktreeSession", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(base, forKey: .base)
            try c.encode(branch, forKey: .branch)
            try c.encode(agentId, forKey: .agentId)
            try c.encodeIfPresent(modelId, forKey: .modelId)
            try c.encodeIfPresent(effortId, forKey: .effortId)
        case .createSession(let worktreeId, let agentId, let modelId, let effortId):
            try c.encode("createSession", forKey: .type)
            try c.encode(worktreeId, forKey: .worktreeId)
            try c.encode(agentId, forKey: .agentId)
            try c.encodeIfPresent(modelId, forKey: .modelId)
            try c.encodeIfPresent(effortId, forKey: .effortId)
        case .subscribe(let s): try c.encode("subscribe", forKey: .type)
        try c.encode(s, forKey: .sessionId)
        case .unsubscribe(let s): try c.encode("unsubscribe", forKey: .type)
        try c.encode(s, forKey: .sessionId)
        case .permissionDecision(let s, let r, let o, let p):
            try c.encode("permissionDecision", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
            try c.encode(o, forKey: .optionId)
            try c.encodeIfPresent(p, forKey: .persistScope)
        case .questionAnswer(let s, let r, let a):
            try c.encode("questionAnswer", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
            try c.encode(a, forKey: .answers)
        case .visualAidResponse(let s, let v, let a, let ids, let n):
            try c.encode("visualAidResponse", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(v, forKey: .visualId)
            try c.encode(a, forKey: .action)
            try c.encode(ids, forKey: .selectedOptionIds)
            try c.encodeIfPresent(n, forKey: .note)
        case .planResponse(let s, let r, let action, let reason):
            try c.encode("planResponse", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .elicitationResponse(let s, let r, let action, let content):
            try c.encode("elicitationResponse", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(content, forKey: .content)
        case .takeOver(let s):
            try c.encode("takeOver", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .sendPrompt(let s, let t, let a, let intent):
            try c.encode("sendPrompt", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(t, forKey: .text)
            try c.encode(a, forKey: .attachments)
            try c.encode(intent, forKey: .intent)
        case .stop(let s):
            try c.encode("stop", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .setModel(let id, let m):
            try c.encode("setModel", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(m, forKey: .modelId)
        case .setMode(let id, let m):
            try c.encode("setMode", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(m, forKey: .modeId)
        case .setAutoRun(let id, let e):
            try c.encode("setAutoRun", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(e, forKey: .enabled)
        case .renameSession(let id, let title):
            try c.encode("renameSession", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(title, forKey: .title)
        case .fetchOlder(let id, let beforeIndex, let limit):
            try c.encode("fetchOlder", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(beforeIndex, forKey: .beforeIndex)
            try c.encode(limit, forKey: .limit)
        case .queueForceSend(let s, let itemId):
            try c.encode("queueForceSend", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(itemId, forKey: .itemId)
        case .queueRemove(let s, let itemId):
            try c.encode("queueRemove", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(itemId, forKey: .itemId)
        case .queueRetry(let s, let itemId):
            try c.encode("queueRetry", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(itemId, forKey: .itemId)
        case .queueEdit(let s, let itemId):
            try c.encode("queueEdit", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(itemId, forKey: .itemId)
        case .queueClear(let s):
            try c.encode("queueClear", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .listChanges(let s, let comparisonMode):
            try c.encode("listChanges", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(comparisonMode, forKey: .comparisonMode)
        case .fileDiff(let s, let path, let stage, let comparisonMode):
            try c.encode("fileDiff", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(stage, forKey: .stage)
            try c.encodeIfPresent(comparisonMode, forKey: .comparisonMode)
        case .listFiles(let s, let path, let comparisonMode):
            try c.encode("listFiles", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(comparisonMode, forKey: .comparisonMode)
        case .listCommitFiles(let s, let sha):
            try c.encode("listCommitFiles", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(sha, forKey: .sha)
        case .commitFileDiff(let s, let sha, let path):
            try c.encode("commitFileDiff", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(sha, forKey: .sha)
            try c.encode(path, forKey: .path)
        case .readFile(let s, let path):
            try c.encode("readFile", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
        case .console(let request):
            try c.encode("console", forKey: .type)
            try c.encode(request, forKey: .console)
        }
    }
}

extension RemoteClientMessage {
    /// Control messages bypass the per-connection serial processing chain
    /// (RemoteConnection.dispatchMessage): they are idempotent and must not
    /// queue behind transcript work. Everything else stays strictly ordered
    /// (e.g. takeOver-before-sendPrompt).
    var isControl: Bool {
        if case .stop = self { return true }
        return false
    }

    /// Dedup key for the read-only file-request verbs, matching
    /// `RemoteSessionGateway`'s own per-verb key shape (kept identical so
    /// the two dedup layers agree on identity). `nil` for every other
    /// message.
    ///
    /// `RemoteConnection.dispatchMessage` checks this BEFORE enqueueing into
    /// the per-connection processing chain: these verbs are not `isControl`,
    /// so they're always serialized behind `processingTail` like any other
    /// ordered message — by the time a duplicate's `handle` call would run,
    /// the original's has already completed and released its key, so a
    /// dedup guard that only lives inside `handle` never actually rejects
    /// anything for a real client. Checking here, at enqueue time, catches a
    /// duplicate that arrives while the original is still queued or
    /// in-flight, before it wastes a spot in the ordered chain (and,
    /// downstream, a git process) on a request that will show identical
    /// results to the one already running.
    var fileRequestDedupKey: String? {
        switch self {
        case .listChanges(let sessionId, let comparisonMode):
            if let comparisonMode {
                return "listChanges\u{0}\(sessionId)\u{0}\(comparisonMode.rawValue)"
            }
            return "listChanges\u{0}\(sessionId)"
        case .fileDiff(let sessionId, let path, let stage, let comparisonMode):
            if let comparisonMode {
                return "fileDiff\u{0}\(sessionId)\u{0}\(path)\u{0}\(stage ?? "")\u{0}\(comparisonMode.rawValue)"
            }
            return "fileDiff\u{0}\(sessionId)\u{0}\(path)\u{0}\(stage ?? "")"
        case .listFiles(let sessionId, let path, let comparisonMode):
            if let comparisonMode {
                return "listFiles\u{0}\(sessionId)\u{0}\(path ?? "")\u{0}\(comparisonMode.rawValue)"
            }
            return "listFiles\u{0}\(sessionId)\u{0}\(path ?? "")"
        case .listCommitFiles(let sessionId, let sha):
            return "listCommitFiles\u{0}\(sessionId)\u{0}\(sha)"
        case .commitFileDiff(let sessionId, let sha, let path):
            return "commitFileDiff\u{0}\(sessionId)\u{0}\(sha)\u{0}\(path)"
        case .readFile(let sessionId, let path):
            return "readFile\u{0}\(sessionId)\u{0}\(path)"
        default:
            return nil
        }
    }

    /// Messages that establish or change which turn is active (answering a
    /// visual aid starts one with its prompt; dismissing one sends nothing),
    /// and so a
    /// following `stop` must wait for them specifically (not the whole
    /// ordered queue) before running — otherwise stop could land before a
    /// still-in-flight `sendPrompt`/`takeOver` finishes, find no active turn
    /// to cancel, and the turn the user just started would proceed anyway
    /// right after they pressed Stop. Read/list/config verbs are excluded so
    /// stop stays fast when a client is simply scrolled up mid-backfill.
    var isDriveOrdering: Bool {
        switch self {
        case .visualAidResponse(_, _, let action, _, _):
            return action == "answer"
        case .sendPrompt, .takeOver,
             .queueForceSend, .queueRemove, .queueRetry, .queueEdit,
             .queueClear:
            return true
        default: return false
        }
    }
}

/// Server → client. `type` discriminates.
enum RemoteServerMessage: Equatable, Sendable {
    /// First frame after a successful upgrade, before any reply.
    /// `capabilities` lists optional features this Mac serves, such as
    /// `PeerConsoleCapability.v1`; absent on older Macs.
    case hello(protocolVersion: Int, serverId: String, name: String,
               federationEnabled: Bool = false, peers: [RemoteHelloPeer] = [], capabilities: [String] = [])
    /// Answer to a `helloAck` that carried a challenge: this Mac's public
    /// key and a signature over the asking peer's own nonce. Sent on the
    /// socket that will carry traffic, so what is proved is the identity of
    /// whoever is actually on the other end of THIS connection — not of
    /// whatever answered a side-channel probe.
    case identityProof(challenge: String, publicKey: String, signature: String)
    case sessionList(sessions: [RemoteSessionSummary])
    case worktreeList(worktrees: [RemoteWorktreeOption])
    case agentList(agents: [RemoteAgentOption])
    case projectList(projects: [RemoteProjectOption])
    case branchList(projectId: String, branches: [String], preferredBase: String)
    case branchListFailed(projectId: String, message: String)
    case worktreeSessionCreated(session: RemoteSessionSummary)
    case worktreeSessionCreationFailed(stage: RemoteWorktreeSessionCreationStage, message: String, worktreeId: String?)
    case sessionCreated(session: RemoteSessionSummary)
    case createSessionFailed(message: String)
    case transcriptSnapshot(
        sessionId: String, streamingState: String, canDrive: Bool, messages: [RemoteWireMessage],
        firstIndex: Int, totalCount: Int, epoch: Int, revision: Int, hasCancellableBackgroundWork: Bool = false)
    case transcriptDelta(
        sessionId: String, streamingState: String, canDrive: Bool, upserts: [RemoteWireMessage],
        epoch: Int, revision: Int, hasCancellableBackgroundWork: Bool = false)
    case transcriptPage(sessionId: String, epoch: Int, firstIndex: Int, messages: [RemoteWireMessage])
    case stopPending(sessionId: String)
    case permissionRequest(sessionId: String, payload: RemotePermissionPayload)
    case permissionResolved(sessionId: String, requestId: Int)
    case questionRequest(sessionId: String, payload: RemoteQuestionPayload)
    case questionResolved(sessionId: String, requestId: Int)
    case planRequest(sessionId: String, payload: RemotePlanPayload)
    case planResolved(sessionId: String, requestId: JSONRPCID)
    case elicitationRequest(sessionId: String, payload: RemoteElicitationPayload)
    case elicitationResolved(sessionId: String, requestId: String)
    case sessionClosed(sessionId: String)
    /// The server dropped a `sendPrompt` (caller is no longer the writer, or
    /// the prompt was empty), so the client should restore the user's text
    /// instead of silently losing it.
    case promptRejected(sessionId: String)
    /// The server refused a `visualAidResponse` (reason: notWriter, notFound,
    /// alreadyAnswered, invalid or failed), so the phone re-enables the card.
    case visualAidRejected(sessionId: String, visualId: String, reason: String)
    case sessionConfig(RemoteSessionConfig)
    case sessionRenamed(sessionId: String, title: String)
    case queueState(sessionId: String, items: [RemoteQueuedPrompt])
    case queueEditRestored(sessionId: String, itemId: String, text: String)
    /// `sessionId` is set when the error is about a specific session (e.g. a
    /// failed rename), so a gateway forwarding it from a peer's home Mac can
    /// route it back to whichever federated client asked — an unscoped error
    /// has nowhere to be routed and is only ever shown on the connection that
    /// triggered it. Nil for every non-session-specific error.
    case error(message: String, sessionId: String? = nil)
    case changeList(
        sessionId: String, comparisonRef: String?, metricsAvailable: Bool,
        files: [RemoteChangedFile], staged: [RemoteChangedFile], unstaged: [RemoteChangedFile],
        commits: [RemoteCommit], truncated: Bool, commitsTruncated: Bool = false)
    case changeListFailed(sessionId: String, reason: RemoteFileAccessReason, message: String?)
    case fileDiffResult(
        sessionId: String, path: String, stage: String? = nil, hunks: [RemoteDiffHunk], truncated: Bool,
        metadataNote: String? = nil)
    case fileDiffFailed(sessionId: String, path: String, stage: String? = nil, reason: RemoteFileAccessReason, message: String?)
    case commitFiles(sessionId: String, sha: String, files: [RemoteChangedFile], truncated: Bool)
    case commitFilesFailed(sessionId: String, sha: String, reason: RemoteFileAccessReason, message: String?)
    case commitDiffResult(sessionId: String, sha: String, path: String, hunks: [RemoteDiffHunk], truncated: Bool,
                          metadataNote: String? = nil)
    case commitDiffFailed(sessionId: String, sha: String, path: String, reason: RemoteFileAccessReason, message: String?)
    case fileTree(sessionId: String, path: String?, nodes: [RemoteFileNode], truncated: Bool)
    case fileTreeFailed(sessionId: String, path: String?, reason: RemoteFileAccessReason, message: String?)
    case fileContents(sessionId: String, path: String, text: String, truncated: Bool)
    case fileUnavailable(
        sessionId: String, path: String, reason: RemoteFileAccessReason,
        byteSize: Int?, message: String?)
    /// Peer console traffic; see `PeerConsoleEvent`.
    case console(PeerConsoleEvent)
}

extension RemoteServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, sessions, sessionId, projectId, streamingState, canDrive, messages, upserts, payload, requestId, message
        case hasCancellableBackgroundWork
        case worktrees, agents, session, projects, branches, preferredBase, stage, worktreeId
        case models, modes, currentModel, currentMode, autoRunEnabled, acceptsImages, title
        case firstIndex, totalCount, epoch, revision
        case items, itemId, text
        case path, files, staged, unstaged, commits, comparisonRef, metricsAvailable, truncated, hunks, nodes, reason, byteSize
        case metadataNote, commitsTruncated, sha
        case protocolVersion, serverId, name, hubEnabled, federationEnabled, peers, capabilities, console
        case challenge, publicKey, signature
        case visualId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                serverId: try c.decode(String.self, forKey: .serverId),
                name: try c.decode(String.self, forKey: .name),
                federationEnabled: try c.decodeIfPresent(Bool.self, forKey: .federationEnabled) ?? false,
                peers: try c.decodeIfPresent([RemoteHelloPeer].self, forKey: .peers) ?? [],
                capabilities: try c.decodeIfPresent([String].self, forKey: .capabilities) ?? [])
        case "console":
            self = .console(try c.decode(PeerConsoleEvent.self, forKey: .console))
        case "identityProof":
            self = .identityProof(
                challenge: try c.decode(String.self, forKey: .challenge),
                publicKey: try c.decode(String.self, forKey: .publicKey),
                signature: try c.decode(String.self, forKey: .signature))
        case "sessionList": self = .sessionList(sessions: try c.decode([RemoteSessionSummary].self, forKey: .sessions))
        case "worktreeList":
            self = .worktreeList(worktrees: try c.decode([RemoteWorktreeOption].self, forKey: .worktrees))
        case "agentList":
            self = .agentList(agents: try c.decode([RemoteAgentOption].self, forKey: .agents))
        case "projectList":
            self = .projectList(projects: try c.decode([RemoteProjectOption].self, forKey: .projects))
        case "branchList":
            self = .branchList(
                projectId: try c.decode(String.self, forKey: .projectId),
                branches: try c.decode([String].self, forKey: .branches),
                preferredBase: try c.decode(String.self, forKey: .preferredBase))
        case "branchListFailed":
            self = .branchListFailed(
                projectId: try c.decode(String.self, forKey: .projectId),
                message: try c.decode(String.self, forKey: .message))
        case "worktreeSessionCreated":
            self = .worktreeSessionCreated(session: try c.decode(RemoteSessionSummary.self, forKey: .session))
        case "worktreeSessionCreationFailed":
            self = .worktreeSessionCreationFailed(
                stage: try c.decode(RemoteWorktreeSessionCreationStage.self, forKey: .stage),
                message: try c.decode(String.self, forKey: .message),
                worktreeId: try c.decodeIfPresent(String.self, forKey: .worktreeId))
        case "sessionCreated":
            self = .sessionCreated(session: try c.decode(RemoteSessionSummary.self, forKey: .session))
        case "createSessionFailed":
            self = .createSessionFailed(message: try c.decode(String.self, forKey: .message))
        case "transcriptSnapshot":
            self = .transcriptSnapshot(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                streamingState: try c.decode(String.self, forKey: .streamingState),
                canDrive: try c.decode(Bool.self, forKey: .canDrive),
                messages: try c.decode([RemoteWireMessage].self, forKey: .messages),
                firstIndex: try c.decode(Int.self, forKey: .firstIndex),
                totalCount: try c.decode(Int.self, forKey: .totalCount),
                epoch: try c.decode(Int.self, forKey: .epoch),
                revision: try c.decode(Int.self, forKey: .revision),
                hasCancellableBackgroundWork: try c.decodeIfPresent(Bool.self, forKey: .hasCancellableBackgroundWork) ?? false)
        case "transcriptDelta":
            self = .transcriptDelta(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                streamingState: try c.decode(String.self, forKey: .streamingState),
                canDrive: try c.decode(Bool.self, forKey: .canDrive),
                upserts: try c.decode([RemoteWireMessage].self, forKey: .upserts),
                epoch: try c.decode(Int.self, forKey: .epoch),
                revision: try c.decode(Int.self, forKey: .revision),
                hasCancellableBackgroundWork: try c.decodeIfPresent(Bool.self, forKey: .hasCancellableBackgroundWork) ?? false)
        case "transcriptPage":
            self = .transcriptPage(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                epoch: try c.decode(Int.self, forKey: .epoch),
                firstIndex: try c.decode(Int.self, forKey: .firstIndex),
                messages: try c.decode([RemoteWireMessage].self, forKey: .messages))
        case "stopPending":
            self = .stopPending(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "permissionRequest":
            self = .permissionRequest(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                payload: try c.decode(RemotePermissionPayload.self, forKey: .payload))
        case "permissionResolved":
            self = .permissionResolved(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(Int.self, forKey: .requestId))
        case "questionRequest":
            self = .questionRequest(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                payload: try c.decode(RemoteQuestionPayload.self, forKey: .payload))
        case "questionResolved":
            self = .questionResolved(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(Int.self, forKey: .requestId))
        case "planRequest":
            self = .planRequest(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                payload: try c.decode(RemotePlanPayload.self, forKey: .payload))
        case "planResolved":
            self = .planResolved(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(JSONRPCID.self, forKey: .requestId))
        case "elicitationRequest":
            self = .elicitationRequest(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                payload: try c.decode(RemoteElicitationPayload.self, forKey: .payload)
            )
        case "elicitationResolved":
            self = .elicitationResolved(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(String.self, forKey: .requestId)
            )
        case "sessionClosed": self = .sessionClosed(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "visualAidRejected":
            self = .visualAidRejected(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                visualId: try c.decode(String.self, forKey: .visualId),
                reason: try c.decode(String.self, forKey: .reason))
        case "promptRejected": self = .promptRejected(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "sessionConfig":
            self = .sessionConfig(RemoteSessionConfig(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                models: try c.decode([RemoteModelInfo].self, forKey: .models),
                modes: try c.decode([RemoteModelInfo].self, forKey: .modes),
                currentModel: try c.decodeIfPresent(String.self, forKey: .currentModel),
                currentMode: try c.decodeIfPresent(String.self, forKey: .currentMode),
                autoRunEnabled: try c.decode(Bool.self, forKey: .autoRunEnabled),
                acceptsImages: try c.decode(Bool.self, forKey: .acceptsImages)))
        case "sessionRenamed":
            self = .sessionRenamed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                title: try c.decode(String.self, forKey: .title))
        case "queueState":
            self = .queueState(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                items: try c.decode([RemoteQueuedPrompt].self, forKey: .items))
        case "queueEditRestored":
            self = .queueEditRestored(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId),
                text: try c.decode(String.self, forKey: .text))
        case "error":
            self = .error(
                message: try c.decode(String.self, forKey: .message),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId))
        case "changeList":
            self = .changeList(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                comparisonRef: try c.decodeIfPresent(String.self, forKey: .comparisonRef),
                metricsAvailable: try c.decode(Bool.self, forKey: .metricsAvailable),
                files: try c.decode([RemoteChangedFile].self, forKey: .files),
                staged: try c.decodeIfPresent([RemoteChangedFile].self, forKey: .staged) ?? [],
                unstaged: try c.decodeIfPresent([RemoteChangedFile].self, forKey: .unstaged) ?? [],
                commits: try c.decodeIfPresent([RemoteCommit].self, forKey: .commits) ?? [],
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
                commitsTruncated: try c.decodeIfPresent(Bool.self, forKey: .commitsTruncated) ?? false)
        case "changeListFailed":
            self = .changeListFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileDiffResult":
            self = .fileDiffResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                stage: try c.decodeIfPresent(String.self, forKey: .stage),
                hunks: try c.decode([RemoteDiffHunk].self, forKey: .hunks),
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
                metadataNote: try c.decodeIfPresent(String.self, forKey: .metadataNote))
        case "fileDiffFailed":
            self = .fileDiffFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                stage: try c.decodeIfPresent(String.self, forKey: .stage),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "commitFiles":
            self = .commitFiles(sessionId: try c.decode(String.self, forKey: .sessionId),
                sha: try c.decode(String.self, forKey: .sha),
                files: try c.decode([RemoteChangedFile].self, forKey: .files),
                truncated: try c.decode(Bool.self, forKey: .truncated))
        case "commitFilesFailed":
            self = .commitFilesFailed(sessionId: try c.decode(String.self, forKey: .sessionId),
                sha: try c.decode(String.self, forKey: .sha),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "commitDiffResult":
            self = .commitDiffResult(sessionId: try c.decode(String.self, forKey: .sessionId),
                sha: try c.decode(String.self, forKey: .sha), path: try c.decode(String.self, forKey: .path),
                hunks: try c.decode([RemoteDiffHunk].self, forKey: .hunks),
                truncated: try c.decode(Bool.self, forKey: .truncated),
                metadataNote: try c.decodeIfPresent(String.self, forKey: .metadataNote))
        case "commitDiffFailed":
            self = .commitDiffFailed(sessionId: try c.decode(String.self, forKey: .sessionId),
                sha: try c.decode(String.self, forKey: .sha), path: try c.decode(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileTree":
            self = .fileTree(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                nodes: try c.decode([RemoteFileNode].self, forKey: .nodes),
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "fileTreeFailed":
            self = .fileTreeFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileContents":
            self = .fileContents(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                text: try c.decode(String.self, forKey: .text),
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "fileUnavailable":
            self = .fileUnavailable(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                byteSize: try c.decodeIfPresent(Int.self, forKey: .byteSize),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let protocolVersion, let serverId, let name, let federationEnabled, let peers, let capabilities):
            try c.encode("hello", forKey: .type)
            try c.encode(protocolVersion, forKey: .protocolVersion)
            try c.encode(serverId, forKey: .serverId)
            try c.encode(name, forKey: .name)
            // Older remote web clients use this wire field to reveal the hub UI.
            try c.encode(true, forKey: .hubEnabled)
            try c.encode(federationEnabled, forKey: .federationEnabled)
            if !peers.isEmpty { try c.encode(peers, forKey: .peers) }
            if !capabilities.isEmpty { try c.encode(capabilities, forKey: .capabilities) }
        case .console(let event):
            try c.encode("console", forKey: .type)
            try c.encode(event, forKey: .console)
        case .identityProof(let challenge, let publicKey, let signature):
            try c.encode("identityProof", forKey: .type)
            try c.encode(challenge, forKey: .challenge)
            try c.encode(publicKey, forKey: .publicKey)
            try c.encode(signature, forKey: .signature)
        case .sessionList(let s): try c.encode("sessionList", forKey: .type)
        try c.encode(s, forKey: .sessions)
        case .worktreeList(let worktrees):
            try c.encode("worktreeList", forKey: .type)
            try c.encode(worktrees, forKey: .worktrees)
        case .agentList(let agents):
            try c.encode("agentList", forKey: .type)
            try c.encode(agents, forKey: .agents)
        case .projectList(let projects):
            try c.encode("projectList", forKey: .type)
            try c.encode(projects, forKey: .projects)
        case .branchList(let projectId, let branches, let preferredBase):
            try c.encode("branchList", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(branches, forKey: .branches)
            try c.encode(preferredBase, forKey: .preferredBase)
        case .branchListFailed(let projectId, let message):
            try c.encode("branchListFailed", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(message, forKey: .message)
        case .worktreeSessionCreated(let session):
            try c.encode("worktreeSessionCreated", forKey: .type)
            try c.encode(session, forKey: .session)
        case .worktreeSessionCreationFailed(let stage, let message, let worktreeId):
            try c.encode("worktreeSessionCreationFailed", forKey: .type)
            try c.encode(stage, forKey: .stage)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(worktreeId, forKey: .worktreeId)
        case .sessionCreated(let session):
            try c.encode("sessionCreated", forKey: .type)
            try c.encode(session, forKey: .session)
        case .createSessionFailed(let message):
            try c.encode("createSessionFailed", forKey: .type)
            try c.encode(message, forKey: .message)
        case .transcriptSnapshot(let id, let st, let cd, let m, let firstIndex, let totalCount, let epoch, let revision, let backgroundWork):
            try c.encode("transcriptSnapshot", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(st, forKey: .streamingState)
            try c.encode(cd, forKey: .canDrive)
            try c.encode(backgroundWork, forKey: .hasCancellableBackgroundWork)
            try c.encode(m, forKey: .messages)
            try c.encode(firstIndex, forKey: .firstIndex)
            try c.encode(totalCount, forKey: .totalCount)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(revision, forKey: .revision)
        case .transcriptDelta(let id, let st, let cd, let u, let epoch, let revision, let backgroundWork):
            try c.encode("transcriptDelta", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(st, forKey: .streamingState)
            try c.encode(cd, forKey: .canDrive)
            try c.encode(backgroundWork, forKey: .hasCancellableBackgroundWork)
            try c.encode(u, forKey: .upserts)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(revision, forKey: .revision)
        case .transcriptPage(let id, let epoch, let firstIndex, let m):
            try c.encode("transcriptPage", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(firstIndex, forKey: .firstIndex)
            try c.encode(m, forKey: .messages)
        case .stopPending(let id):
            try c.encode("stopPending", forKey: .type)
            try c.encode(id, forKey: .sessionId)
        case .permissionRequest(let id, let p):
            try c.encode("permissionRequest", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(p, forKey: .payload)
        case .permissionResolved(let id, let r):
            try c.encode("permissionResolved", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
        case .questionRequest(let id, let p):
            try c.encode("questionRequest", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(p, forKey: .payload)
        case .questionResolved(let id, let r):
            try c.encode("questionResolved", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(r, forKey: .requestId)
        case .planRequest(let id, let payload):
            try c.encode("planRequest", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(payload, forKey: .payload)
        case .planResolved(let id, let requestId):
            try c.encode("planResolved", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(requestId, forKey: .requestId)
        case .elicitationRequest(let id, let payload):
            try c.encode("elicitationRequest", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(payload, forKey: .payload)
        case .elicitationResolved(let id, let requestId):
            try c.encode("elicitationResolved", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(requestId, forKey: .requestId)
        case .sessionClosed(let id): try c.encode("sessionClosed", forKey: .type)
        try c.encode(id, forKey: .sessionId)
        case .promptRejected(let id): try c.encode("promptRejected", forKey: .type)
        try c.encode(id, forKey: .sessionId)
        case .visualAidRejected(let s, let v, let r):
            try c.encode("visualAidRejected", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(v, forKey: .visualId)
            try c.encode(r, forKey: .reason)
        case .sessionConfig(let cfg):
            try c.encode("sessionConfig", forKey: .type)
            try c.encode(cfg.sessionId, forKey: .sessionId)
            try c.encode(cfg.models, forKey: .models)
            try c.encode(cfg.modes, forKey: .modes)
            try c.encodeIfPresent(cfg.currentModel, forKey: .currentModel)
            try c.encodeIfPresent(cfg.currentMode, forKey: .currentMode)
            try c.encode(cfg.autoRunEnabled, forKey: .autoRunEnabled)
            try c.encode(cfg.acceptsImages, forKey: .acceptsImages)
        case .sessionRenamed(let id, let title):
            try c.encode("sessionRenamed", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(title, forKey: .title)
        case .queueState(let id, let items):
            try c.encode("queueState", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(items, forKey: .items)
        case .queueEditRestored(let id, let itemId, let text):
            try c.encode("queueEditRestored", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(itemId, forKey: .itemId)
            try c.encode(text, forKey: .text)
        case .error(let m, let sessionId): try c.encode("error", forKey: .type)
        try c.encode(m, forKey: .message)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        case .changeList(let s, let ref, let available, let files, let staged, let unstaged, let commits, let truncated, let commitsTruncated):
            try c.encode("changeList", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(ref, forKey: .comparisonRef)
            try c.encode(available, forKey: .metricsAvailable)
            try c.encode(files, forKey: .files)
            try c.encode(staged, forKey: .staged)
            try c.encode(unstaged, forKey: .unstaged)
            try c.encode(commits, forKey: .commits)
            try c.encode(truncated, forKey: .truncated)
            try c.encode(commitsTruncated, forKey: .commitsTruncated)
        case .changeListFailed(let s, let reason, let message):
            try c.encode("changeListFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileDiffResult(let s, let path, let stage, let hunks, let truncated, let metadataNote):
            try c.encode("fileDiffResult", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(stage, forKey: .stage)
            try c.encode(hunks, forKey: .hunks)
            try c.encode(truncated, forKey: .truncated)
            try c.encodeIfPresent(metadataNote, forKey: .metadataNote)
        case .fileDiffFailed(let s, let path, let stage, let reason, let message):
            try c.encode("fileDiffFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(stage, forKey: .stage)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .commitFiles(let s, let sha, let files, let truncated):
            try c.encode("commitFiles", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(sha, forKey: .sha)
            try c.encode(files, forKey: .files)
            try c.encode(truncated, forKey: .truncated)
        case .commitFilesFailed(let s, let sha, let reason, let message):
            try c.encode("commitFilesFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(sha, forKey: .sha)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .commitDiffResult(let s, let sha, let path, let hunks, let truncated, let metadataNote):
            try c.encode("commitDiffResult", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(sha, forKey: .sha)
            try c.encode(path, forKey: .path)
            try c.encode(hunks, forKey: .hunks)
            try c.encode(truncated, forKey: .truncated)
            try c.encodeIfPresent(metadataNote, forKey: .metadataNote)
        case .commitDiffFailed(let s, let sha, let path, let reason, let message):
            try c.encode("commitDiffFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(sha, forKey: .sha)
            try c.encode(path, forKey: .path)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileTree(let s, let path, let nodes, let truncated):
            try c.encode("fileTree", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(nodes, forKey: .nodes)
            try c.encode(truncated, forKey: .truncated)
        case .fileTreeFailed(let s, let path, let reason, let message):
            try c.encode("fileTreeFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileContents(let s, let path, let text, let truncated):
            try c.encode("fileContents", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(text, forKey: .text)
            try c.encode(truncated, forKey: .truncated)
        case .fileUnavailable(let s, let path, let reason, let byteSize, let message):
            try c.encode("fileUnavailable", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(byteSize, forKey: .byteSize)
            try c.encodeIfPresent(message, forKey: .message)
        }
    }
}

extension RemoteServerMessage {
    static func hello(_ identity: RemoteServerIdentity) -> RemoteServerMessage {
        .hello(
            protocolVersion: RemoteProtocolVersion.current,
            serverId: identity.serverId,
            name: identity.name,
            // Older peers refuse to link to a Mac that doesn't advertise this.
            federationEnabled: true,
            peers: identity.peers,
            capabilities: [PeerConsoleCapability.v1])
    }
}
