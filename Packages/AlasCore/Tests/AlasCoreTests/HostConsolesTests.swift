import Foundation
import Testing
@testable import AlasCore
@_spi(Testing) import AlasIntegrations
@_spi(AppHost) @testable import AlasHostCore

@MainActor
struct HostConsolesTests {
    @Test func hostShellNamesAreNeverAlasNames() {
        let name = ZmxSessionName.hostShell(worktreeId: "/srv/feature", consoleId: "c")
        #expect(name.hasPrefix("alashost-"))
        #expect(!ZmxSessionName.isAlasName(name)) // sweeps, Open Sessions, pre-freeze migration
        #expect(ZmxSessionName.parseScoped(name) == nil)
    }

    @Test func aShellLaunchesInTheWorktreeWithTheAgentsPath() throws {
        let zmx = ZmxClient(env: ZmxEnv(binaryURL: URL(fileURLWithPath: "/opt/zmx"), zmxDir: URL(fileURLWithPath: "/tmp/z")))
        let base = [
            "PATH": "/login/bin:/usr/bin", "TERM": "dumb", "TERM_PROGRAM": "Apple_Terminal",
            "ZMX_SESSION": "outer", "HOME": "/Users/u", "CLAUDECODE": "1", "CLAUDE_SESSION_ID": "s",
            "ALAS_APP_SUPPORT_DIR": "/profile", "ALAS_ZMX_BINARY": "/opt/zmx", "ALAS_REMOTE_WEB_DIR": "/web",
        ]
        let launch = try #require(HostShellLaunch.make(
            zmx: zmx, sessionName: "alashost-a-b", directory: URL(fileURLWithPath: "/srv/feature"),
            shell: "/bin/zsh", baseEnvironment: base
        ))
        #expect(launch.executable.path == "/opt/zmx")
        #expect(launch.arguments == ["attach", "alashost-a-b", "/bin/zsh", "-l"])
        #expect(launch.directory.path == "/srv/feature")
        #expect(launch.environment == [
            "PATH": "/login/bin:/usr/bin", "HOME": "/Users/u", "TERM": "xterm-256color",
            "COLORTERM": "truecolor", "ZMX_DIR": "/tmp/z", "LANG": "en_US.UTF-8",
        ])
        // A locale the login environment set is kept as it is.
        let localized = HostShellLaunch.make(
            zmx: zmx, sessionName: "alashost-a-b", directory: URL(fileURLWithPath: "/srv/feature"),
            shell: "/bin/zsh", baseEnvironment: ["LC_CTYPE": "UTF-8"]
        )
        #expect(localized?.environment["LANG"] == nil)
    }

    @Test func zmxIsFoundBesideTheLinkedExecutableElseInTheApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hostconsoles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func executable(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
            return url
        }
        // Homebrew layout: root/bin/alas-host -> root/pkg/alas-host/alas-host, zmx in root/pkg/zmx/zmx.
        _ = try executable("pkg/alas-host/alas-host")
        let pkgZmx = try executable("pkg/zmx/zmx")
        let linked = root.appendingPathComponent("bin/alas-host")
        try fm.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linked.path, withDestinationPath: "../pkg/alas-host/alas-host")
        let bare = try executable("bare/alas-host/alas-host")
        let appZmx = try executable("app/zmx/zmx")
        let missing = root.appendingPathComponent("nowhere/zmx")

        #expect(HostShellLaunch.zmxBinary(executable: linked, fallback: appZmx)?.standardizedFileURL.path
            == pkgZmx.resolvingSymlinksInPath().path)
        #expect(HostShellLaunch.zmxBinary(executable: bare, fallback: appZmx) == appZmx)
        #expect(HostShellLaunch.zmxBinary(executable: bare, fallback: missing) == nil)
        // The override wins, and a missing one means no zmx rather than the fallback.
        #expect(HostShellLaunch.zmxBinary(executable: linked, fallback: appZmx, environment: ["ALAS_ZMX_BINARY": appZmx.path]) == appZmx)
        #expect(HostShellLaunch.zmxBinary(executable: linked, fallback: appZmx, environment: ["ALAS_ZMX_BINARY": missing.path]) == nil)
    }

    // MARK: - Registry

    @Test func openLaunchesAShellAndListsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let id = try await consoles.open(worktreeId: fixture.worktree.id)
        #expect(fixture.launches.map(\.directory) == [fixture.worktree.path])
        let summary = try #require(consoles.summaries().first)
        #expect((summary.consoleId, summary.title, summary.worktreeId, summary.rows, summary.columns, summary.tabIndex)
            == (id, "Terminal 1", fixture.worktree.id, 24, 120, 0))
        #expect(consoles.target(id)?.socketPath == fixture.socketPath(of: id))
    }

    enum Unopenable: CaseIterable { case unknownWorktree, busyWorktree, sshProject, noZmx, launchFails }

    @Test(arguments: Unopenable.allCases)
    func openRefusesWithTheReasonAndRecordsNothing(_ kind: Unopenable) async throws {
        let fixture = try Fixture(host: kind == .sshProject ? "box" : nil, zmxAvailable: kind != .noZmx)
        defer { fixture.tearDown() }
        fixture.fakes.withLock { $0.launchFails = kind == .launchFails }
        if kind == .busyWorktree { fixture.projects.setOperationState(for: fixture.worktree, state: .preparingDelete) }
        let consoles = fixture.consoles()
        let expected: PeerConsoleOpenError = switch kind {
        case .unknownWorktree: .worktreeUnavailable
        case .busyWorktree: .worktreeBusy
        case .sshProject: .sshProject
        case .noZmx: .zmxMissing
        case .launchFails: .notStarted
        }
        let worktreeId = kind == .unknownWorktree ? "nowhere" : fixture.worktree.id

        await #expect(throws: expected) { try await consoles.open(worktreeId: worktreeId) }
        #expect(consoles.summaries().isEmpty)
        #expect(try fixture.savedFile()?.consoles.isEmpty ?? true)
        // A launcher that failed may have forked the daemon already.
        #expect(fixture.killed == fixture.launches.map { $0.arguments[1] })
    }

    enum DuringLaunch: CaseIterable { case removalClaimsIt, removalFinishes }

    /// The launch suspends; a removal that begins or ends meanwhile must not
    /// find the shell missing from its cleanup and then see it registered.
    @Test(arguments: DuringLaunch.allCases)
    func aShellLaunchedWhileItsWorktreeGoesIsKilled(_ during: DuringLaunch) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.fakes.withLock { $0.duringLaunch = during }
        let consoles = fixture.consoles()
        let expected: PeerConsoleOpenError = during == .removalClaimsIt ? .worktreeBusy : .worktreeUnavailable

        await #expect(throws: expected) { try await consoles.open(worktreeId: fixture.worktree.id) }
        #expect(consoles.summaries().isEmpty)
        #expect(try fixture.savedFile()?.consoles.isEmpty ?? true)
        #expect(fixture.killed == fixture.launches.map { $0.arguments[1] })
        #expect(fixture.launches.count == 1)
    }

    @Test func titlesReuseTheLowestFreeNumber() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        var ids: [String] = []
        for _ in 0..<3 { try await ids.append(consoles.open(worktreeId: fixture.worktree.id)) }
        consoles.terminate(ids[1])
        _ = try await consoles.open(worktreeId: fixture.worktree.id)
        #expect(consoles.summaries().map(\.title) == ["Terminal 1", "Terminal 3", "Terminal 2"])
    }

    @Test(arguments: [false, true])
    func restoreDropsShellsWhoseSessionIsGone(lsFails: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let first = try await consoles.open(worktreeId: fixture.worktree.id)
        let second = try await consoles.open(worktreeId: fixture.worktree.id)
        let firstName = try #require(fixture.launches.first?.arguments[1])
        fixture.fakes.withLock {
            $0.live = [firstName]
            $0.lsFails = lsFails
        }

        let restored = fixture.consoles()
        await restored.restore()
        // A failed `zmx ls` proves nothing gone: dropping would orphan the daemons.
        let expected = lsFails ? [first, second] : [first]
        #expect(restored.summaries().map(\.consoleId) == expected)
        #expect(try fixture.savedFile()?.consoles.map(\.id) == expected)
    }

    @Test func listDropsShellsWhoseSocketIsGone() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let id = try await consoles.open(worktreeId: fixture.worktree.id)
        try FileManager.default.removeItem(atPath: #require(fixture.socketPath(of: id)))

        #expect(consoles.summaries().isEmpty)
        #expect(try fixture.savedFile()?.consoles.isEmpty == true)
    }

    @Test func savedShellsSurviveWhileZmxIsMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = try await fixture.consoles().open(worktreeId: fixture.worktree.id)

        // Unknown is not gone: zmx may come back, and its daemons with it.
        let restored = fixture.consoles(zmx: ZmxClient(env: ZmxEnv(binaryURL: nil, zmxDir: fixture.zmxDir)))
        await restored.restore()
        #expect(restored.summaries().map(\.consoleId) == [id])
        #expect(restored.hasConsoles(inWorktrees: [fixture.worktree.id]))
        #expect(try fixture.savedFile()?.consoles.map(\.id) == [id])
    }

    @Test func resizeIsRememberedOnlyWhenZmxTookIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let id = try await consoles.open(worktreeId: fixture.worktree.id)

        fixture.fakes.withLock { $0.sizeApplies = false }
        #expect(await consoles.resize(id, rows: 40, columns: 100) == nil)
        #expect(consoles.target(id).map { [$0.rows, $0.columns] } == [24, 120])

        fixture.fakes.withLock { $0.sizeApplies = true }
        #expect(await consoles.resize(id, rows: 40, columns: 100).map { [$0.rows, $0.columns] } == [40, 100])
        #expect(consoles.target(id).map { [$0.rows, $0.columns] } == [40, 100])
        let names = fixture.launches.map { $0.arguments[1] }
        fixture.fakes.withLock { $0.live = names }
        let restored = fixture.consoles()
        await restored.restore()
        #expect(restored.target(id).map { [$0.rows, $0.columns] } == [40, 100])
        #expect(fixture.fakes.withLock { $0.sizes } == ["40x100", "40x100"])
    }

    @Test func resizesDuringADragApplyOneAtATimeAndTheLatestWins() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let id = try await consoles.open(worktreeId: fixture.worktree.id)
        let fakes = fixture.fakes

        fakes.withLock { $0.holdNextSize = true }
        let first = Task { await consoles.resize(id, rows: 30, columns: 80) }
        try await eventually { fakes.withLock { $0.sizes } == ["30x80"] }
        _ = await consoles.resize(id, rows: 35, columns: 90)
        _ = await consoles.resize(id, rows: 40, columns: 100)
        fakes.release.signal()
        // The geometry broadcast follows what was applied last.
        #expect(await first.value.map { [$0.rows, $0.columns] } == [40, 100])

        #expect(fakes.withLock { $0.maxConcurrentSizes } == 1)
        #expect(fakes.withLock { $0.sizes.last } == "40x100")
        #expect(consoles.target(id).map { [$0.rows, $0.columns] } == [40, 100])
    }

    @Test func terminateKillsTheSessionAndForgetsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let id = try await consoles.open(worktreeId: fixture.worktree.id)
        let zmxName = try #require(fixture.launches.first?.arguments[1])

        consoles.terminate(id)
        #expect(consoles.summaries().isEmpty)
        let fakes = fixture.fakes
        try await eventually { fakes.withLock { $0.killed } == [zmxName] }
    }

    @Test func deletingAWorktreeClosesItsShells() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repo = fixture.root.appendingPathComponent("repo")
        try GitTemplate.repository(at: repo)
        try Self.git(["worktree", "add", "-q", "-b", "feature", fixture.worktree.path.path], in: repo)
        let consoles = fixture.consoles()
        fixture.core.willRemoveWorktree = { await consoles.terminateConsoles(inWorktree: $0) }
        _ = try await consoles.open(worktreeId: fixture.worktree.id)
        let zmxName = try #require(fixture.launches.first?.arguments[1])

        let result = await fixture.core.removeWorktree(WorktreeRemovalRequest(
            worktree: fixture.worktree, repoPath: repo, force: true, deleteBranchIfMerged: false
        ))
        #expect(result == .removed)
        #expect(fixture.killed == [zmxName])
        #expect(try fixture.savedFile()?.consoles.isEmpty == true)
    }

    @Test func aProjectWithAnOpenShellIsNotForgotten() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        fixture.core.hasHostConsoles = { consoles.hasConsoles(inWorktrees: $0) }
        let id = try await consoles.open(worktreeId: fixture.worktree.id)

        await #expect(throws: HostError.projectBusy) { try await fixture.core.removeProject(id: "p") }
        #expect(consoles.summaries().map(\.consoleId) == [id])

        // The shell exits with no peer listing: its socket goes, nothing else.
        try FileManager.default.removeItem(atPath: #require(fixture.socketPath(of: id)))
        try await fixture.core.removeProject(id: "p")
        #expect(fixture.projects.projects.isEmpty)
    }

    /// `project remove` boots a host in process, with or without Remote, and
    /// mutates right away: the saved shells guard it before any restore.
    @Test func aSavedShellGuardsItsProjectAsSoonAsTheHostBoots() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = try await fixture.consoles().open(worktreeId: fixture.worktree.id)

        let consoles = HostConsoles.install(on: fixture.core, zmx: fixture.zmx, fileURL: fixture.file)
        await #expect(throws: HostError.projectBusy) { try await fixture.core.removeProject(id: "p") }
        #expect(consoles.summaries().map(\.consoleId) == [id])
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = arguments
        git.currentDirectoryURL = directory
        try git.run()
        git.waitUntilExit()
        #expect(git.terminationStatus == 0)
    }

    struct Fakes {
        var live: [String] = []
        var killed: [String] = []
        var launches: [HostShellLaunch] = []
        var launchFails = false
        var lsFails = false
        var duringLaunch: DuringLaunch?
        var sizeApplies = true
        var sizes: [String] = []
        /// The next size apply blocks until `release` is signaled.
        var holdNextSize = false
        var concurrentSizes = 0
        var maxConcurrentSizes = 0
    }

    final class SharedFakes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Fakes()
        let release = DispatchSemaphore(value: 0)

        func withLock<R>(_ body: (inout Fakes) throws -> R) rethrows -> R {
            try lock.withLock { try body(&value) }
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let zmxDir: URL
        let projects: ProjectsManager
        let worktree: Worktree
        let core: AlasCoreContext
        let zmx: ZmxClient
        let fakes: SharedFakes
        var file: URL { root.appendingPathComponent("host-consoles.json") }
        var launches: [HostShellLaunch] { fakes.withLock { $0.launches } }
        var killed: [String] { fakes.withLock { $0.killed } }

        init(host: String? = nil, zmxAvailable: Bool = true) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("alas-hostconsoles-\(UUID().uuidString)")
            // Short: zmx socket paths must fit sun_path.
            zmxDir = URL(fileURLWithPath: "/tmp/hc-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: zmxDir, withIntermediateDirectories: true)
            projects = ProjectsManager(persistedProjects: [
                ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast, host: host),
            ])
            let path = root.appendingPathComponent("feature")
            worktree = Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
                path: path, status: .clean, lastActivity: .distantPast
            )
            projects.insertOptimisticWorktree(worktree)
            core = AlasCoreContext(
                projects: projects,
                runHistoryStore: nil,
                workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
                attentionStore: .scratch(),
                orchestrationPersistence: ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
            )
            let fakes = SharedFakes()
            self.fakes = fakes
            let runner = SubprocessRunner { _, args, _, _ in
                switch args.first {
                case "ls":
                    if fakes.withLock({ $0.lsFails }) { return .init(exitCode: 1, stdout: "", stderr: "") }
                    return .init(exitCode: 0, stdout: fakes.withLock { $0.live }.joined(separator: "\n"), stderr: "")
                case "kill":
                    fakes.withLock { $0.killed.append(args[1]) }
                    return .init(exitCode: 0, stdout: "", stderr: "")
                default:
                    return .init(exitCode: 1, stdout: "", stderr: "")
                }
            }
            zmx = ZmxClient(
                env: ZmxEnv(binaryURL: zmxAvailable ? URL(fileURLWithPath: "/opt/zmx") : nil, zmxDir: zmxDir),
                runner: runner
            )
        }

        func consoles(zmx override: ZmxClient? = nil) -> HostConsoles {
            let fakes = fakes
            let zmx = override ?? zmx
            let projects = projects
            let worktree = worktree
            return HostConsoles(
                core: core,
                zmx: zmx,
                fileURL: file,
                launch: { launch in
                    let fails = fakes.withLock {
                        $0.launches.append(launch)
                        return $0.launchFails
                    }
                    if fails { throw PeerConsoleOpenError.notStarted }
                    switch fakes.withLock({ $0.duringLaunch }) {
                    case .removalClaimsIt?:
                        await MainActor.run { projects.setOperationState(for: worktree, state: .preparingDelete) }
                    case .removalFinishes?:
                        await MainActor.run { projects.removeOptimisticWorktree(id: worktree.id, projectId: worktree.projectId) }
                    case nil:
                        break
                    }
                    guard let socket = zmx.socketPath(forSession: launch.arguments[1]) else { throw PeerConsoleOpenError.notStarted }
                    FileManager.default.createFile(atPath: socket, contents: nil)
                },
                applySize: { _, rows, columns in
                    let hold = fakes.withLock {
                        $0.sizes.append("\(rows)x\(columns)")
                        $0.concurrentSizes += 1
                        $0.maxConcurrentSizes = max($0.maxConcurrentSizes, $0.concurrentSizes)
                        let hold = $0.holdNextSize
                        $0.holdNextSize = false
                        return hold
                    }
                    if hold { fakes.release.wait() }
                    return fakes.withLock {
                        $0.concurrentSizes -= 1
                        return $0.sizeApplies
                    }
                },
                baseEnvironment: { [:] },
                shell: "/bin/zsh"
            )
        }

        func socketPath(of consoleId: String) -> String? {
            zmx.socketPath(forSession: ZmxSessionName.hostShell(worktreeId: worktree.id, consoleId: consoleId))
        }

        func savedFile() throws -> HostConsolesFile? {
            try PersistenceStore().readIfExists(HostConsolesFile.self, from: file)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: zmxDir)
        }
    }
}
