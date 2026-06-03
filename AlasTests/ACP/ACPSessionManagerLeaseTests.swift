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
}
