import Foundation

/// Which session a wire message is about, and the same message re-addressed.
///
/// `FederatedSessionsProvider` is the only caller: it strips a peer prefix
/// from a client message before forwarding it to the peer, and adds it back
/// to whatever the peer answers. Both enums keep the session id as a plain
/// associated value, so this is a mechanical map with one case per message.
/// A message with no session id (lists, creation, handshake, errors) reports
/// nil and is returned untouched.
extension RemoteClientMessage {
    var sessionId: String? {
        switch self {
        case .helloAck, .listSessions, .listWorktrees, .listAgents, .listProjects, .listBranches,
             .createWorktreeSession, .createSession:
            return nil
        case .subscribe(let id), .unsubscribe(let id), .takeOver(let id), .stop(let id), .queueClear(let id),
             .listChanges(let id):
            return id
        case .permissionDecision(let id, _, _, _), .questionAnswer(let id, _, _), .planResponse(let id, _, _, _),
             .elicitationResponse(let id, _, _, _), .sendPrompt(let id, _, _, _), .setModel(let id, _),
             .setMode(let id, _), .setAutoRun(let id, _), .renameSession(let id, _), .fetchOlder(let id, _, _),
             .queueForceSend(let id, _), .queueRemove(let id, _), .queueRetry(let id, _), .queueEdit(let id, _),
             .fileDiff(let id, _, _), .listFiles(let id, _), .readFile(let id, _):
            return id
        }
    }

    func replacingSessionId(_ new: String) -> RemoteClientMessage {
        switch self {
        case .helloAck, .listSessions, .listWorktrees, .listAgents, .listProjects, .listBranches,
             .createWorktreeSession, .createSession:
            return self
        case .subscribe: return .subscribe(sessionId: new)
        case .unsubscribe: return .unsubscribe(sessionId: new)
        case .permissionDecision(_, let requestId, let optionId, let persistScope):
            return .permissionDecision(sessionId: new, requestId: requestId, optionId: optionId, persistScope: persistScope)
        case .questionAnswer(_, let requestId, let answers):
            return .questionAnswer(sessionId: new, requestId: requestId, answers: answers)
        case .planResponse(_, let requestId, let action, let reason):
            return .planResponse(sessionId: new, requestId: requestId, action: action, reason: reason)
        case .elicitationResponse(_, let requestId, let action, let content):
            return .elicitationResponse(sessionId: new, requestId: requestId, action: action, content: content)
        case .takeOver: return .takeOver(sessionId: new)
        case .sendPrompt(_, let text, let attachments, let intent):
            return .sendPrompt(sessionId: new, text: text, attachments: attachments, intent: intent)
        case .stop: return .stop(sessionId: new)
        case .setModel(_, let modelId): return .setModel(sessionId: new, modelId: modelId)
        case .setMode(_, let modeId): return .setMode(sessionId: new, modeId: modeId)
        case .setAutoRun(_, let enabled): return .setAutoRun(sessionId: new, enabled: enabled)
        case .renameSession(_, let title): return .renameSession(sessionId: new, title: title)
        case .fetchOlder(_, let beforeIndex, let limit):
            return .fetchOlder(sessionId: new, beforeIndex: beforeIndex, limit: limit)
        case .queueForceSend(_, let itemId): return .queueForceSend(sessionId: new, itemId: itemId)
        case .queueRemove(_, let itemId): return .queueRemove(sessionId: new, itemId: itemId)
        case .queueRetry(_, let itemId): return .queueRetry(sessionId: new, itemId: itemId)
        case .queueEdit(_, let itemId): return .queueEdit(sessionId: new, itemId: itemId)
        case .queueClear: return .queueClear(sessionId: new)
        case .listChanges: return .listChanges(sessionId: new)
        case .fileDiff(_, let path, let stage): return .fileDiff(sessionId: new, path: path, stage: stage)
        case .listFiles(_, let path): return .listFiles(sessionId: new, path: path)
        case .readFile(_, let path): return .readFile(sessionId: new, path: path)
        }
    }
}

extension RemoteServerMessage {
    var sessionId: String? {
        switch self {
        case .hello, .identityProof, .sessionList, .worktreeList, .agentList, .projectList, .branchList,
             .branchListFailed, .worktreeSessionCreated, .worktreeSessionCreationFailed, .sessionCreated,
             .createSessionFailed, .error:
            return nil
        case .transcriptSnapshot(let id, _, _, _, _, _, _, _), .transcriptDelta(let id, _, _, _, _, _),
             .transcriptPage(let id, _, _, _), .stopPending(let id), .permissionRequest(let id, _),
             .permissionResolved(let id, _), .questionRequest(let id, _), .questionResolved(let id, _),
             .planRequest(let id, _), .planResolved(let id, _), .elicitationRequest(let id, _),
             .elicitationResolved(let id, _), .sessionClosed(let id), .promptRejected(let id),
             .sessionRenamed(let id, _), .queueState(let id, _), .queueEditRestored(let id, _, _),
             .changeList(let id, _, _, _, _, _, _, _, _), .changeListFailed(let id, _, _),
             .fileDiffResult(let id, _, _, _, _, _), .fileDiffFailed(let id, _, _, _, _),
             .fileTree(let id, _, _, _), .fileTreeFailed(let id, _, _, _), .fileContents(let id, _, _, _),
             .fileUnavailable(let id, _, _, _, _):
            return id
        case .sessionConfig(let cfg):
            return cfg.sessionId
        }
    }

