import Foundation
import Testing
@testable import Alas

@Suite
@MainActor
struct ZmxClientTests {
    // MARK: - Test doubles

    /// Captures every call so tests can assert exact subprocess invocations.
    private final class RecordingRunner: @unchecked Sendable {
        struct Call: Equatable {
            let executable: URL
            let args: [String]
            let env: [String: String]
            let timeout: TimeInterval
        }
        var calls: [Call] = []
        var result: SubprocessRunner.Result = .init(exitCode: 0, stdout: "", stderr: "")

        func runner() -> SubprocessRunner {
            SubprocessRunner { exe, args, env, timeout in
                self.calls.append(Call(executable: exe, args: args, env: env, timeout: timeout))
                return self.result
            }
        }
    }

    private func env(available: Bool) -> ZmxEnv {
        if available {
            return ZmxEnv(
                binaryURL: URL(fileURLWithPath: "/fake/Contents/Resources/zmx/zmx"),
                zmxDir: URL(fileURLWithPath: "/tmp/alas-zmx-test")
            )
        } else {
            return ZmxEnv(binaryURL: nil, zmxDir: URL(fileURLWithPath: "/tmp/alas-zmx-test"))
        }
    }

    private func samplePlan() -> StartupScriptInstaller.Plan {
        StartupScriptInstaller.Plan(
            executable: "/bin/zsh",
            args: ["-l", "-i"],
            envOverrides: ["ZDOTDIR": "/some/dir"]
        )
    }

    // MARK: - isAvailable

    @Test
    func isAvailableMirrorsEnv() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        #expect(client.isAvailable == true)

        let offline = ZmxClient(env: env(available: false), runner: recorder.runner())
        #expect(offline.isAvailable == false)
    }

    // MARK: - wrap

    @Test
    func wrapProducesZmxAttachCommandWhenAvailable() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        let wrapped = client.wrap(sessionName: "alas-XYZ", plan: samplePlan())

        #expect(wrapped.executable == "/fake/Contents/Resources/zmx/zmx")
        #expect(wrapped.args == ["attach", "alas-XYZ", "/bin/zsh", "-l", "-i"])
    }

    @Test
    func wrapPreservesEnvOverrides() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        let wrapped = client.wrap(sessionName: "alas-XYZ", plan: samplePlan())
        #expect(wrapped.envOverrides == ["ZDOTDIR": "/some/dir"])
    }

    @Test
    func wrapReturnsInputPlanUnchangedWhenZmxUnavailable() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: env(available: false), runner: recorder.runner())
        let input = samplePlan()
        let out = client.wrap(sessionName: "alas-XYZ", plan: input)
        #expect(out == input)
    }

    // MARK: - killSession

    @Test
    func killSessionInvokesZmxKillWithFiveSecondTimeout() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        client.killSession(name: "alas-XYZ")

        #expect(recorder.calls.count == 1)
        let call = recorder.calls[0]
        #expect(call.executable.path == "/fake/Contents/Resources/zmx/zmx")
        #expect(call.args == ["kill", "alas-XYZ"])
        #expect(call.timeout == 5.0)
        // ZMX_DIR is pinned for the cleanup command too.
        #expect(call.env["ZMX_DIR"] == "/tmp/alas-zmx-test")
    }

    @Test
    func killSessionIsNoOpWhenZmxUnavailable() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: env(available: false), runner: recorder.runner())
        client.killSession(name: "alas-XYZ")
        #expect(recorder.calls.isEmpty)
    }

    @Test
    func killSessionSwallowsNonZeroExit() {
        let recorder = RecordingRunner()
        recorder.result = SubprocessRunner.Result(exitCode: 1, stdout: "", stderr: "no such session")
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        // Must not throw, must not crash.
        client.killSession(name: "alas-XYZ")
        #expect(recorder.calls.count == 1)
    }

    @Test
    func killSessionSwallowsTimeout() {
        let recorder = RecordingRunner()
        recorder.result = SubprocessRunner.Result(exitCode: nil, stdout: "", stderr: "")
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        client.killSession(name: "alas-XYZ")
        #expect(recorder.calls.count == 1)
    }

    // MARK: - listSessions

    @Test
    func listSessionsParsesNamesFromStdout() {
        let recorder = RecordingRunner()
        // zmx ls one-name-per-line format (golden sample from real zmx output).
        recorder.result = SubprocessRunner.Result(
            exitCode: 0,
            stdout: "alas-AAA\nalas-BBB\nworkbench\n",
            stderr: ""
        )
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        let names = client.listSessions()
        #expect(names == ["alas-AAA", "alas-BBB", "workbench"])

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].args == ["ls", "--short"])
    }

    @Test
    func listSessionsReturnsEmptyOnNonZeroExit() {
        let recorder = RecordingRunner()
        recorder.result = SubprocessRunner.Result(exitCode: 1, stdout: "garbage", stderr: "boom")
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        #expect(client.listSessions() == [])
    }

    @Test
    func listSessionsReturnsEmptyOnTimeout() {
        let recorder = RecordingRunner()
        recorder.result = SubprocessRunner.Result(exitCode: nil, stdout: "", stderr: "")
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        #expect(client.listSessions() == [])
    }

    @Test
    func listSessionsIsEmptyWhenZmxUnavailable() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: env(available: false), runner: recorder.runner())
        #expect(client.listSessions() == [])
        #expect(recorder.calls.isEmpty)
    }

    @Test
    func listSessionsIgnoresBlankLines() {
        let recorder = RecordingRunner()
        recorder.result = SubprocessRunner.Result(
            exitCode: 0,
            stdout: "alas-AAA\n\n  \nalas-BBB\n",
            stderr: ""
        )
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        #expect(client.listSessions() == ["alas-AAA", "alas-BBB"])
    }

    @Test
    func listSessionInfosParsesFullLsOutput() {
        let recorder = RecordingRunner()
        recorder.result = SubprocessRunner.Result(
            exitCode: 0,
            stdout: """
              name=alas-old-leaf\tpid=25367\tclients=1\tcreated=1779957881\tstart_dir=/Users/nacho/.alas/.worktrees/alas/nacho-new-worktree-acp\tcmd=/bin/zsh -l
              name=alas-other\tpid=25368\tclients=0\tcreated=1779957882\tstart_dir=/Volumes/Workspace/alas\tcmd=/bin/zsh -l -i

            """,
            stderr: ""
        )
        let client = ZmxClient(env: env(available: true), runner: recorder.runner())
        let infos = client.listSessionInfos()

        #expect(infos == [
            ZmxSessionInfo(
                name: "alas-old-leaf",
                startDir: "/Users/nacho/.alas/.worktrees/alas/nacho-new-worktree-acp"
            ),
            ZmxSessionInfo(
                name: "alas-other",
                startDir: "/Volumes/Workspace/alas"
            ),
        ])
        #expect(recorder.calls[0].args == ["ls"])
    }
}
