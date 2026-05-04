import Foundation
import UserNotifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onClick: ((String, String, String) -> Void)?   // projectId, worktreeId, sessionId

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let p = info["projectId"] as? String,
           let w = info["worktreeId"] as? String,
           let s = info["sessionId"] as? String {
            DispatchQueue.main.async { self.onClick?(p, w, s) }
        }
        completionHandler()
    }
}
