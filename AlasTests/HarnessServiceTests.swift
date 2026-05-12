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

    @Test func summary_returnsNil_whenIdsEmpty() {
        let service = HarnessService()
        #expect(service.summary(forSessionIds: []) == nil)
    }

    @Test func summary_returnsNil_whenAllSessionsDone() {
        let service = HarnessService()
        service.handleHookEvent(
            HookEvent(sessionId: "s1", kind: "stop", timestamp: Date(), summary: nil),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        #expect(service.stateBySession["s1"] == "done")
        #expect(service.summary(forSessionIds: ["s1"]) == nil)
    }

    @Test func summary_returnsRunning_whenSingleSessionRunning() {
        let service = HarnessService()
        service.setStateForTesting(sessionId: "s1", kind: .claudeCode, state: "running")
        let summary = service.summary(forSessionIds: ["s1"])
        #expect(summary?.state == .running)
        #expect(summary?.kind == .claudeCode)
        #expect(summary?.primarySessionId == "s1")
        #expect(summary?.runningSessionCount == 1)
        #expect(summary?.awaitingSessionCount == 0)
    }

    @Test func summary_prefersAwaiting_overRunning() {
        let service = HarnessService()
        service.setStateForTesting(sessionId: "s1", kind: .claudeCode, state: "running")
        service.setStateForTesting(sessionId: "s2", kind: .codex,      state: "awaiting")
        let summary = service.summary(forSessionIds: ["s1", "s2"])
        #expect(summary?.state == .awaiting)
        #expect(summary?.kind == .codex)
        #expect(summary?.primarySessionId == "s2")
        // Both counts are populated regardless of which state was chosen, so
        // callers (e.g. the collapsed-header tooltip) can enumerate mixed
        // activity even when awaiting masks running.
        #expect(summary?.runningSessionCount == 1)
        #expect(summary?.awaitingSessionCount == 1)
    }

    @Test func summary_picksFirstAwaitingSession_asPrimary() {
        let service = HarnessService()
        service.setStateForTesting(sessionId: "a", kind: .claudeCode, state: "awaiting")
        service.setStateForTesting(sessionId: "b", kind: .codex,      state: "awaiting")
        let summary = service.summary(forSessionIds: ["a", "b"])
        #expect(summary?.primarySessionId == "a")
        #expect(summary?.runningSessionCount == 0)
        #expect(summary?.awaitingSessionCount == 2)
    }

    @Test func summary_skipsSession_whenKindMissing() {
        let service = HarnessService()
        // session "a" has state but no kind (race condition)
        service.setStateOnlyForTesting(sessionId: "a", state: "awaiting")
        service.setStateForTesting(sessionId: "b", kind: .codex, state: "awaiting")
        let summary = service.summary(forSessionIds: ["a", "b"])
        #expect(summary?.kind == .codex)
        #expect(summary?.primarySessionId == "b")
    }

    @Test func summary_fallsBackToRunning_whenAllAwaitingLackKind() {
        let service = HarnessService()
        service.setStateOnlyForTesting(sessionId: "a", state: "awaiting")
        service.setStateForTesting(sessionId: "b", kind: .claudeCode, state: "running")
        let summary = service.summary(forSessionIds: ["a", "b"])
        #expect(summary?.state == .running)
        #expect(summary?.kind == .claudeCode)
        #expect(summary?.primarySessionId == "b")
    }

    @Test func summary_returnsNil_whenNoCandidateSessionHasKind() {
        let service = HarnessService()
        service.setStateOnlyForTesting(sessionId: "a", state: "awaiting")
        service.setStateOnlyForTesting(sessionId: "b", state: "running")
        #expect(service.summary(forSessionIds: ["a", "b"]) == nil)
    }
}
