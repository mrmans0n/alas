import Foundation

/// What a gateway needs from the app. Abstracted so tests inject fakes and
/// production wires it to AppState (Task 8).
@MainActor
public protocol RemoteSessionsProvider: AnyObject {
    /// Whose events push session and worktree lists to clients; without
    /// one, clients get lists only when they ask.
    var eventHost: AlasHost? { get }
    /// Sent when the session list changes in a way host events don't carry,
    /// such as a session tab opening or closing.
    var sessionListChanges: ChangeSignal<Void>? { get }
    func sessionSummaries() async -> [RemoteSessionSummary]
    func session(for id: String) -> ACPSession?
    func permissionPolicy(for id: String) -> ACPPermissionPolicy?
    func hydrateIfNeeded(id: String) async
    func answerQuestion(for id: String, requestId: JSONRPCID, _ response: ACPQuestionResponse)
    func respondToPlan(for id: String, requestId: JSONRPCID, _ response: ACPCursorPlanResponse)
    func respondToUserInput(for id: String, token: UUID, action: ACPUserInputAction)
    func fullToolCallContent(sessionId: String, toolCallId: String) async -> String?
    func isWriter(for id: String) -> Bool
    /// Projection of the session's config for the `sessionConfig` wire message,
    /// or nil if the session isn't live.
    func sessionConfig(for id: String) -> RemoteSessionConfig?
    /// Serves peer console traffic; nil when this app does not.
    var peerConsoleHost: PeerConsoleHost? { get }
}

extension RemoteSessionsProvider {
    public var peerConsoleHost: PeerConsoleHost? { nil }
    public var eventHost: AlasHost? { nil }
    public var sessionListChanges: ChangeSignal<Void>? { nil }

    public func respondToUserInput(for id: String, token: UUID, action: ACPUserInputAction) {}
    public func respondToPlan(for id: String, requestId: JSONRPCID, _ response: ACPCursorPlanResponse) {}
}
