import Foundation
import Testing
@testable import Alas

struct RemotePathMigrationTests {
    private let old = "/srv/wt/a"
    private let new = RemotePath.virtual(host: "mini", realPath: "/srv/wt/a")

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-migration-\(UUID().uuidString)", isDirectory: true)
    }

    /// Writes `text` at `url`, creating parents. Directory stores get a child file.
    private func seed(_ store: RemotePathMigration.Store, root: URL, id: String, text: String) throws -> URL {
        var url = store.url(root: root, id: id)
        if store == .buffers { url.appendPathComponent("tab.json") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func relocated(_ url: URL, root: URL, store: RemotePathMigration.Store) -> URL {
        let oldBase = store.url(root: root, id: old).path
        let newBase = store.url(root: root, id: new).path
        return URL(fileURLWithPath: newBase + url.path.dropFirst(oldBase.count))
    }

    @Test(arguments: RemotePathMigration.Store.allCases)
    func movesLegacyStoreToVirtualId(store: RemotePathMigration.Store) throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var seeded = [try seed(store, root: root, id: old, text: "data")]
        if store == .acpSessions {
            let wal = URL(fileURLWithPath: seeded[0].path + "-wal")
            try Data("wal".utf8).write(to: wal)
            seeded.append(wal)
        }

        RemotePathMigration.migrate(idMap: [old: new], root: root)

        for url in seeded {
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(FileManager.default.fileExists(atPath: relocated(url, root: root, store: store).path))
        }
    }

    /// Sidecars hold committed rows: a partial run must resume without losing
    /// them and without pairing an old WAL with a database that is not its own.
    @Test(arguments: ["walMovedBeforeMain", "mainMovedWalLeftBehind", "bothMainsExist"])
    func acpSidecarsSurviveInterruptedMigration(state: String) throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = RemotePathMigration.Store.acpSessions.url(root: root, id: old)
        let to = RemotePathMigration.Store.acpSessions.url(root: root, id: new)
        func put(_ url: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        switch state {
        case "walMovedBeforeMain":
            try put(from, "db")
            try put(URL(fileURLWithPath: from.path + "-shm"), "shm")
            try put(URL(fileURLWithPath: to.path + "-wal"), "moved-wal")
        case "mainMovedWalLeftBehind":
            try put(to, "db")
            try put(URL(fileURLWithPath: from.path + "-wal"), "wal")
        default:
            try put(from, "old-db")
            try put(to, "new-db")
            try put(URL(fileURLWithPath: from.path + "-wal"), "old-wal")
        }

        RemotePathMigration.migrate(idMap: [old: new], root: root)

        let toWal = URL(fileURLWithPath: to.path + "-wal")
        switch state {
        case "walMovedBeforeMain":
            #expect(read(to) == "db" && read(from) == nil)
            #expect(read(toWal) == "moved-wal")
            #expect(read(URL(fileURLWithPath: to.path + "-shm")) == "shm")
        case "mainMovedWalLeftBehind":
            #expect(read(toWal) == "wal")
        default:
            #expect(read(to) == "new-db" && read(from) == "old-db")
            #expect(read(toWal) == nil)
        }
    }

    @Test func existingDestinationIsKeptAndRerunIsNoOp() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = try seed(.tabs, root: root, id: old, text: "old")
        let newFile = try seed(.tabs, root: root, id: new, text: "new")

        RemotePathMigration.migrate(idMap: [old: new], root: root)
        RemotePathMigration.migrate(idMap: [old: new], root: root)

        #expect(try String(contentsOf: oldFile, encoding: .utf8) == "old")
        #expect(try String(contentsOf: newFile, encoding: .utf8) == "new")
    }

    /// Another worktree's buffers can live in a subdirectory of the legacy id
    /// (e.g. a local worktree nested under the remote path). They stay put.
    @Test func directoryStoreLeavesNestedDirectoriesInPlace() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = try seed(.buffers, root: root, id: old + "/nested", text: "local")

        RemotePathMigration.migrate(idMap: [old: new], root: root)

        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    /// Ruling: tabs must be under the virtual id before `loadAll` and the zmx
    /// orphan sweep run, or live remote sessions look orphaned and get killed.
    /// `@MainActor`: `TabsManager` is main-actor isolated.
    @MainActor
    @Test func tabsPersistedUnderLegacyIdLoadUnderVirtualIdAfterMigration() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tabsDir = root.appendingPathComponent("tabs", isDirectory: true)
        let tab = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDir)
            .appendTerminal(worktreeId: old, title: "shell", sessionId: "s")

        RemotePathMigration.migrate(idMap: [old: new], root: root)

        let loaded = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDir)
        loaded.loadAll(worktreeIds: [new])
        #expect(loaded.tabs(forWorktree: new).map(\.id) == [tab.id])
    }

    /// Migrated tab files keep real external paths; a remote worktree must
    /// load them virtual, or reads and saves hit the local disk.
    @MainActor
    @Test(arguments: [true, false])
    func loadVirtualizesExternalEditorPathsOnlyForRemoteWorktrees(remote: Bool) throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tabsDir = root.appendingPathComponent("tabs", isDirectory: true)
        let id = remote ? new : old
        let external = "/opt/sdk/x.h"
        let editor = EditorTabState(id: "e", title: "x.h", relativePath: "", externalAbsolutePath: external)
        try PersistenceStore().write(
            TabsFile(tabs: [.editor(editor)], activeTabId: nil),
            to: tabsDir.appendingPathComponent("\(id).json")
        )

        let loaded = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDir)
        loaded.loadAll(worktreeIds: [id])

        guard case .editor(let state) = loaded.tabs(forWorktree: id).first else {
            Issue.record("editor tab not restored")
            return
        }
        #expect(state.externalAbsolutePath == (remote ? RemotePath.virtual(host: "mini", realPath: external) : external))
    }

    /// A restored commit-range review must run git on the virtual worktree,
    /// not on the bare real path (which may be a local twin). Its ids are
    /// composites of worktree id and path, so they must match the factory's.
    @Test func reviewSessionTargetsBecomeVirtualAndRerunIsNoOp() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("review-sessions.json")
        let target = ReviewSessionTarget.commitRange(
            worktreeID: old, repositoryPath: URL(fileURLWithPath: old), base: "main", head: "topic"
        )
        try ReviewSessionStore(url: url).save(ReviewSessionRecord(
            id: target.id, target: target, createdAt: .distantPast, updatedAt: .distantPast
        ))

        RemotePathMigration.migrate(idMap: [old: new], root: root)
        RemotePathMigration.migrate(idMap: [old: new], root: root)

        let expected = ReviewSessionTarget.commitRange(
            worktreeID: new, repositoryPath: URL(fileURLWithPath: new), base: "main", head: "topic"
        )
        let migrated = try ReviewSessionStore(url: url).load(id: expected.id)
        #expect(migrated?.id == expected.id)
        #expect(migrated?.target == expected)
    }

    @Test func runHistoryRowsFollowTheVirtualId() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("run-history.sqlite").path
        let conflict = RunPortConflict.ownedByRun(worktreeID: old, branch: "b", scriptName: "s")
        try await RunHistoryStore(path: path).append(RunHistoryEntry(
            id: "run", scriptKey: "k", scriptName: "s", worktreeID: old, branch: "b",
            target: .init(host: "mini", workingDirectory: old), endpoint: nil, outcome: .succeeded,
            startedAt: .distantPast, finishedAt: .distantPast, portConflict: conflict, output: .available(text: "", truncated: false)
        ))

        RemotePathMigration.migrate(idMap: [old: new], root: root)
        RemotePathMigration.migrate(idMap: [old: new], root: root)

        let entry = try await RunHistoryStore(path: path).entry(id: "run")
        #expect(entry?.worktreeID == new)
        #expect(entry?.portConflict == .ownedByRun(worktreeID: new, branch: "b", scriptName: "s"))
    }

    /// A failed step keeps the projects' pending ids so the next launch
    /// retries; a run where every step succeeds clears them.
    @Test func pendingIdsStayUntilEveryStepSucceeds() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tabs = try seed(.tabs, root: root, id: old, text: "tabs")
        // A file where the destination's parent directory must go.
        let blocker = RemotePathMigration.Store.tabs.url(root: root, id: new).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: blocker)
        var project = ProjectConfig(
            id: "p", name: "P", path: RemotePath.virtual(host: "mini", realPath: "/srv/repo"), color: "#fff",
            addedAt: .distantPast, host: "mini"
        )
        project.legacyWorktreeIDs = [old: new]
        var projects = [project]

        _ = RemotePathMigration.migratePending(projects: &projects, root: root)

        #expect(projects[0].legacyWorktreeIDs == [old: new])
        #expect(FileManager.default.fileExists(atPath: tabs.path))

        try FileManager.default.removeItem(at: blocker)
        _ = RemotePathMigration.migratePending(projects: &projects, root: root)

        #expect(projects[0].legacyWorktreeIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: relocated(tabs, root: root, store: .tabs).path))
    }

    /// An interrupted `.new` delegation is recovered by its destination path,
    /// which must match the virtual path of the cached worktree.
    @Test(arguments: [
        (
            ACPDelegatedWorktreeRequest.existing(worktreeId: "/srv/wt/a"),
            ACPDelegatedWorktreeRequest.existing(worktreeId: "/.alas-remote/mini/srv/wt/a")
        ),
        (
            ACPDelegatedWorktreeRequest.new(branch: "b", base: nil, destinationPath: "/srv/wt/a", optimisticId: "pending-child"),
            ACPDelegatedWorktreeRequest.new(
                branch: "b", base: nil, destinationPath: "/.alas-remote/mini/srv/wt/a", optimisticId: "pending-child"
            )
        ),
    ])
    func delegationRowsFollowTheVirtualId(request: ACPDelegatedWorktreeRequest, expected: ACPDelegatedWorktreeRequest) throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("acp-orchestration.sqlite").path
        try ACPOrchestrationStore(path: path).insert(ACPDelegationRecord(
            childSessionId: "child", parentSessionId: "parent", projectId: "project", parentWorktreeId: old,
            childWorktreeId: nil, agentId: "codex", worktreeRequest: request, pendingInitialPrompt: nil,
            phase: .creatingWorktree, failureMessage: nil, createdAt: 1, updatedAt: 1
        ))

        RemotePathMigration.migrate(idMap: [old: new], root: root)
        RemotePathMigration.migrate(idMap: [old: new], root: root)

        let record = try #require(try ACPOrchestrationStore(path: path).delegation(childSessionId: "child"))
        #expect(record.parentWorktreeId == new)
        #expect(record.worktreeRequest == expected)
    }

    /// Pending review files are named by a hash of the worktree path.
    @Test(arguments: ["", "-pr7"])
    func pendingReviewMovesToVirtualPathHash(suffix: String) throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("pending-reviews", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let from = dir.appendingPathComponent("\(PendingReview.pathHash(old))\(suffix).json")
        try Data("[]".utf8).write(to: from)

        RemotePathMigration.migrate(idMap: [old: new], root: root)

        #expect(!FileManager.default.fileExists(atPath: from.path))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(PendingReview.pathHash(new))\(suffix).json").path
        ))
    }

    /// Owners without a lineage id are keyed by path; their events and
    /// source keys must follow, or the inbox can't resolve the worktree.
    @Test func attentionPathIdentitiesBecomeVirtualAndRerunIsNoOp() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("attention-events.json")
        func owner(_ path: String) -> AttentionWorktreeIdentity {
            .init(projectID: "p", location: .ssh("mini"), lineageID: nil, legacyPath: path)
        }
        func event(_ path: String) -> AttentionEvent {
            AttentionEvent(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                sourceKey: .init(rawValue: "git:\(owner(path).storageKey):operation"), fingerprint: "f",
                owner: owner(path), kind: .gitOperation, title: "t", body: nil, jumpTarget: .gitOperation,
                display: .init(projectName: "P", branch: "b", path: path, host: "mini"),
                occurredAt: .distantPast, requiresAction: false
            )
        }
        try PersistenceStore().write(AttentionDocument(events: [event(old)]), to: url)

        RemotePathMigration.migrate(idMap: [old: new], root: root)
        RemotePathMigration.migrate(idMap: [old: new], root: root)

        let migrated = try PersistenceStore().readIfExists(AttentionDocument.self, from: url)
        #expect(migrated?.events == [event(new)])
    }

    /// Restored review, commit and similar tabs carry the worktree id in
    /// their state and tab id; a remote worktree must load them virtual.
    @MainActor
    @Test func loadRemapsEmbeddedWorktreeIdsOfRemoteTabs() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tabsDir = root.appendingPathComponent("tabs", isDirectory: true)
        let legacy = Tab.commit(CommitTabState(worktreeId: old, sha: "abc", title: "c"))
        try PersistenceStore().write(
            TabsFile(tabs: [legacy, .reviewChanges(ReviewChangesTabState(worktreeId: old))], activeTabId: legacy.id),
            to: tabsDir.appendingPathComponent("\(new).json")
        )

        let loaded = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDir)
        loaded.loadAll(worktreeIds: [new])

        let expected = Tab.commit(CommitTabState(worktreeId: new, sha: "abc", title: "c"))
        #expect(loaded.tabs(forWorktree: new) == [expected, .reviewChanges(ReviewChangesTabState(worktreeId: new))])
        #expect(loaded.activeTabId(forWorktree: new) == expected.id)
    }

    /// A local project at the same real path keeps its state.
    @Test func legacyIDMapSkipsIdsStillUsedByLocalProjects() {
        var remote = ProjectConfig(id: "r", name: "R", path: new, color: "#fff", addedAt: .distantPast, host: "mini")
        remote.legacyWorktreeIDs = [old: new, "/srv/wt/b": RemotePath.virtual(host: "mini", realPath: "/srv/wt/b")]
        let local = ProjectConfig(id: "l", name: "L", path: old, color: "#fff", addedAt: .distantPast)

        #expect(RemotePathMigration.legacyIDMap(projects: [remote, local]) == [
            "/srv/wt/b": RemotePath.virtual(host: "mini", realPath: "/srv/wt/b"),
        ])
    }

    /// Saved right away: once projects.json is re-saved the legacy map is
    /// gone, so an unsaved rewrite would leave stale ids forever.
    @Test func rewritesAndSavesRecentsAndSpacesOnlyWhenChanged() {
        var config = AppConfig.defaults
        config.recentWorktreeIdsByProject = ["p": [old, "/local"]]
        config.recentWorktreeRefs = [.init(projectId: "p", worktreeId: old)]
        var spaces: SpacesFile? = SpacesFile(activeSpaceId: "s", spaces: [
            SpaceConfig(id: "s", name: "S", emoji: "x", projectIds: ["p"], lastSelectedWorktreeId: old, createdAt: .distantPast),
        ])
        let store = RecordingStore()

        RemotePathMigration.rewrite(&config, &spaces, idMap: [old: new], saving: store)

        #expect(config.recentWorktreeIdsByProject == ["p": [new, "/local"]])
        #expect(config.recentWorktreeRefs.map(\.worktreeId) == [new])
        #expect(spaces?.spaces.map(\.lastSelectedWorktreeId) == [new])
        #expect(store.writes.map(\.url) == [Paths.appConfigFile, Paths.spacesFile])
        #expect(store.writes.first?.value as? AppConfig == config)
        #expect(store.writes.last?.value as? SpacesFile == spaces)

        RemotePathMigration.rewrite(&config, &spaces, idMap: [old: new], saving: store)
        #expect(store.writes.count == 2)
    }
}

private final class RecordingStore: PersistenceStoreProtocol {
    private(set) var writes: [(url: URL, value: Any)] = []
    func write(_ value: some Encodable, to url: URL) throws { writes.append((url, value)) }
    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
}
