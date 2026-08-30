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

    func setup(onContextClick: @escaping (NotificationClickContext) -> Void) {
        center.delegate = delegate
        delegate.onContextClick = onContextClick
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func setEnabled(_ on: Bool) { enabled = on }

    func playAwaitingPing() {
        awaitingPingPlayer()
    }

    func notifyHarnessAwaiting(agent: AgentKind, body: String?,
                               projectId: String, worktreeId: String, sessionId: String,
                               owner: SessionOwnerID? = nil) {
        let content = buildContent(agent: agent, body: body ?? "Session is waiting for you.",
                                   title: "\(agent.displayName) needs input",
                                   projectId: projectId, worktreeId: worktreeId, sessionId: sessionId,
                                   owner: owner)
        let req = UNNotificationRequest(identifier: "\(sessionId)-awaiting", content: content, trigger: nil)
        notificationAdder(req)
    }

    func notifyHarnessPermission(agent: AgentKind, body: String?,
                                 projectId: String, worktreeId: String, sessionId: String) {
        let content = buildContent(agent: agent, body: body ?? "Session is waiting for you.",
                                   title: "\(agent.displayName) needs permission",
                                   projectId: projectId, worktreeId: worktreeId, sessionId: sessionId)
        let req = UNNotificationRequest(identifier: "\(sessionId)-permission", content: content, trigger: nil)
        notificationAdder(req)
    }

    func notifyACPQuestion(agent: AgentKind, body: String?,
                           projectId: String, worktreeId: String, sessionId: String,
                           requestId: String) {
        let content = buildContent(agent: agent, body: questionBody(body),
                                   title: "\(agent.displayName) has a question",
                                   projectId: projectId, worktreeId: worktreeId, sessionId: sessionId)
        let req = UNNotificationRequest(
            identifier: "\(sessionId)-question-\(requestId)",
            content: content,
            trigger: nil
        )
        notificationAdder(req)
    }

    func notifyHarnessFinished(agent: AgentKind, body: String?,
                               projectId: String, worktreeId: String, sessionId: String) {
        guard enabled else { return }
        let content = buildContent(agent: agent, body: body ?? "Session is done.",
                                   title: "\(agent.displayName) finished",
                                   projectId: projectId, worktreeId: worktreeId, sessionId: sessionId)
        let req = UNNotificationRequest(identifier: sessionId, content: content, trigger: nil)
        notificationAdder(req)
    }

    func notifyAlas(body: String, title: String?, agent: AgentKind,
                    projectId: String, worktreeId: String, sessionId: String) {
        let content = buildContent(
            agent: agent,
            body: body,
            title: title ?? "Alas",
            projectId: projectId,
            worktreeId: worktreeId,
            sessionId: sessionId
        )
        let req = UNNotificationRequest(
            identifier: "\(sessionId)-notify-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        notificationAdder(req)
    }

    // MARK: - Private helpers

    private func questionBody(_ body: String?) -> String {
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Session is waiting for an answer." : trimmed
    }

    private func buildContent(agent: AgentKind, body: String, title: String,
                              projectId: String, worktreeId: String, sessionId: String,
                              owner: SessionOwnerID? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var userInfo: [String: Any] = [
            "projectId": projectId,
            "worktreeId": worktreeId,
            "sessionId": sessionId
        ]
        if let owner {
            switch owner {
            case .worktree(let id):
                userInfo["sessionOwnerKind"] = "worktree"
                userInfo["sessionOwnerWorktreeId"] = id
            case .workspaceCheckout(let id, let location):
                userInfo["sessionOwnerKind"] = "workspaceCheckout"
                userInfo["sessionOwnerCheckoutId"] = id.uuidString
                switch location.normalized {
                case .local:
                    userInfo["sessionOwnerLocationKind"] = "local"
                case .ssh(let destination):
                    userInfo["sessionOwnerLocationKind"] = "ssh"
                    userInfo["sessionOwnerLocationDestination"] = destination
                }
            }
        }
        content.userInfo = userInfo
        if let attachment = makeLogoAttachment(for: agent) {
            content.attachments = [attachment]
        }
        return content
    }

    private func makeLogoAttachment(for agent: AgentKind) -> UNNotificationAttachment? {
        guard let image = NSImage(named: NSImage.Name(agent.logoAssetName)) else { return nil }
        // macOS requires attachments to be plain files on disk.
        guard let tiffData = image.tiffRepresentation else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-notification-\(agent.rawValue).png", isDirectory: false)

        // Avoid re-writing the same temp file on every notification.
        if FileManager.default.fileExists(atPath: tmp.path) {
            return try? UNNotificationAttachment(identifier: "logo", url: tmp, options: nil)
        }

        guard let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        do {
            try pngData.write(to: tmp)
            return try UNNotificationAttachment(identifier: "logo", url: tmp, options: nil)
        } catch {
            return nil
        }
    }
}
