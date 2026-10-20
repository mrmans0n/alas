import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// What a Remote client can ask of the app's own windows. The host never
/// presents anything; a front end with a UI hands its gateways one of these.
/// App wiring, so behind the `AppHost` SPI.
@_spi(AppHost) @MainActor
public protocol RemoteSessionPresenter: AnyObject {
    /// Where the session's tab sits among its owner's tabs, if it has one.
    func sessionTabIndex(_ id: String, owner: SessionOwnerID) -> Int?
    /// Sent when the session list changes in a way host events don't carry,
    /// such as a session tab opening or closing.
    var sessionListChanges: ChangeSignal<Void>? { get }
    /// Serves peer console traffic; nil when this app does not.
    var peerConsoleHost: PeerConsoleHost? { get }
    /// Opens a stored session as a tab in its worktree or checkout without
    /// selecting it. Succeeds without change when the tab is already open.
    func openSessionTab(for id: String) async -> RemoteSessionTabActionResult
    /// Closes the session's tab with the same teardown and reopen history as
    /// a local close, minus the confirmation the requesting Mac already ran.
    /// The session stays in recent history.
    func closeSessionTab(for id: String) async -> RemoteSessionTabActionResult
    /// The session was renamed; its tabs show the new title.
    func sessionRenamed(_ id: String, title: String)
    /// A client created the session in `worktreeID`: the app opens it there,
    /// as it opens a session it creates.
    func sessionCreated(_ id: String, worktreeID: String)
}
