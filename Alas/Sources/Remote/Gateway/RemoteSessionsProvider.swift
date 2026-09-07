import Foundation

/// What a gateway needs from the app. Abstracted so tests inject fakes and
/// production wires it to AppState (Task 8).
@MainActor
protocol RemoteSessionsProvider: AnyObject {
    func sessionSummaries() async -> [RemoteSessionSummary]
    func remoteWorktrees() async -> [RemoteWorktreeOption]
    func remoteProjects() async -> [RemoteProjectOption]
    func remoteBranches(projectId: String) async -> RemoteBranchListResult
    func remoteAgents() -> [RemoteAgentOption]
    func createRemoteSession(worktreeId: String, agentId: String) async -> RemoteCreateSessionResult
    func createRemoteWorktreeSession(
        projectId: String,
        base: String,
        branch: String,
        agentId: String
    ) async -> RemoteCreateWorktreeSessionResult
    func session(for id: String) -> ACPSession?
    func permissionPolicy(for id: String) -> ACPPermissionPolicy?
    func hydrateIfNeeded(id: String) async
    func answerQuestion(for id: String, requestId: JSONRPCID, _ response: ACPQuestionResponse)
    func respondToUserInput(for id: String, token: UUID, action: ACPUserInputAction)
    func fullToolCallContent(sessionId: String, toolCallId: String) async -> String?
    func isWriter(for id: String) -> Bool
    func takeOver(for id: String) async
    /// `onResult` fires once with the final outcome (false = refused now or
    /// failed delivery later); the gateway emits `promptRejected` on false so
    /// the client can restore the text instead of losing it.
    func sendPrompt(for id: String, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void) async
    /// Decode a base64 image to a file under the session's acp-attachments dir.
    /// Returns the file URL on success, nil on any write error.
    func writeAttachment(_ data: Data, mimeType: String, name: String?, for id: String) -> URL?
    func stop(for id: String) async
    func setModel(for id: String, modelId: String) async
    func setMode(for id: String, modeId: String) async
    func setAutoRun(for id: String, enabled: Bool) async
    func renameSession(for id: String, title: String) -> Bool
    /// Queue mutation. All of these are writer-gated inside the manager (the
    /// gateway also pre-checks, mirroring `sendPrompt`) and delegate to the
    /// same native call sites the ACP pane uses, so the `.sending`-head,
    /// persistence, and flush invariants are not duplicated for the remote path.
    func queueForceSend(for id: String, itemId: UUID) async
    func queueRemove(for id: String, itemId: UUID) async
    func queueRetry(for id: String, itemId: UUID) async
    /// Removes the item and returns its text for the web composer, or nil if
    /// the item is gone or already `.sending` (mid-RPC, must not be duplicated).
    func queueEdit(for id: String, itemId: UUID) async -> String?
    func queueClear(for id: String) async
    func queueSteerUndo(for id: String) async
    /// Cancel the in-flight turn, discard the queue, send this prompt instead.
    func steerPrompt(for id: String, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void) async
    /// Projection of the session's config for the `sessionConfig` wire message,
    /// or nil if the session isn't live.
    func sessionConfig(for id: String) -> RemoteSessionConfig?
    /// Read-only worktree inspection for the remote changes/files tabs. All
    /// four resolve the session's worktree first and are ungated by the writer
    /// lease: seeing a session is enough to read its code.
    func remoteChangeList(sessionId: String) async -> RemoteChangeListResult
    func remoteFileDiff(sessionId: String, path: String) async -> RemoteFileDiffResult
    func remoteFileTree(sessionId: String, path: String?) async -> RemoteFileTreeResult
    func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult
}

extension RemoteSessionsProvider {
    func respondToUserInput(for id: String, token: UUID, action: ACPUserInputAction) {}
}
