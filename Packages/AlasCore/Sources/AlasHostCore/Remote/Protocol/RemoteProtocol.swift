import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasACP

/// Wire protocol version advertised in `hello`. Bump only for changes an
/// older client or server cannot tolerate; additive optional fields do not
/// count.
public enum RemoteProtocolVersion: Sendable {
    public static let current = 1
}

/// One of the sending Mac's peers, as reported in `hello` so a client can
/// render the gateway's peer list without a separate request. `state` is
/// `"online"` only when that peer's sessions are actually reachable through
/// this Mac; `"unverified"` marks a record that connects but is not pinned
/// to a proven key, and the rest mirror `RemotePeerConnection.State`.
public struct RemoteHelloPeer: Codable, Equatable, Sendable {
    public let serverId: String
    public let name: String
    public let state: String

    public init(serverId: String, name: String, state: String) {
        self.serverId = serverId
        self.name = name
        self.state = state
    }
}

/// What a Mac says about itself in the first frame of every socket.
public struct RemoteServerIdentity: Equatable, Sendable {
    public let serverId: String
    public let name: String
    public let peers: [RemoteHelloPeer]
    /// The `PeerConsoleCapability` values this server serves; empty for one
    /// with no terminal consoles.
    public let consoleCapabilities: [String]
    /// The `HostProtocolCapability` values this server serves.
    public let hostCapabilities: [String]

    public init(
        serverId: String, name: String, peers: [RemoteHelloPeer] = [],
        consoleCapabilities: [String] = PeerConsoleCapability.appHost, hostCapabilities: [String] = HostProtocolCapability.served
    ) {
        self.serverId = serverId
        self.name = name
        self.peers = peers
        self.consoleCapabilities = consoleCapabilities
        self.hostCapabilities = hostCapabilities
    }
}

/// An `@` mention, offered by the host's `mentionCandidates` and sent back
/// with a prompt. The host resolves `value` itself and refuses a prompt
/// whose mention it can't resolve inside the session's project.
public struct RemoteMention: Codable, Equatable, Hashable, Sendable {
    public static let file = "file"
    public static let session = "session"
    public static let symbol = "symbol"

    /// `file`, `session` or `symbol`.
    public let kind: String
    /// A worktree-relative path, a session id, or an `alas-symbol` URI.
    public let value: String
    /// What the composer shows after the `@`.
    public let name: String
    /// Secondary text for the picker row.
    public var detail: String? = nil

    public init(kind: String, value: String, name: String, detail: String? = nil) {
        self.kind = kind
        self.value = value
        self.name = name
        self.detail = detail
    }
}

public struct RemoteModelInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RemoteAttachment: Codable, Equatable, Sendable {
    public let name: String?
    public let mimeType: String
    public let dataBase64: String

    public init(name: String?, mimeType: String, dataBase64: String) {
        self.name = name
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
    }
}

public struct RemoteSessionConfig: Codable, Equatable, Sendable {
    public var sessionId: String
    public let models: [RemoteModelInfo]
    public let modes: [RemoteModelInfo]
    public var currentModel: String?
    public var currentMode: String?
    public var autoRunEnabled: Bool
    public let acceptsImages: Bool
    public var chips: RemoteChipState? = nil
    public var supportsSteering: Bool? = nil
    /// The agent's slash commands, for the viewer's picker. Nil on older hosts.
    public var availableCommands: [RemoteSlashCommand]? = nil
    /// Context window and token usage for the composer's ring. Nil until the
    /// agent reports any, and on older hosts.
    public var usage: RemoteUsage? = nil
    /// Set by hosts that serve `queueMove` and `queuePromote`. Older hosts
    /// drop unknown verbs, so viewers hide reordering without it.
    public var supportsQueueReorder: Bool? = nil
    /// Set by hosts that serve `searchMentions` and resolve `sendPrompt`
    /// mentions. Older hosts would drop both.
    public var supportsMentions: Bool? = nil
    /// Why the session's agent cannot run on the host, or the error it last
    /// hit, as the host's own banner words it. Nil when nothing is wrong,
    /// and on older hosts.
    public var agentIssue: RemoteAgentIssue? = nil

