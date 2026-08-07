import Testing
import Foundation
import Observation
import UserNotifications
@testable import Alas

@Suite(.serialized)
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

    private func makeService(
        cursorIdleDebounceInterval: TimeInterval = 2.0
    ) -> (HarnessService, RequestCollector) {
        let service = HarnessService(
            socketServer: AgentHookSocketServer(socketPath: "/dev/null"),
            cursorIdleDebounceInterval: cursorIdleDebounceInterval
        )
        let collector = RequestCollector()
        service.notifications.notificationAdder = { collector.requests.append($0) }
        return (service, collector)
    }

    private func waitForMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func waitForActivity(
        _ service: HarnessService,
        sessionId: String = "session-1",
        where predicate: @escaping (HarnessService.HarnessActivityState?) -> Bool
    ) async {
        for _ in 0..<20 {
            await waitForMainQueue()
            if predicate(service.activityBySession[sessionId]) {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await waitForMainQueue()
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

    @Test func attachedSetsSessionBusy() {
        let (service, _) = makeService()
        service.handleSocketEvent(
            makeEvent(event: .attached, agent: .codex, body: "attached"),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        #expect(service.activityBySession["session-1"]?.state == .busy)
        #expect(service.activityBySession["session-1"]?.agent == .codex)
        #expect(service.activityBySession["session-1"]?.lastBody == nil)
    }

    @Test func detachedRemovesSessionActivity() {
        let (service, _) = makeService()
        service.handleSocketEvent(
            makeEvent(event: .busy),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .detached),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        #expect(service.activityBySession["session-1"] == nil)
    }

    @Test func permissionRequestSetsStateBodyAndAwaitingSummary() {
        let (service, _) = makeService()
        service.handleSocketEvent(
            makeEvent(event: .busy, sessionId: "s1"),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .permissionRequest, agent: .codex, sessionId: "s2", body: "Allow command?"),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        #expect(service.activityBySession["s2"]?.state == .permissionRequest)
        #expect(service.activityBySession["s2"]?.lastBody == "Allow command?")

        let summary = service.summary(forSessionIds: ["s1", "s2"])
        #expect(summary?.state == .awaiting)
        #expect(summary?.agent == .codex)
        #expect(summary?.primarySessionId == "s2")
        #expect(summary?.runningSessionCount == 1)
        #expect(summary?.awaitingSessionCount == 1)
    }

    @Test func cursorPermissionRequestIsTreatedAsBusyWithoutNotification() {
        let (service, collector) = makeService()
        service.handleSocketEvent(
            makeEvent(event: .awaitingInput, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .permissionRequest, agent: .cursor),
            stateLookup: { _ in (projectId: "p1", worktreeId: "w1") },
            shouldNotifyOnAwaiting: { true }
        )

        #expect(service.activityBySession["session-1"]?.state == .busy)
        #expect(collector.requests.isEmpty)
    }

    @Test func permissionRequestPostsPermissionNotificationWithFallbackBody() {
        let (service, collector) = makeService()
        service.handleSocketEvent(
            makeEvent(event: .permissionRequest, agent: .codex, body: nil),
            stateLookup: { _ in (projectId: "p1", worktreeId: "w1") },
            shouldNotifyOnAwaiting: { true }
        )

        #expect(service.activityBySession["session-1"]?.state == .permissionRequest)
        #expect(collector.requests.count == 1)
        #expect(collector.requests[0].content.title == "Codex needs permission")
        #expect(collector.requests[0].content.body == "Session is waiting for you.")
    }

    @Test func agentKindMapsToHarnessKind() {
        #expect(AgentKind.claude.asHarnessKind == .claudeCode)
        #expect(AgentKind.codex.asHarnessKind == .codex)
        #expect(AgentKind.cursor.asHarnessKind == .cursor)
        #expect(AgentKind.gemini.asHarnessKind == .gemini)
        #expect(AgentKind.opencode.asHarnessKind == .opencode)
        #expect(AgentKind.pi.asHarnessKind == .pi)
        #expect(AgentKind.copilot.asHarnessKind == .copilot)
    }

    @Test func harnessKindMapsToAgentKind() {
        #expect(HarnessKind.claudeCode.asAgentKind == .claude)
        #expect(HarnessKind.codex.asAgentKind == .codex)
        #expect(HarnessKind.cursor.asAgentKind == .cursor)
        #expect(HarnessKind.gemini.asAgentKind == .gemini)
        #expect(HarnessKind.opencode.asAgentKind == .opencode)
        #expect(HarnessKind.pi.asAgentKind == .pi)
        #expect(HarnessKind.copilot.asAgentKind == .copilot)
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

    /// Codex review (#102): when the process detector finds a harness before
    /// any socket hook fires (or for users who haven't installed hooks at
    /// all), the sidebar must still show that the session is running.
    @Test func recordHarnessDetection_seedsBusyWhenNoSocketEventYet() {
        let (service, _) = makeService()
        service.recordHarnessDetection(sessionId: "s1", kind: .claudeCode)
        #expect(service.activityBySession["s1"]?.state == .busy)
        #expect(service.activityBySession["s1"]?.agent == .claude)
        #expect(service.harnessBySession["s1"] == .claudeCode)
        #expect(service.activeHarnessBySession["s1"] == .claudeCode)
    }

    @Test func recordHarnessDetection_doesNotClobberSocketDrivenState() {
        let (service, _) = makeService()
        service.setStateForTesting(sessionId: "s1", agent: .claude, state: .awaitingInput)
        service.recordHarnessDetection(sessionId: "s1", kind: .claudeCode)
        #expect(service.activityBySession["s1"]?.state == .awaitingInput)
    }

    @Test func recordHarnessDetection_nil_dropsBusyButKeepsAwaiting() {
        let (service, _) = makeService()
        service.recordHarnessDetection(sessionId: "s1", kind: .claudeCode)
        service.recordHarnessDetection(sessionId: "s1", kind: nil)
        #expect(service.activityBySession["s1"] == nil)
        #expect(service.activeHarnessBySession["s1"] == nil)
        #expect(service.harnessBySession["s1"] == .claudeCode)

        service.setStateForTesting(sessionId: "s2", agent: .claude, state: .awaitingInput)
        service.recordHarnessDetection(sessionId: "s2", kind: .claudeCode)
        service.recordHarnessDetection(sessionId: "s2", kind: nil)
        #expect(service.activityBySession["s2"]?.state == .awaitingInput)
        #expect(service.activeHarnessBySession["s2"] == nil)
    }

    @Test func recordHarnessDetection_skipsUnchangedActiveHarnessMutation() {
        let (service, _) = makeService()
        service.recordHarnessDetection(sessionId: "s1", kind: .claudeCode)

        var invalidations = 0
        _ = withObservationTracking {
            _ = service.activeHarnessBySession
        } onChange: {
            invalidations += 1
        }

        service.recordHarnessDetection(sessionId: "s1", kind: .claudeCode)
        #expect(invalidations == 0)

        service.recordHarnessDetection(sessionId: "s1", kind: nil)
        #expect(invalidations == 1)
    }

    @Test func recordHarnessDetection_nilSkipsAbsentActiveHarnessMutation() {
        let (service, _) = makeService()

        var invalidations = 0
        _ = withObservationTracking {
            _ = service.activeHarnessBySession
        } onChange: {
            invalidations += 1
        }

        service.recordHarnessDetection(sessionId: "missing", kind: nil)
        #expect(invalidations == 0)
    }

    // MARK: - Cursor idle debounce

    @Test func cursorIdle_isDebounced() async throws {
        let (service, _) = makeService(cursorIdleDebounceInterval: 0.05)
        service.handleSocketEvent(
            makeEvent(event: .busy, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        service.handleSocketEvent(
            makeEvent(event: .idle, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        #expect(service.activityBySession["session-1"]?.state == .busy)

        await waitForActivity(service) { $0?.state == .idle }
        #expect(service.activityBySession["session-1"]?.state == .idle)
    }

    @Test func cursorIdleDebounce_commitsLatestIdleEvent() async throws {
        let (service, collector) = makeService(cursorIdleDebounceInterval: 0.05)
        service.handleSocketEvent(
            makeEvent(event: .busy, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .idle, agent: .cursor, body: "first"),
            stateLookup: { _ in (projectId: "p1", worktreeId: "w1") },
            shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .idle, agent: .cursor, body: "second"),
            stateLookup: { _ in (projectId: "p1", worktreeId: "w1") },
            shouldNotifyOnAwaiting: { false }
        )

        await waitForActivity(service) { $0?.state == .idle && $0?.lastBody == "second" }
        #expect(service.activityBySession["session-1"]?.state == .idle)
        #expect(service.activityBySession["session-1"]?.lastBody == "second")
        #expect(collector.requests.count == 1)
        #expect(collector.requests[0].content.body == "second")
    }

    @Test func cursorIdleDebounce_isCancelledByBusy() async throws {
        let (service, _) = makeService(cursorIdleDebounceInterval: 0.05)
        service.handleSocketEvent(
            makeEvent(event: .busy, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .idle, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        // Re-burry before the debounce fires.
        service.handleSocketEvent(
            makeEvent(event: .busy, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        await waitForMainQueue()
        #expect(service.activityBySession["session-1"]?.state == .busy)
    }

    @Test func cursorIdleDebounce_isCancelledByAwaitingInput() async throws {
        let (service, _) = makeService(cursorIdleDebounceInterval: 0.05)
        service.handleSocketEvent(
            makeEvent(event: .busy, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .idle, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .awaitingInput, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        await waitForMainQueue()
        #expect(service.activityBySession["session-1"]?.state == .awaitingInput)
    }

    @Test func cursorIdleDebounce_isCancelledByLegacyPermissionRequest() async throws {
        let (service, _) = makeService(cursorIdleDebounceInterval: 0.05)
        service.handleSocketEvent(
            makeEvent(event: .busy, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .idle, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .permissionRequest, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        await waitForActivity(service) { $0?.state == .busy }
        try await Task.sleep(nanoseconds: 150_000_000)
        await waitForMainQueue()
        #expect(service.activityBySession["session-1"]?.state == .busy)
    }

    @Test func claudeIdle_isNotDebounced() {
        let (service, _) = makeService(cursorIdleDebounceInterval: 0.05)
        service.handleSocketEvent(
            makeEvent(event: .busy, agent: .claude),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .idle, agent: .claude),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        #expect(service.activityBySession["session-1"]?.state == .idle)
    }

    @Test func setExternalActivityUpsertsBusyState() {
        let (service, _) = makeService()
        service.setExternalActivity(sessionId: "acp-1", agent: .claude, state: .busy)
        #expect(service.activityBySession["acp-1"]?.state == .busy)
        #expect(service.activityBySession["acp-1"]?.agent == .claude)
    }

    @Test func setExternalActivityReplacesExistingState() {
        let (service, _) = makeService()
        service.setExternalActivity(sessionId: "acp-1", agent: .claude, state: .busy)
        service.setExternalActivity(sessionId: "acp-1", agent: .claude, state: .permissionRequest)
        #expect(service.activityBySession["acp-1"]?.state == .permissionRequest)
    }

    @Test func setExternalActivityDoesNotPostNotifications() {
        let (service, collector) = makeService()
        service.setExternalActivity(sessionId: "acp-1", agent: .claude, state: .awaitingInput)
        #expect(collector.requests.isEmpty)
    }

    @Test func setExternalActivityContributesToSummary() {
        let (service, _) = makeService()
        service.setExternalActivity(sessionId: "acp-1", agent: .claude, state: .busy)
        let s = service.summary(forSessionIds: ["acp-1"])
        #expect(s?.state == .running)
        #expect(s?.primarySessionId == "acp-1")
    }

    @Test func forgetSession_cancelsCursorIdleDebounce() async throws {
        let (service, _) = makeService(cursorIdleDebounceInterval: 0.05)
        service.handleSocketEvent(
            makeEvent(event: .busy, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.handleSocketEvent(
            makeEvent(event: .idle, agent: .cursor),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )
        service.forgetSession("session-1")

        try await Task.sleep(nanoseconds: 150_000_000)
        await waitForMainQueue()
        #expect(service.activityBySession["session-1"] == nil)
    }
}
