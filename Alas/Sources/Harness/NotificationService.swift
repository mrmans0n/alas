import Foundation
import UserNotifications
import AppKit

final class NotificationService {
    let delegate = NotificationDelegate()
    private let center = UNUserNotificationCenter.current()
    private var enabled: Bool = true
    var notificationAdder: (UNNotificationRequest) -> Void
    var awaitingPingPlayer: () -> Void = {
        DispatchQueue.main.async {
            if let sound = NSSound(named: NSSound.Name("Tink")) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    }

    init(notificationAdder: ((UNNotificationRequest) -> Void)? = nil) {
        if let notificationAdder {
            self.notificationAdder = notificationAdder
        } else {
            self.notificationAdder = { request in
                UNUserNotificationCenter.current().add(request)
            }
        }
    }

    func setup(onClick: @escaping (String, String, String) -> Void) {
        center.delegate = delegate
        delegate.onClick = onClick
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func setEnabled(_ on: Bool) { enabled = on }

    func playAwaitingPing() {
        awaitingPingPlayer()
    }

    func notifyHarnessAwaiting(agent: AgentKind, body: String?,
                               projectId: String, worktreeId: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(agent.displayName) needs input"
        content.body = body ?? "Session is waiting for you."
        content.sound = .default
        content.userInfo = [
            "projectId": projectId,
            "worktreeId": worktreeId,
            "sessionId": sessionId
        ]
        let req = UNNotificationRequest(identifier: "\(sessionId)-awaiting", content: content, trigger: nil)
        notificationAdder(req)
    }

    func notifyHarnessPermission(agent: AgentKind, body: String?,
                                 projectId: String, worktreeId: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(agent.displayName) needs permission"
        content.body = body ?? "Session is waiting for you."
        content.sound = .default
        content.userInfo = [
            "projectId": projectId,
            "worktreeId": worktreeId,
            "sessionId": sessionId
        ]
        let req = UNNotificationRequest(identifier: "\(sessionId)-permission", content: content, trigger: nil)
        notificationAdder(req)
    }

    func notifyHarnessFinished(agent: AgentKind, body: String?,
                               projectId: String, worktreeId: String, sessionId: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(agent.displayName) finished"
        content.body = body ?? "Session is done."
        content.sound = .default
        content.userInfo = [
            "projectId": projectId,
            "worktreeId": worktreeId,
            "sessionId": sessionId
        ]
        let req = UNNotificationRequest(identifier: sessionId, content: content, trigger: nil)
        notificationAdder(req)
    }
}