    public init(sessionId: String, models: [RemoteModelInfo], modes: [RemoteModelInfo], currentModel: String? = nil, currentMode: String? = nil, autoRunEnabled: Bool, acceptsImages: Bool, chips: RemoteChipState? = nil, supportsSteering: Bool? = nil, availableCommands: [RemoteSlashCommand]? = nil, usage: RemoteUsage? = nil, supportsQueueReorder: Bool? = nil, supportsMentions: Bool? = nil, agentIssue: RemoteAgentIssue? = nil) {
        self.sessionId = sessionId
        self.models = models
        self.modes = modes
        self.currentModel = currentModel
        self.currentMode = currentMode
        self.autoRunEnabled = autoRunEnabled
        self.acceptsImages = acceptsImages
        self.chips = chips
        self.supportsSteering = supportsSteering
        self.availableCommands = availableCommands
        self.usage = usage
        self.supportsQueueReorder = supportsQueueReorder
        self.supportsMentions = supportsMentions
        self.agentIssue = agentIssue
    }
}

public struct RemoteAgentIssue: Codable, Equatable, Sendable {
    /// `needsSetup`, `needsAuth`, `setupError`, `failed` (the agent could
    /// not start or attach) or `error` (a prompt failed on a running agent).
    public var kind: String
    public var message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct RemoteSlashCommand: Codable, Equatable, Sendable {
    public var command: String
    public var description: String?
    public var hint: String?

    public init(command: String, description: String? = nil, hint: String? = nil) {
        self.command = command
        self.description = description
        self.hint = hint
    }
}

public struct RemoteUsage: Codable, Equatable, Sendable {
    public var modelName: String?
    public var context: RemoteContextWindow?
    /// Per-model totals for the last turn and for the session so far, each
    /// already reduced to the one number the popover shows.
    public var lastTurn: [RemoteTokenUsage]
    public var cumulative: [RemoteTokenUsage]

    public init(modelName: String? = nil, context: RemoteContextWindow? = nil, lastTurn: [RemoteTokenUsage], cumulative: [RemoteTokenUsage]) {
        self.modelName = modelName
        self.context = context
        self.lastTurn = lastTurn
        self.cumulative = cumulative
    }
}

public struct RemoteContextWindow: Codable, Equatable, Sendable {
    public var used: Int
    public var size: Int
    public var costAmount: Double?
    public var costCurrency: String?

    public init(used: Int, size: Int, costAmount: Double? = nil, costCurrency: String? = nil) {
        self.used = used
        self.size = size
        self.costAmount = costAmount
        self.costCurrency = costCurrency
    }
}

public struct RemoteTokenUsage: Codable, Equatable, Sendable {
    public var label: String
    public var tokens: Int

    public init(label: String, tokens: Int) {
        self.label = label
        self.tokens = tokens
    }
}

public struct RemoteChipState: Codable, Equatable, Sendable {
    public var model: RemoteChip?
    public var thinking: RemoteChip?
    public var mode: RemoteChip?
    public var parameters: [RemoteParameterChip]
    public var booleans: [RemoteBooleanOption]
    /// "supported" | "ignored"
    public var autoRun: String

    public init(model: RemoteChip? = nil, thinking: RemoteChip? = nil, mode: RemoteChip? = nil, parameters: [RemoteParameterChip], booleans: [RemoteBooleanOption], autoRun: String) {
        self.model = model
        self.thinking = thinking
        self.mode = mode
        self.parameters = parameters
        self.booleans = booleans
        self.autoRun = autoRun
    }
}

public struct RemoteChip: Codable, Equatable, Sendable {
    /// "model" | "mode" | "config"
    public var source: String
    public var configId: String?
    public var options: [RemoteChipOption]
    public var currentId: String?

    public init(source: String, configId: String? = nil, options: [RemoteChipOption], currentId: String? = nil) {
        self.source = source
        self.configId = configId
        self.options = options
        self.currentId = currentId
    }
}

public struct RemoteChipOption: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var kind: String?

    public init(id: String, name: String, description: String? = nil, kind: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
    }
}

public struct RemoteParameterChip: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var presentation: String
    public var chip: RemoteChip

    public init(id: String, label: String, presentation: String, chip: RemoteChip) {
        self.id = id
        self.label = label
        self.presentation = presentation
        self.chip = chip
    }
}

