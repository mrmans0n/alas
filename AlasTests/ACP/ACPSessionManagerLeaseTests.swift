import Testing
import Foundation
@testable import Alas

@Suite @MainActor struct ACPSessionManagerLeaseTests {
    private func tempManager(instanceId: String, store: ACPSessionStore) -> ACPSessionManager {
        ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt",
                          store: store, instanceId: instanceId, pid: Int64(getpid()))
    }

    @Test("manager exposes its instanceId")
    func exposesInstanceId() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = tempManager(instanceId: "INST-A", store: store)
        #expect(mgr.instanceId == "INST-A")
        #expect(mgr.pid == Int64(getpid()))
    }

    @Test("second instance attaching the same session becomes a mirror")
    func secondInstanceMirrors() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-mirror-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let session = mgrA.createSession(agentId: "claude")

        #expect(mgrA.acquireWriterLease(sessionId: session.id) == true)
        #expect(mgrA.isMirror(sessionId: session.id) == false)

        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = tempManager(instanceId: "B", store: storeB)
        #expect(mgrB.acquireWriterLease(sessionId: session.id) == false)
        #expect(mgrB.isMirror(sessionId: session.id) == true)
    }

    @Test("releasing the lease lets another instance claim it")
    func releaseAllowsReclaim() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-release-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let session = mgrA.createSession(agentId: "claude")
        #expect(mgrA.acquireWriterLease(sessionId: session.id) == true)
        mgrA.releaseWriterLease(sessionId: session.id)

        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = tempManager(instanceId: "B", store: storeB)
        #expect(mgrB.acquireWriterLease(sessionId: session.id) == true)
    }

    @Test("a failed attach releases the writer lease")
    func failedAttachReleasesLease() async throws {
        struct StubError: Error {}
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-failattach-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = ACPSessionManager(
            worktreeId: "wt", worktreePath: "/tmp/wt",
            store: storeA, instanceId: "A", pid: Int64(getpid()),
            setupEvaluator: { _ in .ready },
            connectionFactory: { _ in throw StubError() })
        let session = mgrA.createSession(agentId: "claude")
        await mgrA.attach(to: session.id, freshlyCreated: true)
        // attach failed at connectionFactory; the defer must have released the lease.
        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = ACPSessionManager(
            worktreeId: "wt", worktreePath: "/tmp/wt",
            store: storeB, instanceId: "B", pid: Int64(getpid()))
        #expect(mgrB.acquireWriterLease(sessionId: session.id) == true)
    }
}
