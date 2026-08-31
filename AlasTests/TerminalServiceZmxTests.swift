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
    var resultsByFirstArg: [String: SubprocessRunner.Result] = [:]

    func runner() -> SubprocessRunner {
        SubprocessRunner { exe, args, _, _ in
            self.calls.append(Call(executable: exe, args: args))
            if let first = args.first, let result = self.resultsByFirstArg[first] {
                return result
            }
            return SubprocessRunner.Result(exitCode: 0, stdout: "", stderr: "")
        }
    }
}

private final class SlowListRunner: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [RecordingRunner.Call] = []
    private let listDelay: TimeInterval
    private let listResult: SubprocessRunner.Result

    init(listDelay: TimeInterval, listResult: SubprocessRunner.Result) {
        self.listDelay = listDelay
        self.listResult = listResult
    }

    func runner() -> SubprocessRunner {
        SubprocessRunner { exe, args, _, _ in
            self.lock.lock()
            self.calls.append(RecordingRunner.Call(executable: exe, args: args))
            self.lock.unlock()

            if args == ["ls"] {
                Thread.sleep(forTimeInterval: self.listDelay)
                return self.listResult
            }
            return SubprocessRunner.Result(exitCode: 0, stdout: "", stderr: "")
        }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    var callArgs: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.args)
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
            args: [],
            zmxSessionName: ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-abc")
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
            args: [],
            zmxSessionName: ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-xyz")
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
        recorder.resultsByFirstArg["ls"] = .init(exitCode: 0, stdout: "", stderr: "")

        svc.closeSession(id: "nonexistent-id", worktreeId: "wt-1")
        await waitForCalls(recorder, count: 2) { $0.calls.count }
        #expect(recorder.calls.map(\.args) == [
            ["ls"],
            [
            "kill",
            ZmxSessionName.derive(worktreeId: "wt-1", leafId: "nonexistent-id"),
            ],
        ])
    }

    @Test func closeSessionOnUnrestoredLegacySessionKillsScopedAndMatchingLegacyNames() async {
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(
            exitCode: 0,
            stdout: "  name=alas-legacy-leaf\tpid=1\tclients=0\tcreated=1\tstart_dir=/tmp/wt\tcmd=/bin/zsh -l\n",
            stderr: ""
        )
        let svc = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        )

        svc.closeSession(id: "legacy-leaf", worktreeId: "/tmp/wt")
        await waitForCalls(recorder, count: 3) { $0.calls.count }

        #expect(recorder.calls.map(\.args) == [
            ["ls"],
            ["kill", ZmxSessionName.derive(worktreeId: "/tmp/wt", leafId: "legacy-leaf")],
            ["kill", "alas-legacy-leaf"],
        ])
    }

    @Test func closeSessionOnUnrestoredRepoRootLegacySessionKillsLegacyName() async {
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(
            exitCode: 0,
            stdout: "  name=alas-legacy-leaf\tpid=1\tclients=0\tcreated=1\tstart_dir=/tmp/repo/subdir\tcmd=/bin/zsh -l\n",
            stderr: ""
        )
        let svc = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        )

        svc.closeSession(id: "legacy-leaf", worktreeId: "/tmp/wt", projectPath: "/tmp/repo")
        await waitForCalls(recorder, count: 3) { $0.calls.count }

        #expect(recorder.calls.map(\.args) == [
            ["ls"],
            ["kill", ZmxSessionName.derive(worktreeId: "/tmp/wt", leafId: "legacy-leaf")],
            ["kill", "alas-legacy-leaf"],
        ])
    }

    @Test func legacySessionOwnershipAcceptsRepoRootStartDir() {
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(
            exitCode: 0,
            stdout: "  name=alas-legacy-leaf\tpid=1\tclients=0\tcreated=1\tstart_dir=/tmp/repo/subdir\tcmd=/bin/zsh -l\n",
            stderr: ""
        )
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())

        let belongs = TerminalService.legacySessionBelongsToKnownRoot(
            ZmxSessionName.legacy(leafId: "legacy-leaf"),
            roots: ["/tmp/repo-linked-worktree", "/tmp/repo"],
            zmxClient: client
        )

        #expect(belongs)
        #expect(recorder.calls.map(\.args) == [["ls"]])
    }

    @Test func legacySessionOwnershipRejectsSiblingRepoRootStartDir() {
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(
            exitCode: 0,
            stdout: "  name=alas-legacy-leaf\tpid=1\tclients=0\tcreated=1\tstart_dir=/tmp/repo-other\tcmd=/bin/zsh -l\n",
            stderr: ""
        )
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())

        let belongs = TerminalService.legacySessionBelongsToKnownRoot(
            ZmxSessionName.legacy(leafId: "legacy-leaf"),
            roots: ["/tmp/repo-linked-worktree", "/tmp/repo"],
            zmxClient: client
        )

        #expect(!belongs)
        #expect(recorder.calls.map(\.args) == [["ls"]])
    }

    @Test func resolveSessionNameForAttachUsesPreloadedLegacyInfo() {
        let infos = [
            ZmxSessionInfo(
                name: "alas-legacy-leaf",
                startDir: "/tmp/repo/subdir",
                pid: 1,
                clients: 0,
                created: 1,
                cmd: "/bin/zsh -l"
            ),
        ]

        let name = TerminalService.resolveSessionNameForAttach(
            worktreeId: "/tmp/wt",
            projectPath: "/tmp/repo",
            leafId: "legacy-leaf",
            allowLegacy: true,
            legacySessionInfos: infos
        )

        #expect(name == "alas-legacy-leaf")
    }

    @Test func resolveSessionNameForAttachFallsBackToScopedName() {
        let name = TerminalService.resolveSessionNameForAttach(
            worktreeId: "/tmp/wt",
            projectPath: "/tmp/repo",
            leafId: "legacy-leaf",
            allowLegacy: true,
            legacySessionInfos: [
                ZmxSessionInfo(
                    name: "alas-legacy-leaf",
                    startDir: "/tmp/repo-other",
                    pid: 1,
                    clients: 0,
                    created: 1,
                    cmd: "/bin/zsh -l"
                ),
            ]
        )

        #expect(name == ZmxSessionName.derive(worktreeId: "/tmp/wt", leafId: "legacy-leaf"))
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
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(exitCode: 0, stdout: "", stderr: "")
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
        await waitForCalls(recorder, count: 3) { $0.calls.count }

        let allArgs = Set(recorder.calls.map(\.args))
        #expect(allArgs == Set([
            ["ls"],
            ["kill", ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-A")],
            ["kill", ZmxSessionName.derive(worktreeId: "wt-2", leafId: "leaf-persisted-B")],
        ]))
    }

    @Test
    func terminateAllKillsRepoRootLegacyAdditionalLeaves() async {
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(
            exitCode: 0,
            stdout: "  name=alas-leaf-persisted-B\tpid=1\tclients=0\tcreated=1\tstart_dir=/tmp/repo\tcmd=/bin/zsh -l\n",
            stderr: ""
        )
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        let service = TerminalService(zmxClient: client)

        service.terminateAll(additionalSessions: [
            TerminalSessionIdentity(
                worktreeId: "/tmp/wt",
                projectPath: "/tmp/repo",
                leafId: "leaf-persisted-B"
            ),
        ])
        await waitForCalls(recorder, count: 3) { $0.calls.count }

        #expect(Set(recorder.calls.map(\.args)) == Set([
            ["ls"],
            ["kill", ZmxSessionName.derive(worktreeId: "/tmp/wt", leafId: "leaf-persisted-B")],
            ["kill", "alas-leaf-persisted-B"],
        ]))
    }

    @Test
    func terminateAllKillsPersistedCheckoutOwnerLeavesWithoutLiveRegistryEntries() async {
        let checkoutID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .local)
        let leafID = "checkout-leaf"
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(exitCode: 0, stdout: "", stderr: "")
        let service = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        )

        service.terminateAll(additionalSessions: [
            TerminalSessionIdentity(owner: owner, leafId: leafID),
        ])
        await waitForCalls(recorder, count: 2) { $0.calls.count }

        #expect(Set(recorder.calls.map(\.args)) == Set([
            ["ls"],
            ["kill", ZmxSessionName.derive(owner: owner, leafId: leafID)],
        ]))
    }

    @Test
    func terminateAllDeduplicatesRegistryAndAdditional() async {
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(exitCode: 0, stdout: "", stderr: "")
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
        await waitForCalls(recorder, count: 2) { $0.calls.count }
        #expect(recorder.calls.map(\.args) == [
            [
                "kill",
                ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-A"),
            ],
            ["ls"],
        ])
    }

    @Test
    func terminateAllDoesNotBlockCallerWhileResolvingAdditionalLegacySessions() async {
        let runner = SlowListRunner(
            listDelay: 0.35,
            listResult: .init(
                exitCode: 0,
                stdout: """
                  name=alas-leaf-persisted-A\tpid=1\tclients=0\tcreated=1\tstart_dir=/tmp/repo\tcmd=/bin/zsh -l
                  name=alas-leaf-persisted-B\tpid=2\tclients=0\tcreated=1\tstart_dir=/tmp/repo/subdir\tcmd=/bin/zsh -l

                """,
                stderr: ""
            )
        )
        let client = ZmxClient(env: makeZmxEnv(available: true), runner: runner.runner())
        let service = TerminalService(zmxClient: client)

        let started = Date()
        service.terminateAll(additionalSessions: [
            TerminalSessionIdentity(worktreeId: "/tmp/wt", projectPath: "/tmp/repo", leafId: "leaf-persisted-A"),
            TerminalSessionIdentity(worktreeId: "/tmp/wt", projectPath: "/tmp/repo", leafId: "leaf-persisted-B"),
        ])
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 0.15)

        await waitForCalls(runner, count: 1, timeout: 0.15) { $0.callCount }
        let expectedFirstKills = Set([
            [
                "kill",
                ZmxSessionName.derive(worktreeId: "/tmp/wt", leafId: "leaf-persisted-A"),
            ],
            [
                "kill",
                ZmxSessionName.derive(worktreeId: "/tmp/wt", leafId: "leaf-persisted-B"),
            ],
        ])
        #expect(runner.callArgs.first.map { expectedFirstKills.contains($0) } == true)

        await waitForCalls(runner, count: 5, timeout: 2.0) { $0.callCount }
        #expect(runner.callArgs.filter { $0 == ["ls"] }.count == 1)
        #expect(Set(runner.callArgs) == Set([
            ["ls"],
            ["kill", ZmxSessionName.derive(worktreeId: "/tmp/wt", leafId: "leaf-persisted-A")],
            ["kill", "alas-leaf-persisted-A"],
            ["kill", ZmxSessionName.derive(worktreeId: "/tmp/wt", leafId: "leaf-persisted-B")],
            ["kill", "alas-leaf-persisted-B"],
        ]))
    }

    // MARK: sweepOrphans — boot-time cleanup

    @Test
    func orphanFilterKillsOnlyOurWorktreeWithUnknownLeaf() {
        let mineWtA = "wt-A"
        let mineWtB = "wt-B"
        let mineLeaf = "leaf-keep"
        let unknownLeaf = "leaf-stranded"

        let mineWtAHash = ZmxSessionName.hash16(mineWtA)
        let mineWtBHash = ZmxSessionName.hash16(mineWtB)
        let foreignHash = ZmxSessionName.hash16("wt-not-ours")
        let mineLeafHash = ZmxSessionName.hash16(mineLeaf)
        let unknownLeafHash = ZmxSessionName.hash16(unknownLeaf)

        let names = [
            "alas-\(mineWtAHash)-\(mineLeafHash)",       // ours, still referenced — keep
            "alas-\(mineWtAHash)-\(unknownLeafHash)",    // ours, orphan — kill
            "alas-\(mineWtBHash)-\(unknownLeafHash)",    // different wt of ours, orphan — kill
            "alas-\(foreignHash)-\(unknownLeafHash)",    // another Alas instance — never touch
            "alas-leaf-legacy-uuid-shape",                // legacy form — sweep ignores
            "not-an-alas-session",                        // unrelated — ignore
        ]

        let orphans = TerminalService.orphanSessionNames(
            allSessionNames: names,
            knownWorktreeIdHashes: [mineWtAHash, mineWtBHash],
            knownLeafIdHashes: [mineLeafHash]
        )

        #expect(Set(orphans) == Set([
            "alas-\(mineWtAHash)-\(unknownLeafHash)",
            "alas-\(mineWtBHash)-\(unknownLeafHash)",
        ]))
    }

    @Test
    func orphanFilterStripsZmxSessionPrefixBeforeMatching() {
        let mineWt = "wt-1"
        let mineWtHash = ZmxSessionName.hash16(mineWt)
        let foreignHash = ZmxSessionName.hash16("wt-not-ours")
        let unknownLeafHash = ZmxSessionName.hash16("leaf-stranded")

        // With ZMX_SESSION_PREFIX=team-, zmx ls prefixes every session
        // name. The filter must strip the prefix before parseScoped, and
        // return bare names so callers can hand them to zmx kill (which
        // re-prepends the prefix itself).
        let names = [
            "team-alas-\(mineWtHash)-\(unknownLeafHash)",     // ours, orphan — kill (bare form)
            "team-alas-\(foreignHash)-\(unknownLeafHash)",    // another instance — skip
            "alas-\(mineWtHash)-\(unknownLeafHash)",          // no prefix — not from this run, skip
            "team-not-alas",                                    // prefixed but not scoped — skip
        ]

        let orphans = TerminalService.orphanSessionNames(
            allSessionNames: names,
            knownWorktreeIdHashes: [mineWtHash],
            knownLeafIdHashes: [],
            sessionPrefix: "team-"
        )

        #expect(orphans == ["alas-\(mineWtHash)-\(unknownLeafHash)"])
    }

    @Test
    func workspaceCheckoutOrphanFilterUsesCheckoutOwnerAndLeafIdentity() {
        let checkoutID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .ssh("build-host"))
        let knownLeaf = "leaf-keep"
        let unknownLeaf = "leaf-stranded"
        let foreignOwner = SessionOwnerID.workspaceCheckout(UUID(), .ssh("build-host"))
        let knownName = ZmxSessionName.derive(owner: owner, leafId: knownLeaf)
        let orphanName = ZmxSessionName.derive(owner: owner, leafId: unknownLeaf)
        let foreignName = ZmxSessionName.derive(owner: foreignOwner, leafId: unknownLeaf)

        let orphans = TerminalService.orphanWorkspaceSessionNames(
            allSessionNames: [
                "team-\(knownName)",
                "team-\(orphanName)",
                "team-\(foreignName)",
                knownName,
                "team-alas-\(ZmxSessionName.hash16("wt"))-\(ZmxSessionName.hash16("leaf"))",
            ],
            knownLeavesByOwner: [owner: [knownLeaf]],
            sessionPrefix: "team-"
        )

        #expect(orphans == [orphanName])
    }

    @Test
    func workspaceCheckoutOrphanFilterIncludesOwnersWithNoKnownLeaves() {
        let checkoutID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .local)
        let orphanName = ZmxSessionName.derive(owner: owner, leafId: "stranded-leaf")
        let foreignName = ZmxSessionName.derive(owner: .workspaceCheckout(UUID(), .local), leafId: "stranded-leaf")

        let orphans = TerminalService.orphanWorkspaceSessionNames(
            allSessionNames: [orphanName, foreignName],
            knownLeavesByOwner: [owner: []],
            sessionPrefix: ""
        )

        #expect(orphans == [orphanName])
    }

    @Test
    func sweepOrphansIssuesKillsForFilteredNames() async {
        let mineWt = "wt-1"
        let mineLeaf = "leaf-keep"
        let mineWtHash = ZmxSessionName.hash16(mineWt)
        let foreignHash = ZmxSessionName.hash16("wt-not-ours")
        let unknownLeafHash = ZmxSessionName.hash16("leaf-stranded")
        let recorder = RecordingRunner()
        recorder.resultsByFirstArg["ls"] = .init(
            exitCode: 0,
            stdout: """
            alas-\(mineWtHash)-\(ZmxSessionName.hash16(mineLeaf))
            alas-\(mineWtHash)-\(unknownLeafHash)
            alas-\(foreignHash)-\(unknownLeafHash)
            """,
            stderr: ""
        )
        let service = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        )

        service.sweepOrphans(
            knownWorktreeIds: [mineWt],
            knownLeafIds: [mineLeaf]
        )
        await waitForCalls(recorder, count: 2) { $0.calls.count }

        // Expect `ls --short` then exactly one kill for the our-wt-but-unknown-leaf entry.
        #expect(recorder.calls.map(\.args) == [
            ["ls", "--short"],
            ["kill", "alas-\(mineWtHash)-\(unknownLeafHash)"],
        ])
    }

    // MARK: waitForPendingKills — quit drain

    @Test
    func waitForPendingKillsBlocksUntilDispatchedKillCompletes() {
        let started = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        let recorder = RecordingRunner()
        // Replace runner so the kill subprocess parks until we let it
        // through, simulating a slow daemon round-trip. The drain MUST
        // observe completion before returning, otherwise a Cmd-Q would
        // again abandon the in-flight task.
        let stallRunner = SubprocessRunner { exe, args, _, _ in
            recorder.calls.append(.init(executable: exe, args: args))
            started.signal()
            _ = unblock.wait(timeout: .now() + 5.0)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        let svc = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: true), runner: stallRunner)
        )

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "leaf-drain",
            worktreeId: "wt-1",
            projectId: "proj-1",
            surface: surface,
            executable: "/bin/zsh",
            args: [],
            zmxSessionName: ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-drain")
        )
        svc.registry.register(session)
        svc.closeSession(id: "leaf-drain", worktreeId: "wt-1")
        // The detached task should have entered the runner by now.
        _ = started.wait(timeout: .now() + 2.0)

        // Drain runs on a background awaiter so the @MainActor task that
        // removes the completed task from the tracking set can schedule
        // even though the test thread is calling waitForPendingKills.
        Thread.detachNewThread {
            // Let the subprocess return shortly after the drain begins,
            // proving the wait actually observed the task's completion
            // (rather than just timing out).
            Thread.sleep(forTimeInterval: 0.1)
            unblock.signal()
        }
        let start = Date()
        svc.waitForPendingKills(timeout: 2.0)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 1.5, "drain should return when the kill completes, not at timeout")
        #expect(recorder.calls.map(\.args) == [["kill", "alas-\(ZmxSessionName.hash16("wt-1"))-\(ZmxSessionName.hash16("leaf-drain"))"]])
    }

    @Test
    func waitForPendingKillsReturnsImmediatelyWhenNothingPending() {
        let recorder = RecordingRunner()
        let svc = TerminalService(
            zmxClient: ZmxClient(env: makeZmxEnv(available: true), runner: recorder.runner())
        )

        let start = Date()
        svc.waitForPendingKills(timeout: 5.0)
        #expect(Date().timeIntervalSince(start) < 0.1)
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

    // MARK: open-sessions wrappers

    @Test func loadOpenSessionsClassifiesAgainstRegistry() async {
        let recorder = RecordingRunner()
        let activeName = ZmxSessionName.derive(worktreeId: "wt-1", leafId: "leaf-abc")
        recorder.resultsByFirstArg["ls"] = SubprocessRunner.Result(
            exitCode: 0,
            stdout: """
              name=\(activeName)\tpid=1\tclients=1\tcreated=1779957881\tstart_dir=/work/active\tcmd=/bin/zsh -l
              name=alas-aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb\tpid=2\tclients=0\tcreated=1779957882\tstart_dir=/work/orphan\tcmd=/bin/zsh

            """,
            stderr: ""
        )
        let svc = TerminalService(zmxClient: ZmxClient(env: makeZmxEnv(), runner: recorder.runner()))
        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        svc.registry.register(TerminalSession(
            id: "leaf-abc", worktreeId: "wt-1", projectId: "proj-1",
            surface: surface, executable: "/bin/zsh", args: [],
            zmxSessionName: activeName
        ))

        let snap = await svc.loadOpenSessions()

        #expect(snap.active.map(\.name) == [activeName])
        #expect(snap.active.first?.kind == .active(leafId: "leaf-abc", worktreeId: "wt-1"))
        #expect(snap.orphaned.map(\.name) == ["alas-aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb"])
        #expect(snap.orphaned.first?.isIdle == true)
    }

    @Test func killOrphanSessionRunsZmxKill() async {
        let recorder = RecordingRunner()
        let svc = TerminalService(zmxClient: ZmxClient(env: makeZmxEnv(), runner: recorder.runner()))

        svc.killOrphanSession(name: "alas-aaaa-1111")
        svc.waitForPendingKills(timeout: 2.0)

        #expect(recorder.calls.contains(.init(
            executable: URL(fileURLWithPath: "/fake/Contents/Resources/zmx/zmx"),
            args: ["kill", "alas-aaaa-1111"]
        )))
    }

    @Test func killIdleOrphansKillsOnlyIdleRows() async {
        let recorder = RecordingRunner()
        let svc = TerminalService(zmxClient: ZmxClient(env: makeZmxEnv(), runner: recorder.runner()))
        let snap = OpenSessionsSnapshot(active: [], orphaned: [
            OpenSessionRow(name: "alas-idle-1", kind: .orphanIdle, startDir: nil, cmd: nil, clients: 0, created: nil),
            OpenSessionRow(name: "alas-busy-1", kind: .orphanInUse, startDir: nil, cmd: nil, clients: 2, created: nil),
            OpenSessionRow(name: "alas-idle-2", kind: .orphanIdle, startDir: nil, cmd: nil, clients: 0, created: nil),
        ])

        svc.killIdleOrphans(snap)
        svc.waitForPendingKills(timeout: 2.0)

        let killed = Set(recorder.calls.filter { $0.args.first == "kill" }.map { $0.args[1] })
        #expect(killed == ["alas-idle-1", "alas-idle-2"])
    }
}
