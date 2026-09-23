import Testing
import Foundation
@testable import Alas

struct RemoteMessageSessionScopeTests {
    @Test func everySessionScopedClientMessageExposesAndRewritesItsId() {
        let scoped: [RemoteClientMessage] = [
            .subscribe(sessionId: "a"), .unsubscribe(sessionId: "a"),
            .permissionDecision(sessionId: "a", requestId: 1, optionId: "o", persistScope: nil),
            .questionAnswer(sessionId: "a", requestId: 1, answers: []),
            .planResponse(sessionId: "a", requestId: .number(1), action: "accept", reason: nil),
            .elicitationResponse(sessionId: "a", requestId: "r", action: "cancel", content: nil),
            .takeOver(sessionId: "a"),
            .sendPrompt(sessionId: "a", text: "hi", attachments: [], intent: "auto"),
            .stop(sessionId: "a"),
            .setModel(sessionId: "a", modelId: "m"), .setMode(sessionId: "a", modeId: "m"),
            .setAutoRun(sessionId: "a", enabled: true), .renameSession(sessionId: "a", title: "t"),
            .fetchOlder(sessionId: "a", beforeIndex: 3, limit: 10),
            .queueForceSend(sessionId: "a", itemId: "i"), .queueRemove(sessionId: "a", itemId: "i"),
            .queueRetry(sessionId: "a", itemId: "i"), .queueEdit(sessionId: "a", itemId: "i"),
            .queueClear(sessionId: "a"),
            .listChanges(sessionId: "a"), .fileDiff(sessionId: "a", path: "p", stage: nil),
            .listFiles(sessionId: "a", path: nil), .readFile(sessionId: "a", path: "p"),
        ]
        for message in scoped {
            #expect(message.sessionId == "a", "\(message)")
            let rewritten = message.replacingSessionId("b")
            #expect(rewritten.sessionId == "b", "\(message)")
            // Only the id moved: rewriting back yields the original.
            #expect(rewritten.replacingSessionId("a") == message, "\(message)")
        }
    }

    @Test func unscopedClientMessagesHaveNoIdAndAreUnchanged() {
        let unscoped: [RemoteClientMessage] = [
            .helloAck(protocolVersion: 1), .listSessions, .listWorktrees, .listAgents, .listProjects,
            .listBranches(projectId: "p"),
            .createWorktreeSession(projectId: "p", base: "main", branch: "b", agentId: "x"),
            .createSession(worktreeId: "w", agentId: "x"),
        ]
        for message in unscoped {
            #expect(message.sessionId == nil, "\(message)")
            #expect(message.replacingSessionId("b") == message, "\(message)")
        }
    }

