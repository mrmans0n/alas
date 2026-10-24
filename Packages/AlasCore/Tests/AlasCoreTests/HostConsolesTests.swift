import Foundation
import Testing
@testable import AlasCore
@_spi(Testing) import AlasIntegrations
@_spi(AppHost) @_spi(Testing) @testable import AlasHostCore

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
    @Test(arguments: DuringLaunch.allCases, [false, true])
    func aShellLaunchedWhileItsWorktreeGoesIsKilled(_ during: DuringLaunch, isRun: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.fakes.withLock { $0.duringLaunch = during }
        let consoles = fixture.consoles()
        let expected: PeerConsoleOpenError = during == .removalClaimsIt ? .worktreeBusy : .worktreeUnavailable

        if isRun {
            (fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
            let script = try fixture.runScript(onExit: .keep)
            guard case .started = fixture.core.startRun(script, in: fixture.worktree) else {
                Issue.record("The run did not start")
                return
            }
            await fixture.core.waitForStartingRunsForTesting()
            // Never started: the previous (no) record is put back.
            #expect(fixture.core.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key) == nil)
            let launch = try #require(fixture.launches.first)
            #expect(!fixture.rcFilesExist(of: launch))
        } else {
            await #expect(throws: expected) { try await consoles.open(worktreeId: fixture.worktree.id) }
        }
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
        await consoles.terminate(ids[1])
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

    /// A shell is forgotten only once zmx stopped it; one whose kill failed
    /// stays listed, so the user can try again.
    @Test(arguments: [false, true])
    func terminateKillsTheSessionAndForgetsIt(killFails: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let id = try await consoles.open(worktreeId: fixture.worktree.id)
        let zmxName = try #require(fixture.launches.first?.arguments[1])
        fixture.fakes.withLock { $0.killFails = killFails }

        await consoles.terminate(id)
        #expect(fixture.killed == [zmxName])
        let expected = killFails ? [id] : []
        #expect(consoles.summaries().map(\.consoleId) == expected)
        #expect(try fixture.savedFile()?.consoles.map(\.id) == expected)
    }

    /// Deleting a worktree closes its shells first; one zmx can't stop
    /// (here, zmx is missing) refuses the delete and leaves everything as it was.
    @Test(arguments: [true, false])
    func deletingAWorktreeClosesItsShells(zmxFound: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repo = fixture.root.appendingPathComponent("repo")
        try GitTemplate.repository(at: repo)
        try Self.git(["worktree", "add", "-q", "-b", "feature", fixture.worktree.path.path], in: repo)
        let id = try await fixture.consoles().open(worktreeId: fixture.worktree.id)
        let zmxName = try #require(fixture.launches.first?.arguments[1])
        let zmx = zmxFound ? fixture.zmx : ZmxClient(env: ZmxEnv(binaryURL: nil, zmxDir: fixture.zmxDir))
        _ = HostConsoles.install(on: fixture.core, zmx: zmx, fileURL: fixture.file)

        let result = await fixture.core.removeWorktree(WorktreeRemovalRequest(
            worktree: fixture.worktree, repoPath: repo, force: true, deleteBranchIfMerged: false
        ))
        if zmxFound {
            #expect(result == .removed)
            #expect(fixture.killed == [zmxName])
            #expect(try fixture.savedFile()?.consoles.isEmpty == true)
        } else {
            #expect(result == .failed("Close this worktree's terminals first; the host couldn't stop them."))
            #expect(try fixture.savedFile()?.consoles.map(\.id) == [id])
            #expect(FileManager.default.fileExists(atPath: fixture.worktree.path.path))
        }
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

    // MARK: - Runs

    @Test func aConsolesFileFromBeforeRunsReadsAsShells() throws {
        let json = #"{"consoles":[{"id":"c","worktreeId":"w","title":"Terminal 1","zmxName":"alashost-a-b","rows":24,"columns":120}]}"#
        let file = try JSONDecoder().decode(HostConsolesFile.self, from: Data(json.utf8))
        #expect(file.consoles.map(\.scriptKey) == [nil])
    }

    @Test func aRunLaunchesInAShellThatSourcesTheCapturedCommand() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        (fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .keep)
        guard case .started(let runID) = fixture.core.startRun(script, in: fixture.worktree) else {
            Issue.record("The run did not start")
            return
        }
        await fixture.core.waitForStartingRunsForTesting()

        let launch = try #require(fixture.launches.first)
        #expect(Array(launch.arguments.dropFirst(2)) == ["/bin/zsh", "-l", "-i"])
        let rc = try String(contentsOfFile: #require(launch.environment["ZDOTDIR"]) + "/.zshrc", encoding: .utf8)
        #expect(rc.contains("__alas_run_script_capture") && rc.contains(script.fileURL.path))
        let record = try #require(fixture.core.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key))
        let summary = try #require(consoles.summaries().first)
        #expect((record.sessionID, summary.title) == (summary.consoleId, "Dev"))
        #expect(try fixture.savedFile()?.consoles.map(\.scriptKey) == [script.key])

        try fixture.complete(runID: runID, exitCode: 0)
        let core = fixture.core
        let worktreeID = fixture.worktree.id
        try await eventually { await core.runRecords.record(worktreeID: worktreeID, scriptKey: script.key)?.status == .finished(.succeeded) }
        #expect(consoles.summaries().map(\.consoleId) == [summary.consoleId]) // keep: the console stays
    }

    /// zmx's `attach` fails when the command exits before it connects, though
    /// the command ran: the run settles by its completion, not as never started.
    @Test func aRunWhoseAttachFailsSettlesByItsCompletion() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.fakes.withLock { $0.launchFails = true }
        let consoles = fixture.consoles()
        (fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .close)
        guard case .started(let runID) = fixture.core.startRun(script, in: fixture.worktree) else {
            Issue.record("The run did not start")
            return
        }
        try fixture.complete(runID: runID, exitCode: 3)
        await fixture.core.waitForStartingRunsForTesting()

        #expect(fixture.killed == fixture.launches.map { $0.arguments[1] })
        #expect(consoles.summaries().isEmpty)
        let launch = try #require(fixture.launches.first)
        #expect(!fixture.rcFilesExist(of: launch))
        let core = fixture.core
        let worktreeID = fixture.worktree.id
        try await eventually {
            await core.runRecords.record(worktreeID: worktreeID, scriptKey: script.key)?.status == .finished(.failed(exitCode: 3))
        }
    }

    enum Ending: CaseIterable { case stop, rerun }

    /// Stopping a run, or running it again over its kept console, ends the
    /// console it ran in, so a script never has two.
    @Test(arguments: Ending.allCases)
    func stoppingOrRerunningARunEndsItsConsole(_ ending: Ending) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        (fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .keep)
        guard case .started(let runID) = fixture.core.startRun(script, in: fixture.worktree) else {
            Issue.record("The run did not start")
            return
        }
        await fixture.core.waitForStartingRunsForTesting()
        let first = try #require(consoles.summaries().first?.consoleId)
        let firstName = try #require(fixture.launches.first?.arguments[1])
        let core = fixture.core
        let worktreeID = fixture.worktree.id
        switch ending {
        case .stop:
            core.stopRun(scriptKey: script.key, in: fixture.worktree)
        case .rerun:
            try fixture.complete(runID: runID, exitCode: 0)
            try await eventually { await core.runRecords.record(worktreeID: worktreeID, scriptKey: script.key)?.status == .finished(.succeeded) }
            _ = core.startRun(script, in: fixture.worktree)
            await core.waitForStartingRunsForTesting()
        }

        let fakes = fixture.fakes
        try await eventually { fakes.withLock { $0.killed.first } == firstName }
        let expected = ending == .stop ? 0 : 1
        try await eventually { await MainActor.run { consoles.summaries().count == expected && !consoles.summaries().contains { $0.consoleId == first } } }
        if ending == .stop {
            #expect(core.runRecords.record(worktreeID: worktreeID, scriptKey: script.key)?.status == .finished(.stopped))
        }
    }

    @Test func aSecondStartWhileARunConsoleIsLiveIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        (fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .keep)
        guard case .started = fixture.core.startRun(script, in: fixture.worktree) else {
            Issue.record("The run did not start")
            return
        }
        await fixture.core.waitForStartingRunsForTesting()
        let live = consoles.summaries().map(\.consoleId)

        #expect(fixture.core.startRun(script, in: fixture.worktree)
            == .refused(title: "Run Script Failed", message: "Dev is already running."))
        await fixture.core.waitForStartingRunsForTesting()
        #expect(fixture.killed.isEmpty)
        #expect(consoles.summaries().map(\.consoleId) == live)
    }

    /// Ids come from host-consoles.json; a malformed one must not reach
    /// outside its own rc files.
    @Test(arguments: ["", "..", "../rcfiles"])
    func cleaningUpAMalformedIdKeepsOtherRcFiles(_ id: String) throws {
        let sibling = Paths.appSupportRoot.appendingPathComponent("rcfiles/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }

        StartupScriptInstaller.removeArtifacts(sessionId: id)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    /// A rerun replaces the script's kept console; one zmx can't stop stays
    /// the script's only console, and the rerun is refused.
    @Test func aRunWhosePreviousConsoleCantBeStoppedIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let core = fixture.core
        (core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .keep)
        let first = try await fixture.finishedKeptRun(script, consoles: consoles)
        fixture.fakes.withLock { $0.killFails = true }

        var settlement: RunScriptSettlement?
        _ = core.startRun(script, in: fixture.worktree, onSettled: { settlement = $0 })
        await core.waitForStartingRunsForTesting()
        try await eventually { await MainActor.run { settlement != nil } }
        #expect(settlement == .launchFailed("The previous run of Dev couldn't be stopped; terminate its console and try again."))
        #expect(fixture.launches.count == 1)
        #expect(consoles.summaries().map(\.consoleId) == [first])
    }

    /// Stopped while it was still preparing, a run never starts its shell.
    @Test func aRunStoppedWhilePreparingNeverLaunches() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        let core = fixture.core
        (core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .keep)
        _ = try await fixture.finishedKeptRun(script, consoles: consoles)
        let fakes = fixture.fakes
        fakes.withLock { $0.holdKill = true }

        _ = core.startRun(script, in: fixture.worktree)
        // Preparing: stopping the earlier console.
        try await eventually { fakes.withLock { $0.killed.count } == 1 }
        core.stopRun(scriptKey: script.key, in: fixture.worktree)
        fakes.release.signal()
        try await eventually { await MainActor.run { core.stoppingRuns.isEmpty } }
        #expect(fixture.launches.count == 1)
    }

    /// With no peer listing consoles, a run whose console died without
    /// reporting completion still settles.
    @Test func aRunConsoleThatDiesUnwatchedSettlesItsRun() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles(pruneInterval: .milliseconds(20))
        (fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .keep)
        guard case .started = fixture.core.startRun(script, in: fixture.worktree) else {
            Issue.record("The run did not start")
            return
        }
        await fixture.core.waitForStartingRunsForTesting()
        let record = try #require(fixture.core.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key))
        let sessionID = try #require(record.sessionID)
        try FileManager.default.removeItem(atPath: #require(fixture.socketPath(of: sessionID)))

        let core = fixture.core
        let worktreeID = fixture.worktree.id
        try await eventually { await core.runRecords.record(worktreeID: worktreeID, scriptKey: script.key)?.status == .finished(.unknown) }
        #expect(try fixture.savedFile()?.consoles.isEmpty == true)
    }

    /// A peer terminates a console whose run is still going: the run settles.
    @Test func terminatingARunConsoleSettlesItsRun() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles()
        (fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .keep)
        guard case .started = fixture.core.startRun(script, in: fixture.worktree) else {
            Issue.record("The run did not start")
            return
        }
        await fixture.core.waitForStartingRunsForTesting()
        let consoleId = try #require(consoles.summaries().first?.consoleId)

        await consoles.terminate(consoleId)
        let core = fixture.core
        let worktreeID = fixture.worktree.id
        try await eventually { await core.runRecords.record(worktreeID: worktreeID, scriptKey: script.key)?.status == .finished(.unknown) }
    }

    enum NoConsole: CaseIterable { case noZmx, fish }

    @Test(arguments: NoConsole.allCases)
    func withoutZmxOrAnInjectableShellARunIsAPlainProcess(_ kind: NoConsole) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let consoles = fixture.consoles(
            zmx: kind == .noZmx ? ZmxClient(env: ZmxEnv(binaryURL: nil, zmxDir: fixture.zmxDir)) : nil,
            shell: kind == .fish ? "/opt/homebrew/bin/fish" : "/bin/zsh"
        )
        (fixture.core.environment as! HeadlessHostEnvironment).runLauncherOverride = consoles
        let script = try fixture.runScript(onExit: .close)

        #expect(try await fixture.core.runScript(script, in: fixture.worktree) == .succeeded)
        #expect(fixture.launches.isEmpty)
        #expect(consoles.summaries().isEmpty)
        #expect(fixture.core.runRecords.record(worktreeID: fixture.worktree.id, scriptKey: script.key)?.sessionID == nil)
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
        var killFails = false
        /// The next kill blocks until `release` is signaled.
        var holdKill = false
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
                // Short enough for `eventually`, not zero: an already-written
                // `.done` wins over the idle check.
                runHostGrace: RunHostGrace(local: .milliseconds(200), any: .milliseconds(200)),
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
                    let (fails, hold) = fakes.withLock { fakes in
                        fakes.killed.append(args[1])
                        let hold = fakes.holdKill
                        fakes.holdKill = false
                        return (fakes.killFails, hold)
                    }
                    if hold { fakes.release.wait() }
                    return .init(exitCode: fails ? 1 : 0, stdout: "", stderr: "")
                default:
                    return .init(exitCode: 1, stdout: "", stderr: "")
                }
            }
            zmx = ZmxClient(
                env: ZmxEnv(binaryURL: zmxAvailable ? URL(fileURLWithPath: "/opt/zmx") : nil, zmxDir: zmxDir),
                runner: runner
            )
        }

        func consoles(zmx override: ZmxClient? = nil, shell: String = "/bin/zsh", pruneInterval: Duration = .seconds(60)) -> HostConsoles {
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
                shell: shell,
                pruneInterval: pruneInterval
            )
        }

        func runScript(onExit: RunScriptOnExit) throws -> RunScript {
            let url = worktree.path.appendingPathComponent(".alas/scripts/dev.sh")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "exit 0\n".write(to: url, atomically: true, encoding: .utf8)
            return RunScript(
                scope: .repo, fileName: "dev.sh", fileURL: url, displayName: "Dev",
                onExit: onExit, cwd: nil, isExecutable: false
            )
        }

        func complete(runID: String, exitCode: Int32) throws {
            let path = try RunScriptCompletionMonitor.paths(runID: runID, host: nil).paths.completion
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(exitCode)\t1.0\n".write(to: url, atomically: true, encoding: .utf8)
        }

        /// Runs a keep script to completion; its console stays. Returns it.
        func finishedKeptRun(_ script: RunScript, consoles: HostConsoles) async throws -> String {
            guard case .started(let runID) = core.startRun(script, in: worktree) else { throw CancellationError() }
            await core.waitForStartingRunsForTesting()
            try complete(runID: runID, exitCode: 0)
            let core = core
            let worktreeID = worktree.id
            try await eventually { await core.runRecords.record(worktreeID: worktreeID, scriptKey: script.key)?.status == .finished(.succeeded) }
            return try #require(consoles.summaries().first?.consoleId)
        }

        func rcFilesExist(of launch: HostShellLaunch) -> Bool {
            launch.environment["ZDOTDIR"].map { FileManager.default.fileExists(atPath: $0) } ?? false
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
