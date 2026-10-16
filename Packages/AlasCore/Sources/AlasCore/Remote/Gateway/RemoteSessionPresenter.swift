import Foundation

/// What a Remote client can ask of the app's own windows. The host never
/// presents anything; a front end with a UI hands its gateways one of these.
/// App wiring, so behind the `AppHost` SPI.
@_spi(AppHost) @MainActor
public protocol RemoteSessionPresenter: AnyObject {
    /// Opens a stored session as a tab in its worktree without selecting that
    /// worktree. Succeeds without change when the tab is already open.
    func openSessionTab(for id: String) async -> RemoteSessionTabActionResult
    /// Closes the session's tab with the same teardown and reopen history as
    /// a local close, minus the confirmation the requesting Mac already ran.
    /// The session stays in recent history.
    func closeSessionTab(for id: String) async -> RemoteSessionTabActionResult
    /// The session was renamed; its tabs show the new title.
    func sessionRenamed(_ id: String, title: String)
}
