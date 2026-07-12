import Testing
@testable import Alas

struct RemoteExecTests {
    @Test func invocationWithCwdComposesCdScript() {
        let invocation = RemoteExec.invocation(host: "devbox", cwd: "/srv/repo", command: "ls -1Ap")
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.args.contains("BatchMode=yes"))
        let expected = SSHCommand(host: "devbox", mode: .batch)
            .argv(remoteScript: SSHCommand.remoteScript(cwd: "/srv/repo", command: "ls -1Ap"))
        #expect(invocation.args == expected)
    }

    @Test func invocationWithoutCwdOmitsCd() {
        let invocation = RemoteExec.invocation(host: "devbox", cwd: nil, command: "uname -s")
        let expected = SSHCommand(host: "devbox", mode: .batch)
            .argv(remoteScript: SSHCommand.remoteScript(command: "uname -s"))
        #expect(invocation.args == expected)
    }

    @Test func exit255IsConnectionFailure() {
        #expect(RemoteExec.isConnectionFailure(exitCode: 255))
        #expect(!RemoteExec.isConnectionFailure(exitCode: 0))
        #expect(!RemoteExec.isConnectionFailure(exitCode: 1))
    }
}
