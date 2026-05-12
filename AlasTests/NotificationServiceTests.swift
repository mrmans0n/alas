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
            harness: .claudeCode,
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1"
        )

        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1-awaiting")
        #expect(requests[0].content.title == "Claude Code needs input")
        #expect(requests[0].content.userInfo["projectId"] as? String == "project-1")
        #expect(requests[0].content.userInfo["worktreeId"] as? String == "worktree-1")
        #expect(requests[0].content.userInfo["sessionId"] as? String == "session-1")
    }

    @Test func finishedUsesCompletionNotificationRequest() {
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })

        service.notifyHarnessFinished(
            harness: .codex,
            summary: "Completed\nMore details",
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1"
        )

        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1")
        #expect(requests[0].content.title == "Codex finished")
        #expect(requests[0].content.body == "Completed")
    }

    @Test func finishEnabledFlagDoesNotDisableAwaitingNotifications() {
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })
        service.setEnabled(false)

        service.notifyHarnessAwaiting(
            harness: .aider,
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1"
        )
        service.notifyHarnessFinished(
            harness: .aider,
            summary: nil,
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1"
        )

        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1-awaiting")
    }
}
