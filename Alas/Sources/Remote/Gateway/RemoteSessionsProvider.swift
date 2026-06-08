import Foundation

/// What a gateway needs from the app. Abstracted so tests inject fakes and
/// production wires it to AppState (Task 8).
@MainActor
protocol RemoteSessionsProvider: AnyObject {
    func sessionSummaries() async -> [RemoteSessionSummary]
    func session(for id: String) -> ACPSession?
    func permissionPolicy(for id: String) -> ACPPermissionPolicy?
    func hydrateIfNeeded(id: String) async
    func answerQuestion(for id: String, _ response: ACPQuestionResponse)
    func isWriter(for id: String) -> Bool
    func takeOver(for id: String)
    /// `onResult` fires once with the final outcome (false = refused now or
    /// failed delivery later); the gateway emits `promptRejected` on false so
    /// the client can restore the text instead of losing it.
    func sendPrompt(for id: String, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void)
    /// Decode a base64 image to a file under the session's acp-attachments dir.
    /// Returns the file URL on success, nil on any write error.
    func writeAttachment(_ data: Data, mimeType: String, name: String?, for id: String) -> URL?
    func stop(for id: String)
    func setModel(for id: String, modelId: String)
    func setMode(for id: String, modeId: String)
    func setAutoRun(for id: String, enabled: Bool)
    /// Projection of the session's config for the `sessionConfig` wire message,
    /// or nil if the session isn't live.
    func sessionConfig(for id: String) -> RemoteSessionConfig?
}
