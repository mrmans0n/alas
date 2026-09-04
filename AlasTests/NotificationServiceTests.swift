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

    @Test func acpQuestionUsesClickableQuestionNotificationRequest() {
        let checkoutID = UUID()
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })

        service.notifyACPQuestion(
            agent: .codex,
            body: "Which implementation path should I take?",
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1",
            requestId: "42",
            owner: .workspaceCheckout(checkoutID, .ssh("devbox"))
        )

        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1-question-42")
        #expect(requests[0].content.title == "Codex has a question")
        #expect(requests[0].content.body == "Which implementation path should I take?")
        #expect(requests[0].content.sound != nil)
        #expect(requests[0].content.userInfo["projectId"] as? String == "project-1")
        #expect(requests[0].content.userInfo["worktreeId"] as? String == "worktree-1")
        #expect(requests[0].content.userInfo["sessionId"] as? String == "session-1")
        #expect(NotificationClickContext(userInfo: requests[0].content.userInfo)?.owner == .workspaceCheckout(checkoutID, .ssh("devbox")))
        #expect(requests[0].content.attachments.isEmpty == false)
        #expect(requests[0].content.attachments.first?.identifier == "logo")
    }

    @Test func acpQuestionUsesFallbackBodyWhenBodyIsBlank() {
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })

        service.notifyACPQuestion(
            agent: .codex,
            body: "   ",
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1",
            requestId: "42"
        )

        #expect(requests.count == 1)
        #expect(requests[0].content.body == "Session is waiting for an answer.")
    }

    @Test func alasNotifyUsesClickableNotificationRequest() {
        let checkoutID = UUID()
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })

        service.notifyAlas(
            body: "Blocked on input",
            title: "Need input",
            agent: .codex,
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1",
            owner: .workspaceCheckout(checkoutID, .ssh("devbox"))
        )

        #expect(requests.count == 1)
        #expect(requests[0].identifier.hasPrefix("session-1-notify-"))
        #expect(requests[0].content.title == "Need input")
        #expect(requests[0].content.body == "Blocked on input")
        #expect(requests[0].content.sound != nil)
        #expect(requests[0].content.userInfo["projectId"] as? String == "project-1")
        #expect(requests[0].content.userInfo["worktreeId"] as? String == "worktree-1")
        #expect(requests[0].content.userInfo["sessionId"] as? String == "session-1")
        #expect(NotificationClickContext(userInfo: requests[0].content.userInfo)?.owner == .workspaceCheckout(checkoutID, .ssh("devbox")))
    }

    @Test func ownerOnlyAlasNotifyOmitsLegacyProjectAndWorktreeKeys() {
        let checkoutID = UUID()
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })

        service.notifyAlas(
            body: "Blocked on input",
            title: "Need input",
            agent: .codex,
            sessionId: "session-1",
            owner: .workspaceCheckout(checkoutID, .ssh("devbox"))
        )

        #expect(requests.count == 1)
        #expect(requests[0].content.userInfo["projectId"] == nil)
        #expect(requests[0].content.userInfo["worktreeId"] == nil)
        #expect(requests[0].content.userInfo["sessionId"] as? String == "session-1")
        #expect(NotificationClickContext(userInfo: requests[0].content.userInfo)?.owner == .workspaceCheckout(checkoutID, .ssh("devbox")))
    }

    @Test func checkoutNotificationsCarryTypedClickContextAndLegacyPayloadsDecode() {
        let checkoutID = UUID()
        var requests: [UNNotificationRequest] = []
        let service = NotificationService(notificationAdder: { request in
            requests.append(request)
        })

        service.notifyHarnessAwaiting(
            agent: .codex,
            body: "Workspace checkout needs input",
            projectId: "project-1",
            worktreeId: "worktree-1",
            sessionId: "session-1",
            owner: .workspaceCheckout(checkoutID, .ssh("devbox"))
        )

        let typed = NotificationClickContext(userInfo: requests[0].content.userInfo)
        let legacy = NotificationClickContext(userInfo: [
            "projectId": "project-1",
            "worktreeId": "worktree-1",
            "sessionId": "session-1",
        ])

        #expect(typed?.sessionId == "session-1")
        #expect(typed?.owner == .workspaceCheckout(checkoutID, .ssh("devbox")))
        #expect(legacy?.projectId == "project-1")
        #expect(legacy?.worktreeId == "worktree-1")
        #expect(legacy?.owner == .worktree("worktree-1"))
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
