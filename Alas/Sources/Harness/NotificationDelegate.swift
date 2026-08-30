import Foundation
import UserNotifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onClick: ((String, String, String) -> Void)?   // projectId, worktreeId, sessionId
    var onContextClick: ((NotificationClickContext) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let context = NotificationClickContext(userInfo: info) {
            DispatchQueue.main.async {
                self.onContextClick?(context)
                if let p = context.projectId, let w = context.worktreeId {
                    self.onClick?(p, w, context.sessionId)
                }
            }
        }
        completionHandler()
    }
}

struct NotificationClickContext: Equatable, Sendable {
    var projectId: String?
    var worktreeId: String?
    var sessionId: String
    var owner: SessionOwnerID?

    init?(userInfo: [AnyHashable: Any]) {
        guard let sessionId = userInfo["sessionId"] as? String else { return nil }
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
