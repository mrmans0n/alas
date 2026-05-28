import Foundation
import Testing
@testable import Alas

// MARK: - Test doubles (shared in this file)

/// Captures every subprocess call so tests can assert exact zmx invocations.
private final class RecordingRunner: @unchecked Sendable {
    struct Call: Equatable {
        let executable: URL
        let args: [String]
    }
    var calls: [Call] = []

    func runner() -> SubprocessRunner {
        SubprocessRunner { exe, args, _, _ in
            self.calls.append(Call(executable: exe, args: args))
            return SubprocessRunner.Result(exitCode: 0, stdout: "", stderr: "")
        }
    }
}

private func makeZmxEnv(available: Bool = true) -> ZmxEnv {
    ZmxEnv(
        binaryURL: available
            ? URL(fileURLWithPath: "/fake/Contents/Resources/zmx/zmx")
            : nil,
        zmxDir: URL(fileURLWithPath: "/tmp/alas-zmx-test")
    )
}

/// `TerminalService.closeSession` and `terminateAll` dispatch the zmx
/// subprocess work to `Task.detached`, so tests need to wait for the
/// recorded calls to materialize before asserting on them.
private func waitForCalls<R>(
    _ recorder: R,
    count: Int,
    timeout: TimeInterval = 2.0,
    countOf: @escaping (R) -> Int
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while countOf(recorder) < count, Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

// MARK: - Tests

@Suite(.serialized)
@MainActor
struct TerminalServiceZmxTests {
    // MARK: init

    @Test func initAcceptsCustomZmxClient() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: makeZmxEnv(), runner: recorder.runner())
        let svc = TerminalService(zmxClient: client)
        #expect(svc.zmxClient === client)
    }

    // MARK: closeSession — registry cleanup

    @Test func closeSessionUnregistersSession() {
        let recorder = RecordingRunner()
        let svc = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: false), runner: recorder.runner())
        )

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "leaf-abc",
            worktreeId: "wt-1",
            projectId: "proj-1",
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        svc.registry.register(session)
        #expect(svc.registry.session(for: "leaf-abc") != nil)

        svc.closeSession(id: "leaf-abc", worktreeId: "wt-1")

        #expect(svc.registry.session(for: "leaf-abc") == nil)
    }

    // MARK: closeSession — zmx kill

    @Test func closeSessionInvokesZmxKillWithDerivedName() async {
        let recorder = RecordingRunner()
        let svc = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        )

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "leaf-xyz",
            worktreeId: "wt-1",
            projectId: "proj-1",
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        svc.registry.register(session)

        svc.closeSession(id: "leaf-xyz", worktreeId: "wt-1")
        await waitForCalls(recorder, count: 1) { $0.calls.count }

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].args == [
            "kill",
            ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-xyz"),
        ])
    }

    @Test func closeSessionIsNoOpForZmxKillWhenUnavailable() {
        let recorder = RecordingRunner()
        let svc = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: false), runner: recorder.runner())
        )

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "leaf-absent",
            worktreeId: "wt-1",
            projectId: "proj-1",
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        svc.registry.register(session)

        svc.closeSession(id: "leaf-absent", worktreeId: "wt-1")

        // Registry must be cleaned up even when zmx is unavailable.
        #expect(svc.registry.session(for: "leaf-absent") == nil)
        // No subprocess must be spawned.
        #expect(recorder.calls.isEmpty)
    }

    @Test func closeSessionOnUnknownIdDoesNotCrash() async {
        let recorder = RecordingRunner()
        let svc = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        )
        // Should not throw or crash — zmx kill is still attempted for cleanup.
        svc.closeSession(id: "nonexistent-id", worktreeId: "wt-1")
        await waitForCalls(recorder, count: 1) { $0.calls.count }
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].args == [
            "kill",
            ZmxSessionName.derive(worktreeId: "wt-1", leafId: "nonexistent-id"),
        ])
    }

    // MARK: detachAll

    @Test
    func detachAllDoesNotInvokeKill() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        let service = TerminalService(zmxClient: client)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "leaf-detach",
            worktreeId: "wt-1",
            projectId: "proj-1",
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        service.registry.register(session)

        service.detachAll()

        #expect(recorder.calls.isEmpty)
        // detach does not remove sessions from the registry either.
        #expect(service.registry.session(for: "leaf-detach") != nil)
    }

    // MARK: terminateAll

    @Test
    func terminateAllKillsRegistryAndAdditionalLeaves() async {
        // Use the standard recorder (no scripted ls output): the new
        // terminateAll does not enumerate `zmx ls` at all, so we should
        // see ONLY kill calls — none for `ls`.
        let recorder = RecordingRunner()
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        let service = TerminalService(zmxClient: client)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "leaf-A",
            worktreeId: "wt-1",
            projectId: "proj-1",
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        service.registry.register(session)

        // Pass one persisted-but-not-registered leaf id; expect both to
        // be killed and nothing else.
        service.terminateAll(additionalSessions: [
            TerminalSessionIdentity(worktreeId: "wt-2", leafId: "leaf-persisted-B"),
        ])
        await waitForCalls(recorder, count: 2) { $0.calls.count }

        let allArgs = Set(recorder.calls.map(\.args))
        #expect(allArgs == Set([
            ["kill", ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-A")],
            ["kill", ZmxSessionName.derive(worktreeId: "wt-2", leafId: "leaf-persisted-B")],
        ]))
        // No `ls` invocation — we no longer enumerate zmx's session list
        // to avoid touching another live Alas instance's sessions.
        #expect(recorder.calls.contains(where: { $0.args.first == "ls" }) == false)
    }

    @Test
    func terminateAllDeduplicatesRegistryAndAdditional() async {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        let service = TerminalService(zmxClient: client)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "leaf-A",
            worktreeId: "wt-1",
            projectId: "proj-1",
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        service.registry.register(session)

        // leaf-A is in both registry and additionals — should still kill once.
        service.terminateAll(additionalSessions: [
            TerminalSessionIdentity(worktreeId: "wt-1", leafId: "leaf-A"),
        ])
        await waitForCalls(recorder, count: 1) { $0.calls.count }
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].args == [
            "kill",
            ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-A"),
        ])
    }

    // MARK: resolveLaunchPlan — keepSessionsAlive gating

    @Test func resolveLaunchPlanWrapsWhenKeepAliveTrueAndZmxAvailable() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        let inner = StartupScriptInstaller.Plan(
            executable: "/bin/zsh", args: ["-l"], envOverrides: ["FOO": "1"]
        )

        let plan = TerminalService.resolveLaunchPlan(
            keepAlive: true,
            zmxClient: client,
            sessionName: ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-1"),
            innerPlan: inner
        )

        #expect(plan.executable == "/fake/Contents/Resources/zmx/zmx")
        #expect(plan.args == [
            "attach",
            ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-1"),
            "/bin/zsh",
            "-l",
        ])
        #expect(plan.envOverrides == ["FOO": "1"])
    }

    @Test func resolveLaunchPlanReturnsInnerWhenKeepAliveFalse() {
        let recorder = RecordingRunner()
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        let inner = StartupScriptInstaller.Plan(
            executable: "/bin/zsh", args: ["-l"], envOverrides: ["FOO": "1"]
        )

        let plan = TerminalService.resolveLaunchPlan(
            keepAlive: false,
            zmxClient: client,
            sessionName: ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-2"),
            innerPlan: inner
        )

        // With the setting off, the inner plan is returned untouched —
        // no zmx in the executable, no extra args, env preserved.
        #expect(plan.executable == "/bin/zsh")
        #expect(plan.args == ["-l"])
        #expect(plan.envOverrides == ["FOO": "1"])
        // No subprocess must be spawned — the guard short-circuits before
        // any zmx command runs.
        #expect(recorder.calls.isEmpty)
    }

    @Test func resolveLaunchPlanReturnsInnerWhenZmxUnavailable() {
        // keepAlive=true, but zmx binary missing: ZmxClient.wrap returns the
        // input plan unchanged. The helper must propagate that behavior.
        let recorder = RecordingRunner()
        let client = ZmxClient(env: makeZmxEnv(available: false), runner: recorder.runner())
        let inner = StartupScriptInstaller.Plan(
            executable: "/bin/zsh", args: [], envOverrides: [:]
        )

        let plan = TerminalService.resolveLaunchPlan(
            keepAlive: true,
            zmxClient: client,
            sessionName: ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-3"),
            innerPlan: inner
        )

        #expect(plan.executable == "/bin/zsh")
        #expect(plan.args == [])
        #expect(recorder.calls.isEmpty)
    }
}
