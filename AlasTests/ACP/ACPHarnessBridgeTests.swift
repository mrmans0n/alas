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
}