    @Test func everySessionScopedServerMessageExposesAndRewritesItsId() {
        let cfg = RemoteSessionConfig(sessionId: "a", models: [], modes: [], currentModel: nil,
                                      currentMode: nil, autoRunEnabled: false, acceptsImages: false)
        let scoped: [RemoteServerMessage] = [
            .transcriptSnapshot(sessionId: "a", streamingState: "idle", canDrive: false, messages: [],
                                firstIndex: 0, totalCount: 0, epoch: 0, revision: 0),
            .transcriptDelta(sessionId: "a", streamingState: "idle", canDrive: false, upserts: [], epoch: 0, revision: 1),
            .transcriptPage(sessionId: "a", epoch: 0, firstIndex: 0, messages: []),
            .stopPending(sessionId: "a"),
            .permissionRequest(sessionId: "a", payload: RemotePermissionPayload(
                requestId: 0, toolName: "t", options: [], title: nil, reason: nil, defaultToNo: false, mcpServerName: nil)),
            .permissionResolved(sessionId: "a", requestId: 0),
            .questionRequest(sessionId: "a", payload: RemoteQuestionPayload(requestId: 0, title: nil, questions: [])),
            .questionResolved(sessionId: "a", requestId: 0),
            .planRequest(sessionId: "a", payload: RemotePlanPayload(
                requestId: .number(1), toolCallId: "tc", name: "n", overview: "o", plan: "p", todos: [], isProject: false, phases: [])),
            .planResolved(sessionId: "a", requestId: .number(1)),
            .elicitationRequest(sessionId: "a", payload: RemoteElicitationPayload(
                requestId: "r", title: nil, message: "m", mode: "form", fields: [], elicitationId: nil, url: nil)),
            .elicitationResolved(sessionId: "a", requestId: "r"),
            .sessionClosed(sessionId: "a"), .promptRejected(sessionId: "a"),
            .sessionConfig(cfg), .sessionRenamed(sessionId: "a", title: "t"),
            .queueState(sessionId: "a", items: []), .queueEditRestored(sessionId: "a", itemId: "i", text: "t"),
            .changeList(sessionId: "a", comparisonRef: nil, metricsAvailable: false, files: [], staged: [],
                        unstaged: [], commits: [], truncated: false),
            .changeListFailed(sessionId: "a", reason: .sessionUnknown, message: nil),
            .fileDiffResult(sessionId: "a", path: "p", hunks: [], truncated: false),
            .fileDiffFailed(sessionId: "a", path: "p", reason: .sessionUnknown, message: nil),
            .fileTree(sessionId: "a", path: nil, nodes: [], truncated: false),
            .fileTreeFailed(sessionId: "a", path: nil, reason: .sessionUnknown, message: nil),
            .fileContents(sessionId: "a", path: "p", text: "", truncated: false),
            .fileUnavailable(sessionId: "a", path: "p", reason: .sessionUnknown, byteSize: nil, message: nil),
            .error(message: "m", sessionId: "a"),
        ]
        for message in scoped {
            #expect(message.sessionId == "a", "\(message)")
            let rewritten = message.replacingSessionId("b")
            #expect(rewritten.sessionId == "b", "\(message)")
            #expect(rewritten.replacingSessionId("a") == message, "\(message)")
        }
    }

    @Test func unscopedServerMessagesHaveNoIdAndAreUnchanged() {
        let summary = RemoteSessionSummary(id: "a", title: "t", agentId: "x", status: "idle", canDrive: false)
        let unscoped: [RemoteServerMessage] = [
            .hello(protocolVersion: 1, serverId: "s", name: "n"),
            .identityProof(challenge: "c", publicKey: "k", signature: "s"),
            .sessionList(sessions: [summary]), .worktreeList(worktrees: []), .agentList(agents: []),
            .projectList(projects: []), .branchList(projectId: "p", branches: [], preferredBase: "main"),
            .branchListFailed(projectId: "p", message: "m"),
            .worktreeSessionCreated(session: summary),
            .worktreeSessionCreationFailed(stage: .worktree, message: "m", worktreeId: nil),
            .sessionCreated(session: summary), .createSessionFailed(message: "m"),
            .error(message: "m"),
        ]
        for message in unscoped {
            #expect(message.sessionId == nil, "\(message)")
            #expect(message.replacingSessionId("b") == message, "\(message)")
        }
    }

    /// `.error` is the one case that is scoped or not depending on its own
    /// payload: most callers have nothing to blame on a single session, but
    /// a federated verb (e.g. renameSession) that fails on the home Mac
    /// needs its error routed back to the asking client the same way any
    /// other reply is, which only works when the error carries an id.
    @Test func errorIsScopedOnlyWhenItCarriesASessionId() {
        let unscopedError = RemoteServerMessage.error(message: "m")
        #expect(unscopedError.sessionId == nil)
        #expect(unscopedError.replacingSessionId("b") == unscopedError)

        let scopedError = RemoteServerMessage.error(message: "m", sessionId: "a")
        #expect(scopedError.sessionId == "a")
        #expect(scopedError.replacingSessionId("b") == .error(message: "m", sessionId: "b"))
    }
}
