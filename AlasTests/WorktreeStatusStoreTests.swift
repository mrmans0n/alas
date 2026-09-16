import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct WorktreeStatusStoreTests {
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

    private func freshStore() -> WorktreeStatusStore {
        let store = WorktreeStatusStore.shared
        store.prune(keepingPaths: [])
        return store
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