public struct RemoteBooleanOption: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var value: Bool

    public init(id: String, name: String, value: Bool) {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// Client → server. `type` discriminates.
public enum RemoteClientMessage: Equatable, Sendable {
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
        modelId: String? = nil, effortId: String? = nil, repoHook: RepoHookConsent? = nil)
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
    /// Opens a stored session as a tab on the host; see `PeerSessionTabsCapability`.
    case openSessionTab(sessionId: String)
    /// Closes the host's tab for a session, keeping it in recent history.
    case closeSessionTab(sessionId: String)
    case sendPrompt(
        sessionId: String, text: String, attachments: [RemoteAttachment], intent: String,
        mentions: [RemoteMention] = [])
    /// Asks for `@` candidates matching `query`; answered by
    /// `mentionCandidates`. Served when `supportsMentions` is set.
    case searchMentions(sessionId: String, query: String)
    case stop(sessionId: String)
    case setModel(sessionId: String, modelId: String)
    case setMode(sessionId: String, modeId: String)
    case setAutoRun(sessionId: String, enabled: Bool)
    case setConfigOption(sessionId: String, configId: String, value: ACPConfigValue)
    case renameSession(sessionId: String, title: String)
    case fetchOlder(sessionId: String, beforeIndex: Int, limit: Int)
    case queueForceSend(sessionId: String, itemId: String)
    case queueRemove(sessionId: String, itemId: String)
    case queueRetry(sessionId: String, itemId: String)
    case queueEdit(sessionId: String, itemId: String)
    case queueClear(sessionId: String)
    /// Moves `itemId` into `targetItemId`'s slot, as dropping one queue row
    /// on another does locally. Served when `supportsQueueReorder` is set.
    case queueMove(sessionId: String, itemId: String, targetItemId: String)
    /// Moves `itemId` to the front without interrupting a running turn.
    case queuePromote(sessionId: String, itemId: String)
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
    /// `requestId` is an opaque correlation token echoed on any `visualAidRejected`, so one of several
    /// phones on a federated session can tell its own rejection from another's.
    case visualAidResponse(sessionId: String, visualId: String, action: String, selectedOptionIds: [String], note: String?, requestId: String? = nil)
    /// Peer console traffic; see `PeerConsoleRequest`.
    case console(PeerConsoleRequest)
    /// Forwarded run endpoint traffic; see `PeerPortForwardRequest`.
    case portForward(PeerPortForwardRequest)
    /// A host protocol message; see `HostClientMessage`.
    case host(HostClientMessage)
}

