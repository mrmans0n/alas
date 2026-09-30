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
