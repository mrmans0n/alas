import Foundation

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
    case listSessions
    case listWorktrees
    case listAgents
    case listProjects
    case listBranches(projectId: String)
    case createWorktreeSession(projectId: String, base: String, branch: String, agentId: String)
    case createSession(worktreeId: String, agentId: String)
    case subscribe(sessionId: String)
    case unsubscribe(sessionId: String)
    case permissionDecision(sessionId: String, requestId: Int, optionId: String, persistScope: String?)
    case questionAnswer(sessionId: String, requestId: Int, answers: [RemoteQuestionAnswer])
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
    case queueSteerUndo(sessionId: String)
    case listChanges(sessionId: String)
    case fileDiff(sessionId: String, path: String)
    case listFiles(sessionId: String, path: String?)
    case readFile(sessionId: String, path: String)
}

extension RemoteClientMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, sessionId, requestId, optionId, persistScope, answers, action, content, text, attachments, modelId, modeId, enabled, title, worktreeId, agentId, beforeIndex, limit, itemId, intent, projectId, base, branch, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
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
                agentId: try c.decode(String.self, forKey: .agentId))
        case "createSession":
            self = .createSession(
                worktreeId: try c.decode(String.self, forKey: .worktreeId),
                agentId: try c.decode(String.self, forKey: .agentId))
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
        case "queueSteerUndo":
            self = .queueSteerUndo(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "listChanges":
            self = .listChanges(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "fileDiff":
            self = .fileDiff(sessionId: try c.decode(String.self, forKey: .sessionId),
                             path: try c.decode(String.self, forKey: .path))
        case "listFiles":
            self = .listFiles(sessionId: try c.decode(String.self, forKey: .sessionId),
                              path: try c.decodeIfPresent(String.self, forKey: .path))
        case "readFile":
            self = .readFile(sessionId: try c.decode(String.self, forKey: .sessionId),
                             path: try c.decode(String.self, forKey: .path))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
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
        case .createWorktreeSession(let projectId, let base, let branch, let agentId):
            try c.encode("createWorktreeSession", forKey: .type)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(base, forKey: .base)
            try c.encode(branch, forKey: .branch)
            try c.encode(agentId, forKey: .agentId)
        case .createSession(let worktreeId, let agentId):
            try c.encode("createSession", forKey: .type)
            try c.encode(worktreeId, forKey: .worktreeId)
            try c.encode(agentId, forKey: .agentId)
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
        case .queueSteerUndo(let s):
            try c.encode("queueSteerUndo", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .listChanges(let s):
            try c.encode("listChanges", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .fileDiff(let s, let path):
            try c.encode("fileDiff", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
        case .listFiles(let s, let path):
            try c.encode("listFiles", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(path, forKey: .path)
        case .readFile(let s, let path):
            try c.encode("readFile", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
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

    /// Messages that establish or change which turn is active, and so a
    /// following `stop` must wait for them specifically (not the whole
    /// ordered queue) before running — otherwise stop could land before a
    /// still-in-flight `sendPrompt`/`takeOver` finishes, find no active turn
    /// to cancel, and the turn the user just started would proceed anyway
    /// right after they pressed Stop. Read/list/config verbs are excluded so
    /// stop stays fast when a client is simply scrolled up mid-backfill.
    var isDriveOrdering: Bool {
        switch self {
        case .sendPrompt, .takeOver,
             .queueForceSend, .queueRemove, .queueRetry, .queueEdit,
             .queueClear, .queueSteerUndo:
            return true
        default: return false
        }
    }
}

/// Server → client. `type` discriminates.
enum RemoteServerMessage: Equatable, Sendable {
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
        firstIndex: Int, totalCount: Int, epoch: Int, revision: Int)
    case transcriptDelta(
        sessionId: String, streamingState: String, canDrive: Bool, upserts: [RemoteWireMessage],
        epoch: Int, revision: Int)
    case transcriptPage(sessionId: String, epoch: Int, firstIndex: Int, messages: [RemoteWireMessage])
    case stopPending(sessionId: String)
    case permissionRequest(sessionId: String, payload: RemotePermissionPayload)
    case permissionResolved(sessionId: String, requestId: Int)
    case questionRequest(sessionId: String, payload: RemoteQuestionPayload)
    case questionResolved(sessionId: String, requestId: Int)
    case elicitationRequest(sessionId: String, payload: RemoteElicitationPayload)
    case elicitationResolved(sessionId: String, requestId: String)
    case sessionClosed(sessionId: String)
    /// The server dropped a `sendPrompt` (caller is no longer the writer, or
    /// the prompt was empty), so the client should restore the user's text
    /// instead of silently losing it.
    case promptRejected(sessionId: String)
    case sessionConfig(RemoteSessionConfig)
    case sessionRenamed(sessionId: String, title: String)
    case queueState(sessionId: String, items: [RemoteQueuedPrompt], steerUndoAvailable: Bool)
    case queueEditRestored(sessionId: String, itemId: String, text: String)
    case error(message: String)
    case changeList(
        sessionId: String, comparisonRef: String?, metricsAvailable: Bool,
        files: [RemoteChangedFile], truncated: Bool)
    case changeListFailed(sessionId: String, reason: RemoteFileAccessReason, message: String?)
    case fileDiffResult(sessionId: String, path: String, hunks: [RemoteDiffHunk], truncated: Bool)
    case fileDiffFailed(sessionId: String, path: String, reason: RemoteFileAccessReason, message: String?)
    case fileTree(sessionId: String, path: String?, nodes: [RemoteFileNode])
    case fileTreeFailed(sessionId: String, path: String?, reason: RemoteFileAccessReason, message: String?)
    case fileContents(sessionId: String, path: String, text: String, truncated: Bool)
    case fileUnavailable(
        sessionId: String, path: String, reason: RemoteFileAccessReason,
        byteSize: Int?, message: String?)
}

extension RemoteServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, sessions, sessionId, projectId, streamingState, canDrive, messages, upserts, payload, requestId, message
        case worktrees, agents, session, projects, branches, preferredBase, stage, worktreeId
        case models, modes, currentModel, currentMode, autoRunEnabled, acceptsImages, title
        case firstIndex, totalCount, epoch, revision
        case items, steerUndoAvailable, itemId, text
        case path, files, comparisonRef, metricsAvailable, truncated, hunks, nodes, reason, byteSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
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
                revision: try c.decode(Int.self, forKey: .revision))
        case "transcriptDelta":
            self = .transcriptDelta(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                streamingState: try c.decode(String.self, forKey: .streamingState),
                canDrive: try c.decode(Bool.self, forKey: .canDrive),
                upserts: try c.decode([RemoteWireMessage].self, forKey: .upserts),
                epoch: try c.decode(Int.self, forKey: .epoch),
                revision: try c.decode(Int.self, forKey: .revision))
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
                items: try c.decode([RemoteQueuedPrompt].self, forKey: .items),
                steerUndoAvailable: try c.decodeIfPresent(Bool.self, forKey: .steerUndoAvailable) ?? false)
        case "queueEditRestored":
            self = .queueEditRestored(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                itemId: try c.decode(String.self, forKey: .itemId),
                text: try c.decode(String.self, forKey: .text))
        case "error": self = .error(message: try c.decode(String.self, forKey: .message))
        case "changeList":
            self = .changeList(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                comparisonRef: try c.decodeIfPresent(String.self, forKey: .comparisonRef),
                metricsAvailable: try c.decode(Bool.self, forKey: .metricsAvailable),
                files: try c.decode([RemoteChangedFile].self, forKey: .files),
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "changeListFailed":
            self = .changeListFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileDiffResult":
            self = .fileDiffResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                hunks: try c.decode([RemoteDiffHunk].self, forKey: .hunks),
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "fileDiffFailed":
            self = .fileDiffFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileTree":
            self = .fileTree(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                nodes: try c.decode([RemoteFileNode].self, forKey: .nodes))
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
        case .transcriptSnapshot(let id, let st, let cd, let m, let firstIndex, let totalCount, let epoch, let revision):
            try c.encode("transcriptSnapshot", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(st, forKey: .streamingState)
            try c.encode(cd, forKey: .canDrive)
            try c.encode(m, forKey: .messages)
            try c.encode(firstIndex, forKey: .firstIndex)
            try c.encode(totalCount, forKey: .totalCount)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(revision, forKey: .revision)
        case .transcriptDelta(let id, let st, let cd, let u, let epoch, let revision):
            try c.encode("transcriptDelta", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(st, forKey: .streamingState)
            try c.encode(cd, forKey: .canDrive)
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
        case .queueState(let id, let items, let steerUndoAvailable):
            try c.encode("queueState", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(items, forKey: .items)
            try c.encode(steerUndoAvailable, forKey: .steerUndoAvailable)
        case .queueEditRestored(let id, let itemId, let text):
            try c.encode("queueEditRestored", forKey: .type)
            try c.encode(id, forKey: .sessionId)
            try c.encode(itemId, forKey: .itemId)
            try c.encode(text, forKey: .text)
        case .error(let m): try c.encode("error", forKey: .type)
        try c.encode(m, forKey: .message)
        case .changeList(let s, let ref, let available, let files, let truncated):
            try c.encode("changeList", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(ref, forKey: .comparisonRef)
            try c.encode(available, forKey: .metricsAvailable)
            try c.encode(files, forKey: .files)
            try c.encode(truncated, forKey: .truncated)
        case .changeListFailed(let s, let reason, let message):
            try c.encode("changeListFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileDiffResult(let s, let path, let hunks, let truncated):
            try c.encode("fileDiffResult", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(hunks, forKey: .hunks)
            try c.encode(truncated, forKey: .truncated)
        case .fileDiffFailed(let s, let path, let reason, let message):
            try c.encode("fileDiffFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileTree(let s, let path, let nodes):
            try c.encode("fileTree", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(nodes, forKey: .nodes)
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