extension RemoteClientMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, sessionId, requestId, optionId, persistScope, answers, action, reason, content, text, attachments, modelId, effortId, modeId, enabled, configId, value, title, worktreeId, agentId, beforeIndex, limit, itemId, targetItemId, intent, mentions, query, projectId, base, branch, path, stage, comparisonMode, protocolVersion, challenge, sha, visualId, selectedOptionIds, note, console, portForward, host, repoHook }

    public init(from decoder: Decoder) throws {
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
                effortId: try c.decodeIfPresent(String.self, forKey: .effortId),
                repoHook: try c.decodeIfPresent(RepoHookConsent.self, forKey: .repoHook))
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
                note: try c.decodeIfPresent(String.self, forKey: .note),
                requestId: try c.decodeIfPresent(String.self, forKey: .requestId))
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
        case "openSessionTab":
            self = .openSessionTab(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "closeSessionTab":
            self = .closeSessionTab(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "sendPrompt":
            self = .sendPrompt(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                text: try c.decode(String.self, forKey: .text),
                attachments: try c.decodeIfPresent([RemoteAttachment].self, forKey: .attachments) ?? [],
                // Absent on clients cached before queue parity shipped; those
                // clients only ever meant "auto".
                intent: try c.decodeIfPresent(String.self, forKey: .intent) ?? "auto",
                mentions: try c.decodeIfPresent([RemoteMention].self, forKey: .mentions) ?? [])
        case "searchMentions":
            self = .searchMentions(sessionId: try c.decode(String.self, forKey: .sessionId),
                                   query: try c.decode(String.self, forKey: .query))
        case "stop":
            self = .stop(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "setModel":
            self = .setModel(sessionId: try c.decode(String.self, forKey: .sessionId), modelId: try c.decode(String.self, forKey: .modelId))
        case "setMode":
            self = .setMode(sessionId: try c.decode(String.self, forKey: .sessionId), modeId: try c.decode(String.self, forKey: .modeId))
        case "setConfigOption":
            self = .setConfigOption(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                configId: try c.decode(String.self, forKey: .configId),
                value: try c.decode(ACPConfigValue.self, forKey: .value))
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
        case "queueMove":
            self = .queueMove(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId),
                targetItemId: try c.decode(String.self, forKey: .targetItemId))
        case "queuePromote":
            self = .queuePromote(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId))
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
        case "portForward":
            self = .portForward(try c.decode(PeerPortForwardRequest.self, forKey: .portForward))
        case "host":
            self = .host(try c.decode(HostClientMessage.self, forKey: .host))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
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
        case .createWorktreeSession(let projectId, let base, let branch, let agentId, let modelId, let effortId, let repoHook):
            try c.encode("createWorktreeSession", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(base, forKey: .base)
            try c.encode(branch, forKey: .branch)
            try c.encode(agentId, forKey: .agentId)
            try c.encodeIfPresent(modelId, forKey: .modelId)
            try c.encodeIfPresent(effortId, forKey: .effortId)
            try c.encodeIfPresent(repoHook, forKey: .repoHook)
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
        case .visualAidResponse(let s, let v, let a, let ids, let n, let requestId):
            try c.encode("visualAidResponse", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(v, forKey: .visualId)
            try c.encode(a, forKey: .action)
            try c.encode(ids, forKey: .selectedOptionIds)
            try c.encodeIfPresent(n, forKey: .note)
            try c.encodeIfPresent(requestId, forKey: .requestId)
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
        case .openSessionTab(let s):
            try c.encode("openSessionTab", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .closeSessionTab(let s):
            try c.encode("closeSessionTab", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .sendPrompt(let s, let t, let a, let intent, let mentions):
            try c.encode("sendPrompt", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(t, forKey: .text)
            try c.encode(a, forKey: .attachments)
            try c.encode(intent, forKey: .intent)
            if !mentions.isEmpty { try c.encode(mentions, forKey: .mentions) }
        case .searchMentions(let s, let query):
            try c.encode("searchMentions", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(query, forKey: .query)
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
        case .setConfigOption(let id, let configId, let value):
            try c.encode("setConfigOption", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(configId, forKey: .configId)
            try c.encode(value, forKey: .value)
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
        case .queueMove(let s, let itemId, let targetItemId):
            try c.encode("queueMove", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(itemId, forKey: .itemId)
            try c.encode(targetItemId, forKey: .targetItemId)
        case .queuePromote(let s, let itemId):
            try c.encode("queuePromote", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(itemId, forKey: .itemId)
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
        case .portForward(let request):
            try c.encode("portForward", forKey: .type)
            try c.encode(request, forKey: .portForward)
        case .host(let message):
            try c.encode("host", forKey: .type)
            try c.encode(message, forKey: .host)
        }
    }
}

extension RemoteClientMessage {
    /// Control messages bypass the per-connection serial processing chain
    /// (RemoteConnection.dispatchMessage): they are idempotent and must not
    /// queue behind transcript work. Everything else stays strictly ordered
    /// (e.g. takeOver-before-sendPrompt).
    public var isControl: Bool {
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
    public var fileRequestDedupKey: String? {
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
    public var isDriveOrdering: Bool {
        switch self {
        case .visualAidResponse(_, _, let action, _, _, _):
            return action == "answer"
        case .sendPrompt, .takeOver,
             .queueForceSend, .queueRemove, .queueRetry, .queueEdit,
             .queueClear, .queueMove, .queuePromote:
            return true
        default: return false
        }
    }
}

/// Server → client. `type` discriminates.
public enum RemoteServerMessage: Equatable, Sendable {
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
    /// Nothing was created: the client's user must approve `hook` first.
    case worktreeSessionNeedsRepoHookApproval(hook: PeerRepoHook)
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
    /// instead of silently losing it. `reason` is why the session's agent
    /// cannot take it, when the host knows; nil on older hosts.
    case promptRejected(sessionId: String, reason: String? = nil)
    /// The server refused a `visualAidResponse` (reason: notWriter, notFound,
    /// alreadyAnswered, invalid or failed), so the phone re-enables the card.
    /// `requestId` echoes the response's token when it carried one.
    case visualAidRejected(sessionId: String, visualId: String, reason: String, requestId: String? = nil)
    /// The host opened or closed the tab for `sessionId`. Every tab action
    /// gets exactly one of these two replies, in request order; the session
    /// list refresh that follows a success carries the new `isActive`.
    case sessionTabActionSucceeded(sessionId: String)
    /// The host could not open or close the tab for `sessionId` (unknown id,
    /// archived row, worktree gone, or a peer that does not serve tab actions).
    case sessionTabActionFailed(sessionId: String, message: String)
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
        commits: [RemoteCommit], truncated: Bool, commitsTruncated: Bool = false,
        // Whether `staged`/`unstaged` were capped, apart from `files`; nil from older hosts.
        workingTreeTruncated: Bool? = nil,
        // The worktree's in-progress cherry-pick/revert/merge/rebase; nil from older hosts and with none.
        operation: MergeOperation? = nil)
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
    /// `version` is the read bytes' version; nil from a host that predates it.
    case fileContents(sessionId: String, path: String, text: String, truncated: Bool, version: WorktreeFileVersion? = nil)
    case fileUnavailable(
        sessionId: String, path: String, reason: RemoteFileAccessReason,
        byteSize: Int?, message: String?)
    /// A file's raw bytes, the answer to `HostWorktreeRead.fileBytes`.
    case fileBytes(sessionId: String, path: String, data: Data, byteSize: Int)
    /// The answer to `HostWorktreeRead.fileHistory`: `truncated` when more commits touched it.
    case fileHistory(sessionId: String, path: String, entries: [HostFileHistoryEntry], truncated: Bool)
    case fileHistoryFailed(sessionId: String, path: String, reason: RemoteFileAccessReason, message: String?)
    /// The answer to `searchMentions`, echoing its query so a viewer drops
    /// answers to keystrokes it has moved past.
    case mentionCandidates(sessionId: String, query: String, candidates: [RemoteMention])
    /// Peer console traffic; see `PeerConsoleEvent`.
    case console(PeerConsoleEvent)
    /// Forwarded run endpoint traffic; see `PeerPortForwardEvent`.
    case portForward(PeerPortForwardEvent)
    /// A host protocol message; see `HostServerMessage`.
    case host(HostServerMessage)
}

extension RemoteServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, sessions, sessionId, projectId, streamingState, canDrive, messages, upserts, payload, requestId, message
        case hasCancellableBackgroundWork
        case worktrees, agents, session, projects, branches, preferredBase, stage, worktreeId
        case chips, supportsSteering, availableCommands, usage, supportsQueueReorder, supportsMentions, agentIssue
        case query, candidates
        case models, modes, currentModel, currentMode, autoRunEnabled, acceptsImages, title
        case firstIndex, totalCount, epoch, revision
        case items, itemId, text
        case path, files, staged, unstaged, commits, comparisonRef, metricsAvailable, truncated, hunks, nodes, reason, byteSize
        case metadataNote, commitsTruncated, workingTreeTruncated, operation, sha
        case protocolVersion, serverId, name, hubEnabled, federationEnabled, peers, capabilities, console, portForward, host
        case challenge, publicKey, signature
        case visualId
        case hook
        case version, entries
        case data
    }

    public init(from decoder: Decoder) throws {
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
        case "portForward":
            self = .portForward(try c.decode(PeerPortForwardEvent.self, forKey: .portForward))
        case "host":
            self = .host(try c.decode(HostServerMessage.self, forKey: .host))
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
        case "worktreeSessionNeedsRepoHookApproval":
            self = .worktreeSessionNeedsRepoHookApproval(hook: try c.decode(PeerRepoHook.self, forKey: .hook))
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
                reason: try c.decode(String.self, forKey: .reason),
                requestId: try c.decodeIfPresent(String.self, forKey: .requestId))
        case "promptRejected":
            self = .promptRejected(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                reason: try? c.decodeIfPresent(String.self, forKey: .reason) ?? nil)
        case "sessionTabActionSucceeded":
            self = .sessionTabActionSucceeded(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "sessionTabActionFailed":
            self = .sessionTabActionFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                message: try c.decode(String.self, forKey: .message))
        case "sessionConfig":
            var config = RemoteSessionConfig(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                models: try c.decode([RemoteModelInfo].self, forKey: .models),
                modes: try c.decode([RemoteModelInfo].self, forKey: .modes),
                currentModel: try c.decodeIfPresent(String.self, forKey: .currentModel),
                currentMode: try c.decodeIfPresent(String.self, forKey: .currentMode),
                autoRunEnabled: try c.decode(Bool.self, forKey: .autoRunEnabled),
                acceptsImages: try c.decode(Bool.self, forKey: .acceptsImages))
            // Deliberately lenient: a malformed or future-shaped chips payload
            // degrades to the legacy model/mode UI instead of dropping the frame.
            config.chips = try? c.decodeIfPresent(RemoteChipState.self, forKey: .chips) ?? nil
            config.supportsSteering = try c.decodeIfPresent(Bool.self, forKey: .supportsSteering)
            config.availableCommands = try? c.decodeIfPresent([RemoteSlashCommand].self, forKey: .availableCommands) ?? nil
            config.usage = try? c.decodeIfPresent(RemoteUsage.self, forKey: .usage) ?? nil
            config.supportsQueueReorder = try? c.decodeIfPresent(Bool.self, forKey: .supportsQueueReorder) ?? nil
            config.supportsMentions = try? c.decodeIfPresent(Bool.self, forKey: .supportsMentions) ?? nil
            config.agentIssue = try? c.decodeIfPresent(RemoteAgentIssue.self, forKey: .agentIssue) ?? nil
            self = .sessionConfig(config)
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
                commitsTruncated: try c.decodeIfPresent(Bool.self, forKey: .commitsTruncated) ?? false,
                workingTreeTruncated: try c.decodeIfPresent(Bool.self, forKey: .workingTreeTruncated),
                operation: (try? c.decodeIfPresent(MergeOperation.self, forKey: .operation)) ?? nil)
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
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
                version: try? c.decodeIfPresent(WorktreeFileVersion.self, forKey: .version) ?? nil)
        case "mentionCandidates":
            self = .mentionCandidates(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                query: try c.decode(String.self, forKey: .query),
                candidates: try c.decode([RemoteMention].self, forKey: .candidates))
        case "fileUnavailable":
            self = .fileUnavailable(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                byteSize: try c.decodeIfPresent(Int.self, forKey: .byteSize),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileBytes":
            self = .fileBytes(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                data: try c.decode(Data.self, forKey: .data),
                byteSize: try c.decode(Int.self, forKey: .byteSize))
        case "fileHistory":
            self = .fileHistory(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                entries: try c.decode([HostFileHistoryEntry].self, forKey: .entries),
                truncated: try c.decode(Bool.self, forKey: .truncated))
        case "fileHistoryFailed":
            self = .fileHistoryFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
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
        case .portForward(let event):
            try c.encode("portForward", forKey: .type)
            try c.encode(event, forKey: .portForward)
        case .host(let message):
            try c.encode("host", forKey: .type)
            try c.encode(message, forKey: .host)
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
        case .worktreeSessionNeedsRepoHookApproval(let hook):
            try c.encode("worktreeSessionNeedsRepoHookApproval", forKey: .type)
            try c.encode(hook, forKey: .hook)
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
        case .promptRejected(let id, let reason): try c.encode("promptRejected", forKey: .type)
        try c.encode(id, forKey: .sessionId)
        try c.encodeIfPresent(reason, forKey: .reason)
        case .visualAidRejected(let s, let v, let r, let requestId):
            try c.encode("visualAidRejected", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(v, forKey: .visualId)
            try c.encode(r, forKey: .reason)
            try c.encodeIfPresent(requestId, forKey: .requestId)
        case .sessionTabActionSucceeded(let s):
            try c.encode("sessionTabActionSucceeded", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .sessionTabActionFailed(let s, let message):
            try c.encode("sessionTabActionFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(message, forKey: .message)
        case .sessionConfig(let cfg):
            try c.encode("sessionConfig", forKey: .type)
            try c.encode(cfg.sessionId, forKey: .sessionId)
            try c.encode(cfg.models, forKey: .models)
            try c.encode(cfg.modes, forKey: .modes)
            try c.encodeIfPresent(cfg.currentModel, forKey: .currentModel)
            try c.encodeIfPresent(cfg.currentMode, forKey: .currentMode)
            try c.encode(cfg.autoRunEnabled, forKey: .autoRunEnabled)
            try c.encode(cfg.acceptsImages, forKey: .acceptsImages)
            try c.encodeIfPresent(cfg.chips, forKey: .chips)
            try c.encodeIfPresent(cfg.supportsSteering, forKey: .supportsSteering)
            try c.encodeIfPresent(cfg.availableCommands, forKey: .availableCommands)
            try c.encodeIfPresent(cfg.usage, forKey: .usage)
            try c.encodeIfPresent(cfg.supportsQueueReorder, forKey: .supportsQueueReorder)
            try c.encodeIfPresent(cfg.supportsMentions, forKey: .supportsMentions)
            try c.encodeIfPresent(cfg.agentIssue, forKey: .agentIssue)
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
        case .changeList(
            let s, let ref, let available, let files, let staged, let unstaged, let commits, let truncated, let commitsTruncated,
            let workingTreeTruncated, let operation
        ):
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
            try c.encodeIfPresent(workingTreeTruncated, forKey: .workingTreeTruncated)
            try c.encodeIfPresent(operation, forKey: .operation)
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
        case .fileContents(let s, let path, let text, let truncated, let version):
            try c.encode("fileContents", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(text, forKey: .text)
            try c.encode(truncated, forKey: .truncated)
            try c.encodeIfPresent(version, forKey: .version)
        case .mentionCandidates(let s, let query, let candidates):
            try c.encode("mentionCandidates", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(query, forKey: .query)
            try c.encode(candidates, forKey: .candidates)
        case .fileUnavailable(let s, let path, let reason, let byteSize, let message):
            try c.encode("fileUnavailable", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(byteSize, forKey: .byteSize)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileBytes(let s, let path, let data, let byteSize):
            try c.encode("fileBytes", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(data, forKey: .data)
            try c.encode(byteSize, forKey: .byteSize)
        case .fileHistory(let s, let path, let entries, let truncated):
            try c.encode("fileHistory", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(entries, forKey: .entries)
            try c.encode(truncated, forKey: .truncated)
        case .fileHistoryFailed(let s, let path, let reason, let message):
            try c.encode("fileHistoryFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        }
    }
}

extension RemoteServerMessage {
    public static func hello(_ identity: RemoteServerIdentity) -> RemoteServerMessage {
        .hello(
            protocolVersion: RemoteProtocolVersion.current,
            serverId: identity.serverId,
            name: identity.name,
            // Older peers refuse to link to a Mac that doesn't advertise this.
            federationEnabled: true,
            peers: identity.peers,
            capabilities: identity.consoleCapabilities + [PeerSessionTabsCapability.v1] + identity.hostCapabilities)
    }
}

/// The host protocol, served to paired devices as `host` messages.
public enum HostProtocolCapability: Sendable {
    /// Advertised in `hello` by hosts that answer `host` messages speaking
    /// `HostProtocolVersion` 1.
    public static let v1 = "host.v1"
    /// Advertised by hosts that also serve the session requests and events
    /// (`createSession` … `unfollowSession`). Older v1 hosts cannot decode
    /// them and answer nothing matched to the request, so clients gate
    /// session requests on this capability.
    public static let sessionsV1 = "host.sessions.v1"
    /// Hosts that serve `followWorktree` and `unfollowWorktree`.
    public static let worktreesFollowV1 = "host.worktrees.follow.v1"
    /// Hosts that serve `subscribeAccepting`, and send the event kinds a
    /// client accepts beyond those every version 1 client decodes.
    public static let eventsV1 = "host.events.v1"
    /// Hosts that serve `runOutput`.
    public static let runsOutputV1 = "host.runs.output.v1"
    /// Hosts whose `deleteWorktree` and `archiveWorktree` take
    /// `discardUnsavedEdits` and answer typed unsaved-edits and Workspace refusals.
    public static let worktreesLifecycleV1 = "host.worktrees.lifecycle.v1"
    /// Hosts that serve `readWorktree`.
    public static let worktreesReadV1 = "host.worktrees.read.v1"
    /// Hosts that serve the `fileBytes` read of `readWorktree`.
    public static let worktreesFileBytesV1 = "host.worktrees.fileBytes.v1"
    /// Hosts whose `fileBytes` read also takes the stash, checkpoint and
    /// range revisions. Only a headless host.
    public static let worktreesFileBytesV2 = "host.worktrees.fileBytes.v2"
    /// Hosts that serve the `fileHistory` read of `readWorktree`.
    public static let worktreesFileHistoryV1 = "host.worktrees.fileHistory.v1"
    /// Hosts that serve `listRunScripts` and `restartRun`.
    public static let runsScriptsV1 = "host.runs.scripts.v1"
    /// Hosts that serve `renameBranch`.
    public static let worktreesRenameBranchV1 = "host.worktrees.renameBranch.v1"
    /// Hosts that serve `mutateWorktree`, `commitMessageInput` and
    /// `reviewStatus`: only a headless host, whose Mac has no one at it to
    /// do them there.
    public static let worktreesGitV1 = "host.worktrees.git.v1"
    /// Hosts that serve `listReviews`, `readReview` and `mutateReview`:
    /// only a headless host.
    public static let reviewsV1 = "host.reviews.v1"
    /// Hosts that serve `readProviderReview`, `openProviderReview`,
    /// `mutateReviewThread` and `publishReview`: only a headless host.
    public static let reviewsProviderV1 = "host.reviews.provider.v1"
    /// Hosts that serve `listStashes`, `stashFiles`, `stashDiff` and the
    /// stash changes of `mutateWorktree`: only a headless host.
    public static let worktreesStashV1 = "host.worktrees.stash.v1"
    /// Hosts that serve the operation and conflict changes of
    /// `mutateWorktree`: continue, skip, abort, use ours, use theirs, keep
    /// deleted and mark resolved. Only a headless host.
    public static let worktreesOperationsV1 = "host.worktrees.operations.v1"
    /// Hosts that serve `commitDetails` and the `editCommit` change of
    /// `mutateWorktree`. Only a headless host.
    public static let worktreesCommitEditV1 = "host.worktrees.commitEdit.v1"
    /// Hosts that serve `listCheckpoints`, `checkpointManifest`,
    /// `checkpointDiff`, `checkpointRestorePreview` and the checkpoint changes
    /// of `mutateWorktree`. Only a headless host.
    public static let worktreesCheckpointsV1 = "host.worktrees.checkpoints.v1"
    /// Hosts that report an interrupted checkpoint restore in `listCheckpoints`
    /// and serve the `recoverCheckpointRestore` change. Only a headless host.
    public static let worktreesCheckpointRecoveryV1 = "host.worktrees.checkpointRecovery.v1"
    /// Hosts that serve `writeFile`, `createFolder`, `followFile` and `unfollowFile`, and send the
    /// `fileChanged` event. Only a headless host.
    public static let worktreesFilesV1 = "host.worktrees.files.v1"
    /// Hosts that serve the merge and rebase changes of `mutateWorktree`.
    /// Only a headless host.
    public static let worktreesIntegrateV1 = "host.worktrees.integrate.v1"
    /// Hosts that serve the hunk change of `mutateWorktree`. Only a headless host.
    public static let worktreesHunksV1 = "host.worktrees.hunks.v1"
    /// Hosts whose `createWorktreeSession` takes `repoHook`, answering
    /// `worktreeSessionNeedsRepoHookApproval` for a hook the client's user
    /// must approve first.
    public static let repoHooksApprovalV1 = "host.repoHooks.approval.v1"
    /// Everything every host serves of the host protocol.
    public static let served = [
        v1, sessionsV1, worktreesFollowV1, eventsV1, runsOutputV1, worktreesLifecycleV1, worktreesReadV1, runsScriptsV1,
        worktreesRenameBranchV1, repoHooksApprovalV1, worktreesFileBytesV1, worktreesFileHistoryV1,
    ]
    /// What only a headless host serves.
    public static let headlessOnly = [worktreesGitV1, reviewsV1, reviewsProviderV1, worktreesStashV1, worktreesOperationsV1,
                                       worktreesCommitEditV1, worktreesCheckpointsV1, worktreesFilesV1, worktreesIntegrateV1,
                                       worktreesCheckpointRecoveryV1, worktreesHunksV1, worktreesFileBytesV2]
}

/// Opening and closing host tabs from a peer. Older hosts drop unknown client
/// messages silently, so clients gate the controls on this capability.
public enum PeerSessionTabsCapability: Sendable {
    /// Advertised in `hello` by hosts that serve `openSessionTab` and `closeSessionTab`.
    public static let v1 = "peerSessionTabs.v1"
}
