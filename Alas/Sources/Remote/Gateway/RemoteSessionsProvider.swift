import Foundation

/// What a gateway needs from the app. Abstracted so tests inject fakes and
/// production wires it to AppState (Task 8).
@MainActor
protocol RemoteSessionsProvider: AnyObject {
    func sessionSummaries() -> [RemoteSessionSummary]
    func session(for id: String) -> ACPSession?
    func permissionPolicy(for id: String) -> ACPPermissionPolicy?
    func hydrateIfNeeded(id: String) async
    func answerQuestion(for id: String, _ response: ACPQuestionResponse)
    func isWriter(for id: String) -> Bool
    func takeOver(for id: String)
    /// `onResult` fires once with the final outcome (false = refused now or
    /// failed delivery later); the gateway emits `promptRejected` on false so
    /// the client can restore the text instead of losing it.
    func sendPrompt(for id: String, text: String, onResult: @escaping @MainActor (Bool) -> Void)
    func stop(for id: String)
}
