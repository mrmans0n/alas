import Foundation
import UserNotifications
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Main-actor confined: both handlers are wired by `NotificationService`
/// during startup and route straight into `AppState`, which is `@MainActor`.
/// `UNUserNotificationCenterDelegate` itself is not actor-isolated, so the
/// two protocol methods stay `nonisolated` and hop explicitly.
@MainActor
public final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    public var onClick: ((String, String, String) -> Void)?   // projectId, worktreeId, sessionId
    public var onContextClick: ((NotificationClickContext) -> Void)?

    /// `nonisolated` so `NotificationService` — which is not main-actor
    /// isolated — can still create the delegate in a stored-property
    /// initializer. Nothing main-actor confined is touched: both handlers
    /// start out nil and are only ever assigned from the main actor.
    public nonisolated override init() {
        super.init()
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// UserNotifications does not guarantee a delivery thread for this
    /// callback, so the handler invocation hops with a `Task` rather than
    /// asserting main-actor isolation. Nothing observes the handlers
    /// synchronously — the previous implementation already deferred them onto
    /// the main queue — and `completionHandler()` is still called inline so
    /// the system is not kept waiting on the hop.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let context = NotificationClickContext(userInfo: info) {
            Task { @MainActor in
                self.onContextClick?(context)
                if let p = context.projectId, let w = context.worktreeId {
                    self.onClick?(p, w, context.sessionId)
                }
            }
        }
        completionHandler()
    }
}

public struct NotificationClickContext: Equatable, Sendable {
    public var projectId: String?
    public var worktreeId: String?
    public var sessionId: String
    public var owner: SessionOwnerID?
    /// The paired host whose session `sessionId` is, for a relayed notice.
    public var peerServerId: String?
    /// The host worktree a relayed worktree notice is about.
    public var peerWorktreeId: String?
    /// The host review a relayed worktree notice is about.
    public var peerReviewSessionId: String?

    public init?(userInfo: [AnyHashable: Any]) {
        guard let sessionId = userInfo["sessionId"] as? String else { return nil }
        self.peerServerId = userInfo["peerServerId"] as? String
        self.peerWorktreeId = userInfo["peerWorktreeId"] as? String
        self.peerReviewSessionId = userInfo["peerReviewSessionId"] as? String
        self.projectId = userInfo["projectId"] as? String
        self.worktreeId = userInfo["worktreeId"] as? String
        self.sessionId = sessionId
        switch userInfo["sessionOwnerKind"] as? String {
        case "workspaceCheckout":
            guard let rawID = userInfo["sessionOwnerCheckoutId"] as? String,
                  let id = UUID(uuidString: rawID)
            else { return nil }
            let location: ExecutionLocation
            if (userInfo["sessionOwnerLocationKind"] as? String) == "ssh" {
                location = .ssh(userInfo["sessionOwnerLocationDestination"] as? String ?? "")
            } else {
                location = .local
            }
            owner = .workspaceCheckout(id, location)
        case "worktree":
            guard let id = userInfo["sessionOwnerWorktreeId"] as? String ?? worktreeId else { return nil }
            owner = .worktree(id)
        default:
            owner = worktreeId.map(SessionOwnerID.worktree)
        }
    }
}
