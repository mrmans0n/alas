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
        #expect(MissionBaseReference.remoteName(
            in: "team/origin/main",
            knownRemoteNames: ["team", "team/origin"]
        ) == "team/origin")
        #expect(MissionBaseReference.resolveLegacyRemoteName(
            in: "upstream/main",
            knownRemoteNames: ["canonical"],
            localBranchNames: ["main"],
            branchNames: ["main", "canonical/main"]
        ) == "upstream")
        #expect(MissionBaseReference.resolveLegacyRemoteName(
            in: "release/1.0",
            knownRemoteNames: ["origin"],
            localBranchNames: [],
            branchNames: ["origin/release/1.0"]
        ) == "")
        #expect(MissionBaseReference.resolveLegacyRemoteName(
            in: "release/1.0",
            knownRemoteNames: ["origin", "release"],
            localBranchNames: ["release/1.0"],
            branchNames: ["release/1.0", "origin/release/1.0"]
        ) == "")
        #expect(MissionBaseReference.resolveLegacyRemoteName(
            in: "team/origin/main",
            knownRemoteNames: ["team", "team/origin"],
            localBranchNames: [],
            branchNames: ["team/origin/main"]
        ) == "team/origin")
        #expect(MissionBaseReference.branchName(
            "origin/main",
            persistedRemoteName: "origin"
        ) == "main")
        #expect(MissionBaseReference.branchName(
            "upstream/feature/release",
            persistedRemoteName: "upstream"
        ) == "feature/release")
        #expect(MissionBaseReference.branchName(
            "team/origin/main",
            persistedRemoteName: "team/origin"
        ) == "main")
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

    @Test func missionReviewRemotePrefersTheLongestMatchingAlias() throws {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )
        let remote = try #require(AppState.missionReviewRemote(
            identity: identity,
            baseRef: "team/origin/main",
            remotes: [
                GitRemote(name: "team", url: "git@github.com:acme/alas.git"),
                GitRemote(name: "team/origin", url: "git@github.com:acme/alas.git"),
            ]
        ))

        #expect(remote.remoteName == "team/origin")
    }

    @Test func missionReviewRemoteRejectsForkWhenConfiguredBaseRemoteExists() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "nacho/alas",
            number: 42
        )

        let remote = AppState.missionReviewRemote(
            identity: identity,
            baseRef: "upstream/main",
            persistedRemoteName: "upstream",
            remotes: [
                GitRemote(name: "origin", url: "git@github.com:nacho/alas.git"),
                GitRemote(name: "upstream", url: "git@github.com:acme/alas.git"),
            ]
        )

        #expect(remote == nil)
    }

    @Test func missionReviewRemoteRepairsStaleConfiguredBaseAlias() throws {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )

        let remote = try #require(AppState.missionReviewRemote(
            identity: identity,
            baseRef: "origin/main",
            persistedRemoteName: "origin",
            remotes: [GitRemote(name: "upstream", url: "git@github.com:acme/alas.git")]
        ))

        #expect(remote.remoteName == "upstream")
    }

    @Test func missionReviewRemoteDoesNotGuessStaleBaseAliasWhenMultipleRemotesExist() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )

        let remote = AppState.missionReviewRemote(
            identity: identity,
            baseRef: "origin/main",
            persistedRemoteName: "origin",
            remotes: [
                GitRemote(name: "fork", url: "git@github.com:nacho/alas.git"),
                GitRemote(name: "upstream", url: "git@github.com:acme/alas.git"),
            ]
        )

        #expect(remote == nil)
    }

    @Test func missionPaneBaseRefDoesNotGuessStaleBaseAliasWhenMultipleRemotesExist() {
        let baseRef = AppState.missionPaneBaseRef(
            baseRef: "origin/main",
            persistedRemoteName: "origin",
            remotes: [
                GitRemote(name: "fork", url: "git@github.com:nacho/alas.git"),
                GitRemote(name: "upstream", url: "git@github.com:acme/alas.git"),
            ],
            supportedKinds: [.github]
        )

        #expect(baseRef == "origin/main")
    }

    @Test func missionDiscoveryRemoteUsesTheTargetProjectRepository() throws {
        let remote = try #require(AppState.missionDiscoveryRemote(
            baseRef: "origin/main",
            remotes: [
                GitRemote(name: "origin", url: "git@github.com:acme/sdk.git"),
                GitRemote(name: "issue", url: "git@github.com:acme/alas.git"),
            ],
            supportedKinds: [.github, .gitlab]
        ))

        #expect(remote.remoteName == "origin")
        #expect(remote.repositorySlug == "acme/sdk")
    }

    @Test func missionDiscoveryUsesQualifiedBaseForRemoteAndStrippedBranchForProvider() {
        #expect(AppState.missionDiscoveryBaseBranch(
            baseRef: "upstream/main",
            remoteName: "upstream"
        ) == "main")
    }

    @Test func missionIssueQueryUsesPersistedSlugSoProviderCanFollowRenameRedirect() throws {
        let current = try #require(CodeHostRemoteDetector.detect(
            from: [GitRemote(name: "origin", url: "git@github.com:acquired/renamed-alas.git")],
            matching: .github
        ))
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )

        let query = AppState.missionIssueQueryRemote(identity: identity, candidates: [current])

        #expect(query.repositorySlug == "acme/alas")
        #expect(query.host == "github.com")
        #expect(query.remoteName == "origin")
        #expect(query.webURL == URL(string: "https://github.com/acme/alas"))
    }

    @Test func missionIssueQueryKeepsAnExactCurrentRemote() throws {
        let current = try #require(CodeHostRemoteDetector.detect(
            from: [GitRemote(name: "upstream", url: "git@gitlab.example.com:platform/mobile/alas.git")],
            matching: .gitlab
        ))
        let identity = MissionIssueIdentity(
            provider: .gitlab,
            host: "gitlab.example.com",
            repositorySlug: "platform/mobile/alas",
            number: 77
        )

        let query = AppState.missionIssueQueryRemote(identity: identity, candidates: [current])

        #expect(query == current)
    }

    @Test func startupCanonicalRefreshIsLimitedToSameHostSlugChanges() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )

        #expect(AppState.missionRepositoryNeedsCanonicalRefresh(
            identity: identity,
            remotes: [GitRemote(name: "origin", url: "git@github.com:acquired/renamed-alas.git")]
        ))
        #expect(!AppState.missionRepositoryNeedsCanonicalRefresh(
            identity: identity,
            remotes: [GitRemote(name: "origin", url: "git@github.com:acme/alas.git")]
        ))
        #expect(!AppState.missionRepositoryNeedsCanonicalRefresh(
            identity: identity,
            remotes: [GitRemote(name: "origin", url: "git@gitlab.com:acquired/renamed-alas.git")]
        ))
    }

    @Test func openMissionDoesNotChangeSelectedWorktree() async throws {
        let fixture = try MissionGlobalNavigationFixture(includeWorktree: true)
        fixture.state.selectedWorktreeId = fixture.otherWorktree.id
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        #expect(try result.get() == .mission(MissionTabState.fixture))
        #expect(fixture.state.selectedWorktreeId == fixture.otherWorktree.id)
        #expect(fixture.state.globalTabs.activeMissionTab() == .fixture)
    }

    @Test func selectingWorktreeClearsActiveGlobalMissionWithoutClosingIt() async throws {
        let fixture = try MissionGlobalNavigationFixture(includeWorktree: true)
        await fixture.state.missions.load()
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()

        fixture.state.selectWorktree(id: fixture.otherWorktree.id)

        #expect(fixture.state.selectedWorktreeId == fixture.otherWorktree.id)
        #expect(fixture.state.globalTabs.activeMissionTab() == nil)
        #expect(fixture.state.globalTabs.tabs == [.mission(.fixture)])
    }

    @Test func openingWorktreeACPSessionClearsActiveGlobalMission() throws {
        let fixture = try MissionGlobalNavigationFixture(includeWorktree: true)
        fixture.state.selectWorktree(id: fixture.otherWorktree.id)
        fixture.state.globalTabs.openOrFocusMission(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )

        fixture.state.openNewACPSession(agentID: "test-agent")

        #expect(fixture.state.globalTabs.activeMissionTab() == nil)
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.otherWorktree.id) != nil)
    }

    @Test func selectingInitialWorktreePreservesRestoredGlobalMission() async throws {
        let fixture = try MissionGlobalNavigationFixture(includeWorktree: true)
        await fixture.state.missions.load()
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()

        fixture.state.selectInitialWorktree(id: fixture.otherWorktree.id)

        #expect(fixture.state.selectedWorktreeId == fixture.otherWorktree.id)
        #expect(fixture.state.globalTabs.activeMissionTab() == .fixture)
    }

    @Test func centerShortcutsRouteThroughGlobalMissionOwnership() throws {
        let fixture = try MissionGlobalNavigationFixture(includeWorktree: true)
        let terminal = fixture.state.tabs.appendTerminal(
            worktreeId: fixture.otherWorktree.id,
            title: "Shell",
            sessionId: "session-1"
        )
        fixture.state.globalTabs.openOrFocusMission(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )

        #expect(fixture.state.activateCenterTabNumber(1, worktreeId: fixture.otherWorktree.id) == MissionTabState.fixture.id)
        #expect(fixture.state.globalTabs.activeMissionTab() == .fixture)
        #expect(fixture.state.activateCenterTabNumber(2, worktreeId: fixture.otherWorktree.id) == terminal.id)
        #expect(fixture.state.globalTabs.activeMissionTab() == nil)

        fixture.state.globalTabs.activate(tabId: MissionTabState.fixture.id)
        fixture.state.handleCloseCenterShortcut(worktreeId: fixture.otherWorktree.id)

        #expect(fixture.state.globalTabs.tabs.isEmpty)
        #expect(fixture.state.tabs.tabs(forWorktree: fixture.otherWorktree.id) == [terminal])
    }

    @Test func reloadTabsPreservesGlobalMissionWhenWorktreeIsMissing() throws {
        let fixture = try MissionGlobalNavigationFixture(includeWorktree: false)
        fixture.state.globalTabs.openOrFocusMission(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )

        fixture.state.reloadTabs()

        #expect(fixture.state.globalTabs.activeMissionTab() == .fixture)
        let orphanedTabs = fixture.state.tabs.tabs(forWorktree: fixture.worktree.id)
        #expect(orphanedTabs.count == 1)
        if let first = orphanedTabs.first, case .terminal = first {
            // The migration scans the unavailable worktree's persisted file,
            // extracts only its Mission tab, and preserves ordinary tabs.
        } else {
            Issue.record("Expected the orphaned terminal tab to survive Mission migration")
        }
    }

    @Test func closingMissingMissionGlobalTabClearsRecoveryPresentation() async throws {
        let fixture = try MissionGlobalNavigationFixture(includeWorktree: false)
        await fixture.state.missions.load()
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()

        fixture.state.closeGlobalTab(tabId: MissionTabState.fixture.id)

        #expect(fixture.state.globalTabs.activeMissionTab() == nil)
        #expect(fixture.state.missingMissionTab == nil)
    }

    @Test func migratedMissionTabRemainsGlobalAcrossAnSDKOnlySpace() async throws {
        let fixture = try MissionCrossSpaceNavigationFixture()
        let store = PersistenceStore()
        try store.write(
            TabsFile(
                version: 1,
                tabs: [.mission(.crossRepoFixture)],
                activeTabId: MissionTabState.crossRepoFixture.id
            ),
            to: fixture.tabsDirectory.appendingPathComponent("\(fixture.appWorktree.id).json")
        )
        let worktreeTabs = TabsManager(tabsDirectory: fixture.tabsDirectory)
        worktreeTabs.loadAll(worktreeIds: [fixture.appWorktree.id, fixture.sdkWorktree.id])
        let globalTabs = GlobalTabsManager(fileURL: fixture.globalTabsFile)

        try globalTabs.loadAndMigrate(worktreeTabs: worktreeTabs)

        #expect(worktreeTabs.tabs(forWorktree: fixture.appWorktree.id).isEmpty)
        #expect(globalTabs.tabs == [.mission(.crossRepoFixture)])

        let state = fixture.makeState(globalTabs: globalTabs)
        await state.missions.load()
        #expect(state.switchToSpace(id: "sdk-space"))
        #expect(state.activeSpaceProjects.map(\.id) == ["sdk-project"])
        #expect(globalTabs.tabs == [.mission(.crossRepoFixture)])

        globalTabs.activate(tabId: MissionTabState.crossRepoFixture.id)
        let aggregate = try #require(state.missions.aggregate(id: fixture.aggregate.mission.id))
        let presentation = MissionAggregateSummary(
            aggregate: aggregate,
            legs: aggregate.legs.map { leg in
                MissionLegPresentation(
                    aggregate: aggregate,
                    leg: leg,
                    worktree: state.projectsManager.worktrees(projectId: leg.projectId)
                        .first(where: { $0.id == leg.worktreeId })
                )
            }
        )

        #expect(globalTabs.activeMissionTab() == .crossRepoFixture)
        #expect(presentation.legs.map(\.id) == [.app, .sdk])
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

    @Test func missionBranchOwnerPrefersTheConfiguredPushRemote() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )
        let remotes = [
            GitRemote(name: "upstream", url: "git@github.com:acme/alas.git"),
            GitRemote(name: "fork", url: "git@github.com:nacho/alas.git"),
        ]

        let owner = AppState.missionBranchOwner(
            identity: identity,
            baseRef: "upstream/main",
            branchRemoteName: "upstream",
            pushRemoteName: "fork",
            remotes: remotes
        )

        #expect(owner == "nacho")
    }

    @Test func effectiveMissionPushRemoteUsesGitPrecedence() {
        #expect(AppState.effectiveMissionPushRemote(
            branchPushRemoteName: "fork",
            defaultPushRemoteName: "personal",
            branchRemoteName: "upstream"
        ) == "fork")
        #expect(AppState.effectiveMissionPushRemote(
            branchPushRemoteName: "",
            defaultPushRemoteName: "personal",
            branchRemoteName: "upstream"
        ) == "personal")
        #expect(AppState.effectiveMissionPushRemote(
            branchPushRemoteName: "",
            defaultPushRemoteName: "",
            branchRemoteName: "upstream"
        ) == "upstream")
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

    @Test func missionBranchOwnerUsesTheTargetProjectsProvider() {
        let sharedIssue = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )
        let remotes = [GitRemote(name: "origin", url: "git@gitlab.com:acme/sdk.git")]

        let owner = AppState.missionBranchOwner(
            identity: sharedIssue,
            baseRef: "origin/main",
            branchRemoteName: "origin",
            remotes: remotes,
            supportedKinds: [.github, .gitlab]
        )

        #expect(owner == "acme")
    }

    @Test func missionPaneBaseRefRequalifiesAStaleRemoteAlias() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )

        let baseRef = AppState.missionPaneBaseRef(
            identity: identity,
            baseRef: "origin/main",
            persistedRemoteName: "origin",
            remotes: [GitRemote(name: "upstream", url: "git@github.com:acme/alas.git")]
        )

        #expect(baseRef == "upstream/main")
    }

    @Test func secondaryMissionPaneBaseUsesTheLegRepositoryRemote() {
        let baseRef = AppState.missionPaneBaseRef(
            baseRef: "origin/main",
            persistedRemoteName: "origin",
            remotes: [GitRemote(name: "upstream", url: "git@gitlab.com:acme/sdk.git")],
            supportedKinds: [.github, .gitlab]
        )

        #expect(baseRef == "upstream/main")
    }

    @Test func missionPaneBaseRefPreservesAnUnqualifiedSlashBranch() {
        let identity = MissionIssueIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 42
        )

        let baseRef = AppState.missionPaneBaseRef(
            identity: identity,
            baseRef: "release/1.0",
            persistedRemoteName: "",
            remotes: [GitRemote(name: "release", url: "git@github.com:acme/alas.git")]
        )

        #expect(baseRef == "release/1.0")
    }

    @Test func missionPaneCallbackUsesThePersistedBaseRef() {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.legs[0].worktreeId = "worktree-1"

        let baseRef = AppState.missionCallbackBaseRef(
            worktreeID: "worktree-1",
            paneBaseRef: "upstream/main",
            aggregates: [aggregate]
        )

        #expect(baseRef == "origin/main")
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
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-mission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        #expect(try await Process.git(["init"], cwd: repository).exitCode == 0)
        #expect(try await Process.git([
            "remote", "add", "upstream", "git@github.com:acme/alas.git",
        ], cwd: repository).exitCode == 0)
        let project = ProjectConfig(
            id: Self.project.id,
            name: Self.project.name,
            path: repository.path,
            color: Self.project.color,
            addedAt: Self.project.addedAt
        )
        let worktree = Worktree(
            id: Self.worktree.id,
            projectId: Self.worktree.projectId,
            name: Self.worktree.name,
            branch: Self.worktree.branch,
            path: repository,
            status: Self.worktree.status,
            lastActivity: Self.worktree.lastActivity,
            lineageID: Self.worktree.lineageID
        )
        let persistence = try Self.makeMissionPersistence(worktree: worktree)
        var requestedWorktreeIDs: [String] = []
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence,
            missionStartupReviewSnapshot: { worktree, baseRef in
                requestedWorktreeIDs.append(worktree.id)
                #expect(baseRef == "upstream/main")
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
        lastActivity: Date(timeIntervalSince1970: 100),
        lineageID: "lineage-1"
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

    private static func makeMissionPersistence(worktree: Worktree = worktree) throws -> MissionPersistence {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.mission.setupCheckpoint = .running
        let leg = aggregate.legs[0]
        aggregate.legs[0] = MissionLeg(
            id: leg.id,
            missionID: leg.missionID,
            ordinal: leg.ordinal,
            projectId: leg.projectId,
            baseRef: leg.baseRef,
            baseRemoteName: leg.baseRemoteName,
            branch: leg.branch,
            destinationPath: worktree.path.path,
            worktreeId: worktree.id,
            worktreeLineageID: worktree.lineageID,
            agentId: leg.agentId,
            acpSessionId: "session-1",
            initialPromptId: leg.initialPromptId,
            pendingInitialPrompt: nil,
            reviewIdentity: leg.reviewIdentity
        )
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
private struct MissionGlobalNavigationFixture {
    let aggregate: MissionAggregate
    let worktree: Worktree
    let otherWorktree: Worktree
    let state: AppState

    init(includeWorktree: Bool) throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-global-navigation-\(UUID().uuidString).sqlite")
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        let store = try MissionStore(path: databaseURL.path)
        try store.insert(aggregate)

        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let worktree = Worktree(
            id: "worktree-1",
            projectId: project.id,
            name: "fix/parser-crash",
            branch: "fix/parser-crash",
            path: URL(fileURLWithPath: "/tmp/alas-mission"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0),
            lineageID: aggregate.legs[0].worktreeLineageID
        )
        let otherWorktree = Worktree(
            id: "worktree-2",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/alas"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let appState = AppState(
            store: NavigationStore(projectsFile: ProjectsFile(projects: [project])),
            missionPersistence: MissionPersistence(path: databaseURL.path),
            globalTabs: GlobalTabsManager(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mission-global-navigation-\(UUID().uuidString).json")
            )
        )
        if includeWorktree {
            appState.projectsManager.insertOptimisticWorktree(worktree)
        }
        appState.projectsManager.insertOptimisticWorktree(otherWorktree)

        self.aggregate = aggregate
        self.worktree = worktree
        self.otherWorktree = otherWorktree
        self.state = appState
    }

    private struct NavigationStore: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            type == ProjectsFile.self ? projectsFile as? T : nil
        }
    }
}

