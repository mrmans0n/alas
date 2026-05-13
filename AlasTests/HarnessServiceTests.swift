import Testing
import Foundation
import UserNotifications
@testable import Alas

struct HarnessServiceTests {
    private func makeEvent(
        event: ActivityEvent, agent: AgentKind = .claude,
        sessionId: String = "session-1", body: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(version: 1, event: event, agent: agent,
                       sessionId: sessionId, pid: nil, timestamp: nil, body: body)
    }

    private final class RequestCollector {
        var requests: [UNNotificationRequest] = []
    }

    private func makeService() -> (HarnessService, RequestCollector) {
        let service = HarnessService(socketServer: AgentHookSocketServer(socketPath: "/dev/null"))
        let collector = RequestCollector()
        service.notifications.notificationAdder = { collector.requests.append($0) }
        return (service, collector)
    }

    @Test func awaitingNotificationPostsOnlyWhenEnteringAwaitingState() {
        let (service, collector) = makeService()
        let awaiting = makeEvent(event: .awaitingInput, body: "Need help")

        service.handleSocketEvent(
            awaiting,
            stateLookup: { _ in (projectId: "p1", worktreeId: "w1") },
            shouldNotifyOnAwaiting: { true }
        )
        service.handleSocketEvent(
            awaiting,
            stateLookup: { _ in (projectId: "p1", worktreeId: "w1") },
            shouldNotifyOnAwaiting: { true }
        )

        #expect(service.activityBySession["session-1"]?.state == .awaitingInput)
        #expect(collector.requests.count == 1)
        #expect(collector.requests[0].content.title == "Claude Code needs input")
        #expect(collector.requests[0].content.body == "Need help")
    }

    @Test func awaitingNotificationRespectsPreference() {
        let (service, collector) = makeService()
        service.handleSocketEvent(
            makeEvent(event: .awaitingInput),
            stateLookup: { _ in (projectId: "p1", worktreeId: "w1") },
            shouldNotifyOnAwaiting: { false }
        )
        #expect(service.activityBySession["session-1"]?.state == .awaitingInput)
        #expect(collector.requests.isEmpty)
    }

    @Test func idlePostsFinishedNotification() {
        let (service, collector) = makeService()
        service.handleSocketEvent(
            makeEvent(event: .idle, body: "Done with cleanup"),
            stateLookup: { _ in (projectId: "p1", worktreeId: "w1") },
            shouldNotifyOnAwaiting: { true }
        )
        #expect(service.activityBySession["session-1"]?.state == .idle)
        #expect(collector.requests.count == 1)
        #expect(collector.requests[0].content.title == "Claude Code finished")
        #expect(collector.requests[0].content.body == "Done with cleanup")
    }

    @Test func busyClearsBody() {
        let (service, _) = makeService()
        service.handleSocketEvent(
            makeEvent(event: .awaitingInput, body: "some body"),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .busy),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        #expect(service.activityBySession["session-1"]?.lastBody == nil)
    }

    @Test func summary_returnsNil_whenIdsEmpty() {
        let (service, _) = makeService()
        #expect(service.summary(forSessionIds: []) == nil)
    }

    @Test func summary_prefersAwaiting_overRunning() {
        let (service, _) = makeService()
        service.setStateForTesting(sessionId: "s1", agent: .claude, state: .busy)
        service.setStateForTesting(sessionId: "s2", agent: .codex, state: .awaitingInput)
        let summary = service.summary(forSessionIds: ["s1", "s2"])
        #expect(summary?.state == .awaiting)
        #expect(summary?.agent == .codex)
        #expect(summary?.primarySessionId == "s2")
        #expect(summary?.runningSessionCount == 1)
        #expect(summary?.awaitingSessionCount == 1)
    }

    @Test func summary_returnsRunning_whenNoneAwaiting() {
        let (service, _) = makeService()
        service.setStateForTesting(sessionId: "s1", agent: .claude, state: .busy)
        let summary = service.summary(forSessionIds: ["s1"])
        #expect(summary?.state == .running)
        #expect(summary?.agent == .claude)
    }

    @Test func summary_ignoresIdleSessions() {
        let (service, _) = makeService()
        service.setStateForTesting(sessionId: "s1", agent: .claude, state: .idle)
        #expect(service.summary(forSessionIds: ["s1"]) == nil)
    }

    @Test func forgetSession_clearsAllState() {
        let (service, _) = makeService()
        service.setStateForTesting(sessionId: "s1", agent: .claude, state: .busy)
        service.forgetSession("s1")
        #expect(service.activityBySession["s1"] == nil)
    }
}
