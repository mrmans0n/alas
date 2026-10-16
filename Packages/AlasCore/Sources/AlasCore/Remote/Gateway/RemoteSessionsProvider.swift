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
    /// Serves peer console traffic; nil when this app does not.
    var peerConsoleHost: PeerConsoleHost? { get }
}

extension RemoteSessionsProvider {
    public var peerConsoleHost: PeerConsoleHost? { nil }
    public var eventHost: AlasHost? { nil }
    public var sessionListChanges: ChangeSignal<Void>? { nil }
}