private extension MissionTabState {
    static let fixture = MissionTabState(
        missionID: MissionID(rawValue: "mission-1"),
        title: "Fix parser crash"
    )

    static let crossRepoFixture = MissionTabState(
        missionID: .fixture,
        title: "Fixture Mission"
    )
}

@MainActor
private struct MissionCrossSpaceNavigationFixture {
    let root: URL
    let tabsDirectory: URL
    let globalTabsFile: URL
    let aggregate: MissionAggregate
    let appWorktree: Worktree
    let sdkWorktree: Worktree
    private let projectsFile: ProjectsFile
    private let spacesFile: SpacesFile
    private let missionDatabaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-cross-space-\(UUID().uuidString)", isDirectory: true)
        tabsDirectory = root.appendingPathComponent("tabs", isDirectory: true)
        globalTabsFile = root.appendingPathComponent("global-tabs.json")
        missionDatabaseURL = root.appendingPathComponent("missions.sqlite")

        let appProject = ProjectConfig(
            id: "app-project",
            name: "Alas",
            path: "/tmp/alas",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let sdkProject = ProjectConfig(
            id: "sdk-project",
            name: "Alas SDK",
            path: "/tmp/alas-sdk",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 1)
        )
        projectsFile = ProjectsFile(projects: [appProject, sdkProject])
        spacesFile = SpacesFile(
            version: 1,
            activeSpaceId: "app-space",
            spaces: [
                SpaceConfig(
                    id: "app-space",
                    name: "App",
                    emoji: "1",
                    projectIds: [appProject.id],
                    lastSelectedWorktreeId: nil,
                    createdAt: Date(timeIntervalSince1970: 0)
                ),
                SpaceConfig(
                    id: "sdk-space",
                    name: "SDK",
                    emoji: "2",
                    projectIds: [sdkProject.id],
                    lastSelectedWorktreeId: nil,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
            ]
        )
        aggregate = MissionFixtures.twoLegMission()
        let timestamp = aggregate.mission.createdAt
        let appLeg = aggregate.legs[0]
        let sdkLeg = aggregate.legs[1]
        let missionID = aggregate.mission.id
        appWorktree = Worktree(
            id: "app-worktree",
            projectId: appProject.id,
            name: appLeg.branch,
            branch: appLeg.branch,
            path: URL(fileURLWithPath: appLeg.destinationPath),
            status: .clean,
            lastActivity: timestamp,
            lineageID: appLeg.worktreeLineageID
        )
        sdkWorktree = Worktree(
            id: "sdk-worktree",
            projectId: sdkProject.id,
            name: sdkLeg.branch,
            branch: sdkLeg.branch,
            path: URL(fileURLWithPath: sdkLeg.destinationPath),
            status: .clean,
            lastActivity: timestamp,
            lineageID: sdkLeg.worktreeLineageID
        )
        let missionStore = try MissionStore(path: missionDatabaseURL.path)
        var initial = aggregate
        initial.legs = [appLeg]
        try missionStore.insert(initial)
        try missionStore.addLeg(
            sdkLeg,
            event: MissionEvent(
                id: "cross-repo-sdk-leg-added",
                missionID: missionID,
                legID: sdkLeg.id,
                kind: .legAdded,
                message: "Mission leg added for \(sdkLeg.branch).",
                createdAt: timestamp
            )
        )
    }

    func makeState(globalTabs: GlobalTabsManager) -> AppState {
        let state = AppState(
            store: Store(projectsFile: projectsFile, spacesFile: spacesFile),
            missionPersistence: MissionPersistence(path: missionDatabaseURL.path),
            globalTabs: globalTabs
        )
        state.projectsManager.insertOptimisticWorktree(appWorktree)
        state.projectsManager.insertOptimisticWorktree(sdkWorktree)
        return state
    }

    private struct Store: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile
        let spacesFile: SpacesFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            if type == SpacesFile.self { return spacesFile as? T }
            return nil
        }
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
