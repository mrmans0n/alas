import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStatePersistenceTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private struct FailingStore: PersistenceStoreProtocol {
        let error = NSError(
            domain: "AppStatePersistenceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "write rejected"]
        )

        func write<T: Encodable>(_: T, to _: URL) throws {
            throw error
        }

        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
            nil
        }
    }

    private final class RecordingStore: PersistenceStoreProtocol, @unchecked Sendable {
        let initialProjectsFile: ProjectsFile
        var writtenProjectsFile: ProjectsFile?

        init(initialProjectsFile: ProjectsFile) {
            self.initialProjectsFile = initialProjectsFile
        }

        func write<T: Encodable>(_ value: T, to _: URL) throws {
            if let projectsFile = value as? ProjectsFile {
                writtenProjectsFile = projectsFile
            }
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            type == ProjectsFile.self ? initialProjectsFile as? T : nil
        }
    }

    @Test func missionBaseReferenceNormalizesOnlyKnownRemoteAliases() {
        #expect(MissionBaseReference.remoteName(
            in: "upstream/main",
            knownRemoteNames: ["origin", "upstream"]
        ) == "upstream")
        #expect(MissionBaseReference.remoteName(
            in: "release/1.0",
            knownRemoteNames: ["origin", "upstream"]
        ) == nil)
        #expect(MissionBaseReference.resolveLegacyRemoteName(
            in: "upstream/main",
            knownRemoteNames: ["canonical"],
            branchNames: ["main", "canonical/main"]
        ) == "upstream")
        #expect(MissionBaseReference.resolveLegacyRemoteName(
            in: "release/1.0",
            knownRemoteNames: ["origin"],
            branchNames: ["origin/release/1.0"]
        ) == "")
        #expect(MissionBaseReference.branchName(
            "origin/main",
            persistedRemoteName: "origin"
        ) == "main")
        #expect(MissionBaseReference.branchName(
            "upstream/feature/release",
            persistedRemoteName: "upstream"
        ) == "feature/release")
        #expect(MissionBaseReference.branchName(
            "release/1.0",
            persistedRemoteName: nil
        ) == "release/1.0")
    }

    @Test func missionReviewRemoteUsesPersistedProviderForEnterpriseHost() throws {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.example.com",
            repositorySlug: "acme/alas",
            number: 42
        )

        let remote = try #require(AppState.missionReviewRemote(
            identity: identity,
            baseRef: "origin/main",
            remotes: [GitRemote(name: "origin", url: "git@github.example.com:acme/alas.git")]
        ))

        #expect(remote.kind == .github)
        #expect(remote.host == identity.host)
        #expect(remote.repositorySlug == identity.repositorySlug)
    }

    @Test func missionBranchOwnerPrefersTheBranchTrackingRemote() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )
        let remotes = [
            GitRemote(name: "origin", url: "git@github.com:acme/alas.git"),
            GitRemote(name: "fork", url: "git@github.com:nacho/alas.git"),
        ]

        let owner = AppState.missionBranchOwner(
            identity: identity,
            baseRef: "origin/main",
            branchRemoteName: "fork",
            remotes: remotes
        )

        #expect(owner == "nacho")
    }

    @Test func missionBranchOwnerAcceptsRenamedForkTrackingRemote() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )
        let remotes = [
            GitRemote(name: "origin", url: "git@github.com:acme/alas.git"),
            GitRemote(name: "fork", url: "git@github.com:nacho/renamed-alas.git"),
        ]

        let owner = AppState.missionBranchOwner(
            identity: identity,
            baseRef: "origin/main",
            branchRemoteName: "fork",
            remotes: remotes
        )

        #expect(owner == "nacho")
    }

    @Test func missionBranchOwnerPrefersTheBranchTrackingRemotePushURL() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )
        let remotes = [
            GitRemote(name: "origin", url: "git@github.com:acme/alas.git"),
            GitRemote(name: "origin", url: "git@github.com:nacho/alas.git", direction: .push),
        ]

        let owner = AppState.missionBranchOwner(
            identity: identity,
            baseRef: "origin/main",
            branchRemoteName: "origin",
            remotes: remotes
        )

        #expect(owner == "nacho")
    }

    @Test func missionBranchOwnerPrefersOriginPushURLWithoutTrackingRemote() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )
        let remotes = [
            GitRemote(name: "origin", url: "git@github.com:acme/alas.git"),
            GitRemote(name: "origin", url: "git@github.com:nacho/alas.git", direction: .push),
        ]

        let owner = AppState.missionBranchOwner(
            identity: identity,
            baseRef: "origin/main",
            branchRemoteName: "",
            remotes: remotes
        )

        #expect(owner == "nacho")
    }

    @Test func missionBranchOwnerFallsBackToTheBaseRemote() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )
        let remotes = [GitRemote(name: "origin", url: "git@github.com:acme/alas.git")]

        let owner = AppState.missionBranchOwner(
            identity: identity,
            baseRef: "origin/main",
            branchRemoteName: "",
            remotes: remotes
        )

        #expect(owner == "acme")
    }

    @Test func saveConfigReportsWriteFailure() {
        var reports: [(title: String, message: String)] = []
        let state = AppState(store: FailingStore()) { title, message in
            reports.append((title, message))
        }

        let saved = state.saveConfig()

        #expect(saved == false)
        #expect(reports.map(\.title) == ["Settings Save Failed"])
        #expect(reports.first?.message == "write rejected")
    }

    @Test func saveProjectsReportsWriteFailure() {
        var reports: [(title: String, message: String)] = []
        let state = AppState(store: FailingStore()) { title, message in
            reports.append((title, message))
        }

        let saved = state.saveProjects()

        #expect(saved == false)
        #expect(reports.map(\.title) == ["Projects Save Failed"])
        #expect(reports.first?.message == "write rejected")
    }

    @Test func deletedWorktreeOverrideIsRemovedAndPersistedBeforeTopologyRefresh() throws {
        let persistedProject = ProjectConfig(
            id: "project",
            name: "Alas",
            path: "/tmp/alas",
            color: "teal",
            addedAt: .now
        )
        let store = RecordingStore(
            initialProjectsFile: ProjectsFile(projects: [persistedProject])
        )
        let state = AppState(store: store)
        state.projectsManager.setGGWorktreeMode(
            projectId: persistedProject.id,
            worktreeId: "deleted-worktree",
            mode: .on
        )

        state.removePersistedGGWorktreeMode(
            projectId: persistedProject.id,
            worktreeId: "deleted-worktree"
        )

        #expect(state.projectsManager.ggWorktreeMode(
            projectId: persistedProject.id,
            worktreeId: "deleted-worktree"
        ) == .inherit)
        #expect(store.writtenProjectsFile?.projects.first?.ggWorktreeModes.isEmpty == true)
    }

    @Test func shortcutOverridesPersistThroughSaveAndReload() throws {
        let state = AppState(store: MemoryStore())
        state.setShortcut(ShortcutBinding(key: "o", modifiers: [.command]), for: .searchFiles)
        state.setShortcut(nil, for: .switchRepository)
        // Reload by encoding/decoding via AppConfig (mirrors what disk does).
        let data = try JSONEncoder().encode(state.config)
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(reloaded.shortcutOverrides[ShortcutAction.searchFiles.rawValue] ==
                .some(ShortcutBinding(key: "o", modifiers: [.command])))
        #expect(reloaded.shortcutOverrides[ShortcutAction.switchRepository.rawValue] == .some(nil))
    }

    @Test func languageServerRegistryRefreshesOnlyWhenLanguageServersChange() {
        var tracker = AppState.LanguageServerConfigChangeTracker(
            initial: AppConfig.defaults.code.languageServers
        )

        var widthOnlyConfig = AppConfig.defaults
        widthOnlyConfig.sidebarWidth = 300
        #expect(tracker.consumeChange(in: widthOnlyConfig) == false)

        var languageServerConfig = widthOnlyConfig
        languageServerConfig.code.languageServers = [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "/usr/bin/sourcekit-lsp",
                args: [],
                env: [:],
                rootMarkers: ["Package.swift"],
                enabled: true
            )
        ]
        #expect(tracker.consumeChange(in: languageServerConfig) == true)
        #expect(tracker.consumeChange(in: languageServerConfig) == false)
    }

    @Test func archivingMissionWorktreeRecordsExplicitReadySignal() async throws {
        let project = Self.project
        let persistence = try Self.makeMissionPersistence()
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence
        )
        let worktree = Self.worktree
        state.projectsManager.insertOptimisticWorktree(worktree)
        await state.missions.load()

        state.archiveWorktree(worktree)
        let aggregate = try await Self.waitForMissionState(.readyToComplete, persistence: persistence)

        #expect(state.projectsManager.isWorktreeHidden(projectId: project.id, path: worktree.path))
        #expect(aggregate.events.last?.kind == .ready)
        #expect(aggregate.events.last?.message == "Worktree archived in Alas.")
    }

    @Test func archivingMissionWorktreeRecordsReadyBeforeSelectionCleanup() async throws {
        let project = Self.project
        let persistence = try Self.makeMissionPersistence()
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence
        )
        let worktree = Self.worktree
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.selectedWorktreeId = worktree.id
        await state.missions.load()

        state.archiveWorktree(worktree)

        #expect(state.projectsManager.isWorktreeHidden(projectId: project.id, path: worktree.path))
        #expect(state.selectedWorktreeId == worktree.id)

        _ = try await Self.waitForMissionState(.readyToComplete, persistence: persistence)
        #expect(state.selectedWorktreeId == nil)
    }

    @Test func deferredMissionArchiveKeepsANewerSelection() async throws {
        let project = Self.project
        let persistence = try Self.makeMissionPersistence()
        let recorder = ArchiveRecorderGate()
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence,
            missionArchiveRecorder: { _ in await recorder.waitForRelease() }
        )
        let worktree = Self.worktree
        let other = Self.otherWorktree
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.projectsManager.insertOptimisticWorktree(other)
        state.tabs.appendTerminal(worktreeId: worktree.id, title: "term", sessionId: "session")
        state.selectedWorktreeId = worktree.id
        await state.missions.load()

        state.archiveWorktree(worktree)
        await recorder.waitUntilStarted()
        state.selectedWorktreeId = other.id
        await recorder.release()
        let tabsClosed = await Self.waitForTabsToClose(worktreeId: worktree.id, state: state)

        #expect(tabsClosed)
        #expect(state.selectedWorktreeId == other.id)
    }

    @Test func deferredMissionArchiveDoesNothingAfterUnarchive() async throws {
        let project = Self.project
        let persistence = try Self.makeMissionPersistence()
        let recorder = ArchiveRecorderGate()
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence,
            missionArchiveRecorder: { _ in await recorder.waitForRelease() }
        )
        let worktree = Self.worktree
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.tabs.appendTerminal(worktreeId: worktree.id, title: "term", sessionId: "session")
        state.selectedWorktreeId = worktree.id
        await state.missions.load()

        state.archiveWorktree(worktree)
        await recorder.waitUntilStarted()
        state.unarchiveWorktree(projectId: project.id, path: worktree.path)
        await recorder.release()
        await Task.yield()
        await Task.yield()

        #expect(state.projectsManager.isWorktreeHidden(projectId: project.id, path: worktree.path) == false)
        #expect(state.tabs.tabs(forWorktree: worktree.id).count == 1)
        #expect(state.selectedWorktreeId == worktree.id)
        let aggregate = try #require(try await persistence.aggregate(id: MissionID(rawValue: "mission-1")))
        #expect(aggregate.mission.state == .running)
    }

    @Test func startupMissionReconciliationLoadsMergedReviewBeforePaneCreation() async throws {
        let project = Self.project
        let worktree = Self.worktree
        let persistence = try Self.makeMissionPersistence()
        var requestedWorktreeIDs: [String] = []
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence,
            missionStartupReviewSnapshot: { worktree, baseRef in
                requestedWorktreeIDs.append(worktree.id)
                #expect(baseRef == "origin/main")
                return Self.mergedReviewSnapshot()
            },
            missionBranchTipOverride: { projectID, branch in
                #expect(projectID == project.id)
                #expect(branch == worktree.branch)
                return "abc123"
            }
        )
        state.projectsManager.insertOptimisticWorktree(worktree)

        #expect(state.rightPaneStore.reviewSnapshot(
            worktreeId: worktree.id,
            baseBranch: state.config.worktrees.baseBranch
        ) == nil)
        await state.reconcileMissionsForStartup()
        let aggregate = try await Self.waitForMissionState(.readyToComplete, persistence: persistence)

        #expect(requestedWorktreeIDs == [worktree.id])
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 91)
    }

    @Test func removingMissionProjectRecordsAttentionWithoutDeletingMission() async throws {
        let project = Self.project
        let persistence = try Self.makeMissionPersistence()
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence
        )
        await state.missions.load()

        #expect(state.removeProject(id: project.id))
        let aggregate = try await Self.waitForMissionState(.needsAttention, persistence: persistence)

        #expect(aggregate.mission.attentionReason == "The Mission project is no longer available.")
        #expect(aggregate.issue.identity == MissionFixtures.issue().identity)
        #expect(aggregate.primaryLeg?.projectId == project.id)
    }

    private static let project = ProjectConfig(
        id: "project-1",
        name: "Alas",
        path: "/tmp/alas",
        color: "teal",
        addedAt: Date(timeIntervalSince1970: 100)
    )

    private static let worktree = Worktree(
        id: "worktree-1",
        projectId: "project-1",
        name: "fix/parser-crash",
        branch: "fix/parser-crash",
        path: URL(fileURLWithPath: "/tmp/alas-mission"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 100)
    )

    private static let otherWorktree = Worktree(
        id: "worktree-2",
        projectId: "project-1",
        name: "other",
        branch: "other",
        path: URL(fileURLWithPath: "/tmp/alas-other"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 100)
    )

    private static func makeMissionPersistence() throws -> MissionPersistence {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.mission.setupCheckpoint = .running
        aggregate.legs[0].worktreeId = worktree.id
        aggregate.legs[0].acpSessionId = "session-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-state-mission-\(UUID().uuidString).sqlite")
            .path
        let store = try MissionStore(path: path)
        try store.insert(aggregate)
        return MissionPersistence(path: path)
    }

    private static func waitForMissionState(
        _ state: MissionState,
        persistence: MissionPersistence
    ) async throws -> MissionAggregate {
        for _ in 0..<100 {
            if let aggregate = try await persistence.aggregate(id: MissionID(rawValue: "mission-1")),
               aggregate.mission.state == state {
                return aggregate
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(try await persistence.aggregate(id: MissionID(rawValue: "mission-1")))
    }

    private static func waitForTabsToClose(worktreeId: String, state: AppState) async -> Bool {
        for _ in 0..<100 {
            if state.tabs.tabs(forWorktree: worktreeId).isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return state.tabs.tabs(forWorktree: worktreeId).isEmpty
    }

    private static func mergedReviewSnapshot() -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "acme",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/acme/alas")!
        )
        return ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "fix/parser-crash",
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: true,
                needsPush: false
            ),
            remote: remote,
            reviewRequest: ReviewRequest(
                remote: remote,
                number: 91,
                title: "Mission review",
                url: URL(string: "https://github.com/acme/alas/pull/91")!,
                state: .merged,
                isDraft: false,
                headRefName: "fix/parser-crash",
                baseRefName: "main",
                headSHA: "abc123",
                reviewDecision: .approved,
                mergeState: .clean,
                checks: [],
                threads: []
            ),
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .readOnly,
            errorMessage: nil
        )
    }
}

@MainActor
private final class ArchiveRecorderGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        started = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
