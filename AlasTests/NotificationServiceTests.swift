import Testing
import Foundation
import UserNotifications
@testable import Alas

struct NotificationServiceTests {
    @Test func awaitingUsesClickableNotificationRequest() {
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })

        service.notifyHarnessAwaiting(
            agent: .claude,
            body: nil,
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1"
        )

        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1-awaiting")
        #expect(requests[0].content.title == "Claude Code needs input")
        #expect(requests[0].content.sound != nil)
        #expect(requests[0].content.userInfo["projectId"] as? String == "project-1")
        #expect(requests[0].content.userInfo["worktreeId"] as? String == "worktree-1")
        #expect(requests[0].content.userInfo["sessionId"] as? String == "session-1")
        #expect(requests[0].content.attachments.isEmpty == false)
        #expect(requests[0].content.attachments.first?.identifier == "logo")
    }

    @Test func finishedUsesCompletionNotificationRequest() {
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })

        service.notifyHarnessFinished(
            agent: .codex,
            body: "Completed",
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1"
        )

        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1")
        #expect(requests[0].content.title == "Codex finished")
        #expect(requests[0].content.body == "Completed")
        #expect(requests[0].content.sound != nil)
        #expect(requests[0].content.attachments.isEmpty == false)
        #expect(requests[0].content.attachments.first?.identifier == "logo")
    }

    @Test func finishEnabledFlagDoesNotDisableAwaitingNotifications() {
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })
        service.setEnabled(false)

        service.notifyHarnessAwaiting(
            agent: .claude,
            body: nil,
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1"
        )
        service.notifyHarnessFinished(
            agent: .claude,
            body: nil,
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1"
        )

        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1-awaiting")
        #expect(requests[0].content.attachments.isEmpty == false)
    }
}
