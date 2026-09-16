import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct WorktreeStatusStoreTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        var projectsFile = ProjectsFile(projects: [])

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            if type == ProjectsFile.self {
                return projectsFile as? T
            }
            if type == AppConfig.self {
                return AppConfig.defaults as? T
            }
            return nil
        }
    }

    private struct AvailableWorkspaceObserver: WorkspaceCheckoutObserving {
        func observe(_: WorkspaceCheckoutMember, in _: WorkspaceCheckout) async -> WorkspaceCheckoutMemberObservation {
            .exactLineage("test-lineage")
        }
    }

    private actor ScanProbe {
        private var calls: [[String]] = []
        private var firstStarted: CheckedContinuation<Void, Never>?
        private var releaseFirst: CheckedContinuation<Void, Never>?

        func record(paths: [URL]) async -> [String: WorktreeDirtyState] {
            calls.append(paths.map(\.path))
            if calls.count == 1 {
                firstStarted?.resume()
                firstStarted = nil
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                }
            }
            return Dictionary(uniqueKeysWithValues: paths.map { ($0.path, .clean) })
        }

        func waitUntilFirstScanStarts() async {
            guard calls.isEmpty else { return }
            await withCheckedContinuation { continuation in
                firstStarted = continuation
            }
        }

        func releaseFirstScan() {
            releaseFirst?.resume()
            releaseFirst = nil
        }

        func recordedCalls() -> [[String]] {
            calls
        }
    }

    private actor ScanRecorder {
        private var calls: [[String]] = []

        func record(paths: [URL]) {
            calls.append(paths.map(\.path))
        }

        func recordedCalls() -> [[String]] {
            calls
        }
    }

    private func freshStore() -> WorktreeStatusStore {
        let store = WorktreeStatusStore.shared
        store.prune(keepingPaths: [])
        return store
    }

    private func worktree(path: String, branch: String, projectId: String = "p1") -> Worktree {
        let url = URL(fileURLWithPath: path)
        return Worktree(
            id: Worktree.makeId(path: url),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: url,
            status: .clean,
            lastActivity: Date()
        )
    }

    @Test func unseenPathIsUnknownNotClean() {
        // The distinction that keeps the first paint honest.
        #expect(freshStore().status(forPath: "/nope") == .unknown)
    }

    @Test func applyMergesRatherThanReplaces() {
        let store = freshStore()
        store.apply(["/a": .clean, "/b": .dirty(fileCount: 2, conflictCount: 0)])
        // A later partial scan covering only /a must not blank /b.
        store.apply(["/a": .dirty(fileCount: 1, conflictCount: 0)])
        #expect(store.status(forPath: "/a") == .dirty(fileCount: 1, conflictCount: 0))
        #expect(store.status(forPath: "/b") == .dirty(fileCount: 2, conflictCount: 0))
    }

    @Test func applyIgnoresAnEmptyScan() {
        let store = freshStore()
        store.apply(["/a": .clean])
        store.apply([:])
        #expect(store.status(forPath: "/a") == .clean)
    }

    @Test func pruneDropsPathsThatAreGone() {
        let store = freshStore()
        store.apply(["/a": .clean, "/b": .clean])
        store.prune(keepingPaths: ["/a"])
        #expect(store.status(forPath: "/a") == .clean)
        #expect(store.status(forPath: "/b") == .unknown)
    }

    @Test func pruneKeepingEverythingChangesNothing() {
        let store = freshStore()
        store.apply(["/a": .clean, "/b": .clean])
        store.prune(keepingPaths: ["/a", "/b"])
        #expect(store.statuses.count == 2)
    }

    @Test func coalescedScanUsesLatestRequestedPaths() async {
        let probe = ScanProbe()
        let scanner = WorktreeStatusScanner { paths in
            await probe.record(paths: paths)
        }

        let firstPath = URL(fileURLWithPath: "/old")
        let latestPath = URL(fileURLWithPath: "/new")
        let scanTask = Task {
            await scanner.scan(paths: [firstPath])
        }

        await probe.waitUntilFirstScanStarts()
        await scanner.scan(paths: [latestPath])
        await probe.releaseFirstScan()
        await scanTask.value

        #expect(await probe.recordedCalls() == [["/old"], ["/new"]])
    }

    @Test func coalescedScanMergesPendingPathSets() async {
        let probe = ScanProbe()
        let scanner = WorktreeStatusScanner { paths in
            await probe.record(paths: paths)
        }

        let firstPath = URL(fileURLWithPath: "/old")
        let broadPath = URL(fileURLWithPath: "/new-worktree")
        let activePath = URL(fileURLWithPath: "/active-worktree")
        let scanTask = Task {
            await scanner.scan(paths: [firstPath])
        }

        await probe.waitUntilFirstScanStarts()
        await scanner.scan(paths: [broadPath, activePath])
        await scanner.scan(paths: [activePath])
        await probe.releaseFirstScan()
        await scanTask.value

        #expect(await probe.recordedCalls() == [
            ["/old"],
            ["/new-worktree", "/active-worktree"],
        ])
    }

    @Test func routineLocalStatusPathsExcludeHiddenWorktrees() {
        let project = ProjectConfig(
            id: "p1",
            name: "Project",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            hiddenWorktreePaths: ["/repo/hidden"]
        )
        let state = AppState(store: MemoryStore(projectsFile: .init(projects: [project])))
        state.projectsManager.insertOptimisticWorktree(worktree(path: "/repo/visible", branch: "visible"))
        state.projectsManager.insertOptimisticWorktree(worktree(path: "/repo/hidden", branch: "hidden"))

        #expect(state.localWorktreeStatusPaths().map(\.path) == ["/repo/visible"])
        #expect(state.localWorktreeStatusPaths(projectId: "p1").map(\.path) == ["/repo/visible"])
    }

    @Test func workspaceCheckoutSelectionRefreshesFocusedMemberStatus() async throws {
        let recorder = ScanRecorder()
        let worktree = worktree(path: "/workspace/repo", branch: "topic")
        let project = ProjectConfig(
            id: "p1",
            name: "Project",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let member = WorkspaceCheckoutMember(
            workspaceMemberID: UUID(),
            projectID: project.id,
            fallbackProjectName: project.name,
            fallbackRepositoryRoot: project.path,
            worktreePath: worktree.path.path,
            availability: .available
        )
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "topic",
            rootPath: "/workspace",
            members: [member]
        )
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-status-selection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let workspacesManager = WorkspacesManager(
            bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore),
            observer: AvailableWorkspaceObserver()
        )
        let state = AppState(
            store: MemoryStore(projectsFile: .init(projects: [project])),
            restoreActiveTabsOnStartup: false,
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore,
            worktreeStatusScan: { paths in
                await recorder.record(paths: paths)
            }
        )
        state.config.workspacesEnabled = true
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        state.projectsManager.insertOptimisticWorktree(worktree)

        state.selectWorkspaceCheckout(id: checkout.id)
        try await Task.sleep(for: .milliseconds(50))

        #expect(state.selectedWorktreeId == worktree.id)
        #expect(await recorder.recordedCalls() == [[worktree.path.path]])
    }

    @Test func projectScanInvalidatesOlderTargetedRemoteScanForCoveredWorktree() {
        var generations = RemoteWorktreeStatusRescanGenerations()

        let targeted = generations.beginWorktreeScan(projectID: "p1", worktreeID: "w1")
        let project = generations.beginProjectScan(projectID: "p1", worktreeIDs: ["w1", "w2"])

        #expect(generations.isCurrent(project))
        #expect(generations.isCurrent(targeted) == false)
        #expect(generations.isCurrentWorktree(
            projectID: "p1",
            worktreeID: "w1",
            generation: project.worktreeGeneration(worktreeID: "w1") ?? -1
        ))
        #expect(generations.isCurrentWorktree(
            projectID: "p1",
            worktreeID: "w2",
            generation: project.worktreeGeneration(worktreeID: "w2") ?? -1
        ))
    }

    @Test func targetedRemoteScanInvalidatesOnlyItsPathFromOlderProjectScan() {
        var generations = RemoteWorktreeStatusRescanGenerations()

        let project = generations.beginProjectScan(projectID: "p1", worktreeIDs: ["w1", "w2"])
        let targeted = generations.beginWorktreeScan(projectID: "p1", worktreeID: "w1")

        #expect(generations.isCurrent(project))
        #expect(generations.isCurrent(targeted))
        #expect(generations.isCurrentWorktree(
            projectID: "p1",
            worktreeID: "w1",
            generation: project.worktreeGeneration(worktreeID: "w1") ?? -1
        ) == false)
        #expect(generations.isCurrentWorktree(
            projectID: "p1",
            worktreeID: "w2",
            generation: project.worktreeGeneration(worktreeID: "w2") ?? -1
        ))
    }
}
