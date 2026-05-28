import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPHarnessBridge")
struct ACPHarnessBridgeTests {
    private func makeHarness() -> HarnessService {
        HarnessService(
            socketServer: AgentHookSocketServer(socketPath: "/dev/null"),
            cursorIdleDebounceInterval: 2.0
        )
    }

    @Test("streamingState .sending writes .busy")
    func sendingMapsToBusy() async {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let session = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "t")
        bridge.observe(session: session)
        session.streamingState = .sending
        await Task.yield()
        #expect(harness.activityBySession["s1"]?.state == .busy)
        #expect(harness.activityBySession["s1"]?.agent == .claude)
    }

    @Test("streamingState .streaming writes .busy")
    func streamingMapsToBusy() async {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let session = ACPSession(id: "s1", agentId: "codex", worktreeId: "wt", title: "t")
        bridge.observe(session: session)
        session.streamingState = .streaming
        await Task.yield()
        #expect(harness.activityBySession["s1"]?.state == .busy)
        #expect(harness.activityBySession["s1"]?.agent == .codex)
    }

    @Test("streamingState .awaitingPermission writes .permissionRequest")
    func awaitingPermissionMapsToPermissionRequest() async {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let session = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "t")
        bridge.observe(session: session)
        session.streamingState = .awaitingPermission
        await Task.yield()
        #expect(harness.activityBySession["s1"]?.state == .permissionRequest)
    }

    @Test("streamingState .idle removes the entry")
    func idleClearsEntry() async {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let session = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "t")
        bridge.observe(session: session)
        session.streamingState = .streaming
        await Task.yield()
        session.streamingState = .idle
        await Task.yield()
        #expect(harness.activityBySession["s1"] == nil)
    }

    @Test("cursor-agent agentId maps to .cursor AgentKind")
    func cursorAgentMaps() async {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let session = ACPSession(id: "s1", agentId: "cursor-agent", worktreeId: "wt", title: "t")
        bridge.observe(session: session)
        session.streamingState = .streaming
        await Task.yield()
        #expect(harness.activityBySession["s1"]?.agent == .cursor)
    }

    @Test("unknown agentId falls back to .claude")
    func unknownAgentFallsBack() async {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let session = ACPSession(id: "s1", agentId: "made-up-agent", worktreeId: "wt", title: "t")
        bridge.observe(session: session)
        session.streamingState = .streaming
        await Task.yield()
        #expect(harness.activityBySession["s1"]?.agent == .claude)
    }

    @Test("attach observes existing sessions and writes their state")
    func attachObservesExistingSessions() async throws {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(agentId: "claude")

        bridge.attach(manager: manager)
        session.streamingState = .streaming
        await Task.yield()

        #expect(harness.activityBySession[session.id]?.state == .busy)
    }

    @Test("attach observes sessions added after attach")
    func attachObservesSessionsAddedLater() async throws {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        bridge.attach(manager: manager)

        let session = manager.createSession(agentId: "claude")
        await Task.yield()
        session.streamingState = .streaming
        await Task.yield()

        #expect(harness.activityBySession[session.id]?.state == .busy)
    }

    @Test("removing a session from the manager forgets its harness entry")
    func removingSessionForgetsHarnessEntry() async throws {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(agentId: "claude")
        bridge.attach(manager: manager)
        session.streamingState = .streaming
        await Task.yield()
        #expect(harness.activityBySession[session.id]?.state == .busy)

        manager.closeSession(id: session.id)
        await Task.yield()

        #expect(harness.activityBySession[session.id] == nil)
    }

    @Test("detach stops observing and clears all the manager's sessions")
    func detachStopsObservation() async throws {
        let harness = makeHarness()
        let bridge = ACPHarnessBridge(harness: harness)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(agentId: "claude")
        bridge.attach(manager: manager)
        session.streamingState = .streaming
        await Task.yield()

        bridge.detach(worktreeId: "wt")
        await Task.yield()

        #expect(harness.activityBySession[session.id] == nil)

        // Further streamingState changes are not mirrored.
        session.streamingState = .awaitingPermission
        await Task.yield()
        #expect(harness.activityBySession[session.id] == nil)
    }
}