    func replacingSessionId(_ new: String) -> RemoteServerMessage {
        switch self {
        case .hello, .identityProof, .sessionList, .worktreeList, .agentList, .projectList, .branchList,
             .branchListFailed, .worktreeSessionCreated, .worktreeSessionCreationFailed, .sessionCreated,
             .createSessionFailed, .error:
            return self
        case .transcriptSnapshot(_, let st, let cd, let m, let firstIndex, let totalCount, let epoch, let revision):
            return .transcriptSnapshot(sessionId: new, streamingState: st, canDrive: cd, messages: m,
                                       firstIndex: firstIndex, totalCount: totalCount, epoch: epoch, revision: revision)
        case .transcriptDelta(_, let st, let cd, let u, let epoch, let revision):
            return .transcriptDelta(sessionId: new, streamingState: st, canDrive: cd, upserts: u, epoch: epoch, revision: revision)
        case .transcriptPage(_, let epoch, let firstIndex, let m):
            return .transcriptPage(sessionId: new, epoch: epoch, firstIndex: firstIndex, messages: m)
        case .stopPending: return .stopPending(sessionId: new)
        case .permissionRequest(_, let p): return .permissionRequest(sessionId: new, payload: p)
        case .permissionResolved(_, let r): return .permissionResolved(sessionId: new, requestId: r)
        case .questionRequest(_, let p): return .questionRequest(sessionId: new, payload: p)
        case .questionResolved(_, let r): return .questionResolved(sessionId: new, requestId: r)
        case .planRequest(_, let p): return .planRequest(sessionId: new, payload: p)
        case .planResolved(_, let r): return .planResolved(sessionId: new, requestId: r)
        case .elicitationRequest(_, let p): return .elicitationRequest(sessionId: new, payload: p)
        case .elicitationResolved(_, let r): return .elicitationResolved(sessionId: new, requestId: r)
        case .sessionClosed: return .sessionClosed(sessionId: new)
        case .promptRejected: return .promptRejected(sessionId: new)
        case .sessionConfig(let cfg):
            return .sessionConfig(RemoteSessionConfig(
                sessionId: new, models: cfg.models, modes: cfg.modes, currentModel: cfg.currentModel,
                currentMode: cfg.currentMode, autoRunEnabled: cfg.autoRunEnabled, acceptsImages: cfg.acceptsImages))
        case .sessionRenamed(_, let title): return .sessionRenamed(sessionId: new, title: title)
        case .queueState(_, let items): return .queueState(sessionId: new, items: items)
        case .queueEditRestored(_, let itemId, let text):
            return .queueEditRestored(sessionId: new, itemId: itemId, text: text)
        case .changeList(_, let ref, let available, let files, let staged, let unstaged, let commits, let truncated, let commitsTruncated):
            return .changeList(sessionId: new, comparisonRef: ref, metricsAvailable: available, files: files,
                               staged: staged, unstaged: unstaged, commits: commits, truncated: truncated,
                               commitsTruncated: commitsTruncated)
        case .changeListFailed(_, let reason, let message):
            return .changeListFailed(sessionId: new, reason: reason, message: message)
        case .fileDiffResult(_, let path, let stage, let hunks, let truncated, let metadataNote):
            return .fileDiffResult(sessionId: new, path: path, stage: stage, hunks: hunks, truncated: truncated,
                                   metadataNote: metadataNote)
        case .fileDiffFailed(_, let path, let stage, let reason, let message):
            return .fileDiffFailed(sessionId: new, path: path, stage: stage, reason: reason, message: message)
        case .fileTree(_, let path, let nodes, let truncated):
            return .fileTree(sessionId: new, path: path, nodes: nodes, truncated: truncated)
        case .fileTreeFailed(_, let path, let reason, let message):
            return .fileTreeFailed(sessionId: new, path: path, reason: reason, message: message)
        case .fileContents(_, let path, let text, let truncated):
            return .fileContents(sessionId: new, path: path, text: text, truncated: truncated)
        case .fileUnavailable(_, let path, let reason, let byteSize, let message):
            return .fileUnavailable(sessionId: new, path: path, reason: reason, byteSize: byteSize, message: message)
        }
    }
}
