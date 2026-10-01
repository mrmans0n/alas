import Foundation
import Testing
@testable import Alas

struct AgentExecutionTargetTests {
    @Test func registeredRemotePathResolvesSSHHost() {
        let path = URL(fileURLWithPath: RemotePath.virtual(host: "dev@example", realPath: "/srv/agent-target-tests/repo"))

        #expect(AgentExecutionTarget.resolve(worktreePath: path) == .ssh(host: "dev@example"))
    }

    @Test func explicitHostWinsAndOrdinaryPathIsLocal() {
        let path = URL(fileURLWithPath: "/tmp/agent-target-tests")

        #expect(AgentExecutionTarget.resolve(worktreePath: path, remoteHost: "pinned") == .ssh(host: "pinned"))
        #expect(AgentExecutionTarget.resolve(worktreePath: path) == .local)
    }

    @Test func explicitLocalTargetWinsOverRegisteredRemotePath() {
        let path = URL(fileURLWithPath: RemotePath.virtual(host: "dev@example", realPath: "/srv/agent-target-tests/local-checkout"))

        #expect(AgentExecutionTarget.resolve(worktreePath: path, pinnedTarget: .local) == .local)
        #expect(ExecutionLocation.local.agentExecutionTarget == .local)
    }
}
