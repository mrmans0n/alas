import Testing
import Foundation
import UserNotifications
@testable import Alas

struct HarnessServiceTests {
    @Test func awaitingNotificationPostsOnlyWhenEnteringAwaitingState() {
        let service = HarnessService()
        var requests: [UNNotificationRequest] = []
        service.notifications.notificationAdder = { request in
            requests.append(request)
        }
        service.recordHarnessDetection(sessionId: "session-1", kind: .claudeCode)

        let awaiting = HookEvent(sessionId: "session-1", kind: "awaiting", timestamp: Date(), summary: nil)

        service.handleHookEvent(
            awaiting,
            stateLookup: { _ in (projectId: "project-1", worktreeId: "worktree-1") },
            shouldNotifyOnAwaiting: { true }
        )
        service.handleHookEvent(
            awaiting,
            stateLookup: { _ in (projectId: "project-1", worktreeId: "worktree-1") },
            shouldNotifyOnAwaiting: { true }
        )

        #expect(service.stateBySession["session-1"] == "awaiting")
        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1-awaiting")
        #expect(requests[0].content.title == "Claude Code needs input")
        #expect(requests[0].content.userInfo["projectId"] as? String == "project-1")
    }

    @Test func awaitingNotificationRespectsPreference() {
        let service = HarnessService()
        var requests: [UNNotificationRequest] = []
        service.notifications.notificationAdder = { request in
            requests.append(request)
        }
        service.recordHarnessDetection(sessionId: "session-1", kind: .codex)

        let awaiting = HookEvent(sessionId: "session-1", kind: "awaiting", timestamp: Date(), summary: nil)

        service.handleHookEvent(
            awaiting,
            stateLookup: { _ in (projectId: "project-1", worktreeId: "worktree-1") },
            shouldNotifyOnAwaiting: { false }
        )

        #expect(service.stateBySession["session-1"] == "awaiting")
        #expect(requests.isEmpty)
    }

    @Test func stopNotificationStillPostsFinishedNotification() {
        let service = HarnessService()
        var requests: [UNNotificationRequest] = []
        service.notifications.notificationAdder = { request in
            requests.append(request)
        }
        service.recordHarnessDetection(sessionId: "session-1", kind: .aider)

        let stop = HookEvent(sessionId: "session-1", kind: "stop", timestamp: Date(), summary: "Done\nDetails")

        service.handleHookEvent(
            stop,
            stateLookup: { _ in (projectId: "project-1", worktreeId: "worktree-1") },
            shouldNotifyOnAwaiting: { true }
        )

        #expect(service.stateBySession["session-1"] == "done")
        #expect(requests.count == 1)
        #expect(requests[0].identifier == "session-1")
        #expect(requests[0].content.title == "Aider finished")
        #expect(requests[0].content.body == "Done")
    }
}
