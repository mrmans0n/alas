import Foundation
import Testing
@testable import Alas

struct AgentExecutionTargetTests {
    @Test func registeredRemotePathResolvesSSHHost() {
        let path = URL(fileURLWithPath: "/srv/agent-target-tests/repo")
        RemoteHostRegistry.shared.register(root: path.path, host: "dev@example")
        defer { RemoteHostRegistry.shared.unregister(root: path.path) }

        #expect(AgentExecutionTarget.resolve(worktreePath: path) == .ssh(host: "dev@example"))
    }

    @Test func explicitHostWinsAndOrdinaryPathIsLocal() {
        let path = URL(fileURLWithPath: "/tmp/agent-target-tests")

        #expect(AgentExecutionTarget.resolve(worktreePath: path, remoteHost: "pinned") == .ssh(host: "pinned"))
        #expect(AgentExecutionTarget.resolve(worktreePath: path) == .local)
    }
}
