import Foundation
import Testing
@testable import Alas

@MainActor
struct RightPaneStateFileTreeTests {
    @Test func mergingChildrenMarksDirectoryLoadedAndPreservesExistingBadges() {
        let tree = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "App.swift",
                        path: "Sources/App.swift",
                        kind: .file,
                        children: nil,
                        badge: "M",
                        visibility: .tracked,
                        childrenState: .loaded
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]
        let children = [
            FileTreeNode(
                name: "cache.log",
                path: "Sources/cache.log",
                kind: .file,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .loaded
            )
        ]

        let result = RightPaneState.mergingChildren(in: tree, for: "Sources", with: children, state: .loaded)
        let updated = result.nodes
        let root = updated.first!
        #expect(result.didMerge)
        #expect(root.childrenState == .loaded)
        #expect(root.children?.contains { $0.path == "Sources/App.swift" && $0.badge == "M" } == true)
        #expect(root.children?.contains { $0.path == "Sources/cache.log" && $0.visibility == .ignored } == true)
    }

    @Test func mergingChildrenRefreshesExistingChildMetadataAndPreservesDescendants() {
        let tree = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "Generated",
                        path: "Sources/Generated",
                        kind: .dir,
                        children: [
                            FileTreeNode(
                                name: "keep.txt",
                                path: "Sources/Generated/keep.txt",
                                kind: .file,
                                children: nil,
                                badge: "A",
                                visibility: .tracked,
                                childrenState: .loaded
                            )
                        ],
                        badge: nil,
                        visibility: .tracked,
                        childrenState: .loaded
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]
        let children = [
            FileTreeNode(
                name: "Generated",
                path: "Sources/Generated",
                kind: .dir,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .notLoaded
            )
        ]

        let result = RightPaneState.mergingChildren(in: tree, for: "Sources", with: children, state: .loaded)
        let generated = result.nodes.first?.children?.first
        let keep = generated?.children?.first

        #expect(result.didMerge)
        #expect(generated?.name == "Generated")
        #expect(generated?.path == "Sources/Generated")
        #expect(generated?.kind == .dir)
        #expect(generated?.visibility == .ignored)
        #expect(generated?.childrenState == .loaded)
        #expect(keep?.path == "Sources/Generated/keep.txt")
        #expect(keep?.badge == "A")
    }

    @Test func mergingChildrenPreservesSpecificExistingVisibilityWhenReturnedVisibilityIsDefaultTracked() {
        let tree = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "New.swift",
                        path: "Sources/New.swift",
                        kind: .file,
                        children: nil,
                        badge: "A",
                        visibility: .untracked,
                        childrenState: .loaded
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]
        let children = [
            FileTreeNode(
                name: "New.swift",
                path: "Sources/New.swift",
                kind: .file,
                children: nil,
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]

        let result = RightPaneState.mergingChildren(in: tree, for: "Sources", with: children, state: .loaded)
        let file = result.nodes.first?.children?.first

        #expect(result.didMerge)
        #expect(file?.badge == "A")
        #expect(file?.visibility == .untracked)
    }

    @Test func mergingChildrenReportsMissingTargetWithoutMutatingTree() {
        let tree = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: nil,
                badge: nil,
                visibility: .tracked,
                childrenState: .notLoaded
            )
        ]
        let children = [
            FileTreeNode(
                name: "cache.log",
                path: "Missing/cache.log",
                kind: .file,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .loaded
            )
        ]

        let result = RightPaneState.mergingChildren(in: tree, for: "Missing", with: children, state: .loaded)

        #expect(result.didMerge == false)
        #expect(result.nodes == tree)
    }

    @Test func mergingChildrenForLoadingDirectoryPreservesExistingChildren() {
        let tree = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "App.swift",
                        path: "Sources/App.swift",
                        kind: .file,
                        children: nil,
                        badge: "M",
                        visibility: .tracked,
                        childrenState: .loaded
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]

        let result = RightPaneState.mergingChildren(in: tree, for: "Sources", with: [], state: .loading)
        let sources = result.nodes.first

        #expect(result.didMerge)
        #expect(sources?.childrenState == .loading)
        #expect(sources?.children?.map(\.path) == ["Sources/App.swift"])
    }

    @Test func invalidatingFileTreeChildLoadsStartsNewGenerationAndClearsTracking() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-filetree-generation-\(UUID().uuidString)")
        let state = RightPaneState(
            worktree: Worktree(
                id: Worktree.makeId(path: path),
                projectId: "test-project",
                name: "main",
                branch: "main",
                path: path,
                status: .clean,
                lastActivity: Date()
            ),
            baseBranch: "main"
        )
        let generation = state.fileTreeGeneration

        state.invalidateFileTreeChildLoadsForRefresh()

        #expect(state.fileTreeGeneration == generation + 1)
        #expect(state.loadedFileTreeChildPaths == [""])
        #expect(state.loadingFileTreeChildPaths.isEmpty)
        #expect(state.failedFileTreeChildPaths.isEmpty)
    }

    @Test func invalidatingFileTreeChildLoadsResetsLoadingDirectoriesInRetainedTree() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-filetree-loading-reset-\(UUID().uuidString)")
        let state = RightPaneState(
            worktree: Worktree(
                id: Worktree.makeId(path: path),
                projectId: "test-project",
                name: "main",
                branch: "main",
                path: path,
                status: .clean,
                lastActivity: Date()
            ),
            baseBranch: "main"
        )
        state.fileTree = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "Generated",
                        path: "Sources/Generated",
                        kind: .dir,
                        children: [],
                        badge: nil,
                        visibility: .ignored,
                        childrenState: .loading
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]

        state.invalidateFileTreeChildLoadsForRefresh()

        let sources = state.fileTree.first
        let generated = sources?.children?.first
        #expect(sources?.childrenState == .loaded)
        #expect(generated?.childrenState == .notLoaded)
        #expect(generated?.children == nil)
    }

    @Test func resetLoadingFileTreeChildrenRecursivelyMarksLoadingDirectoriesNotLoaded() {
        let tree = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "Generated",
                        path: "Sources/Generated",
                        kind: .dir,
                        children: [
                            FileTreeNode(
                                name: "cache.log",
                                path: "Sources/Generated/cache.log",
                                kind: .file,
                                children: nil,
                                badge: nil,
                                visibility: .ignored,
                                childrenState: .loaded
                            )
                        ],
                        badge: nil,
                        visibility: .ignored,
                        childrenState: .loading
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]

        let reset = RightPaneState.resetLoadingFileTreeChildren(in: tree)
        let sources = reset.first
        let generated = sources?.children?.first

        #expect(sources?.childrenState == .loaded)
        #expect(generated?.childrenState == .notLoaded)
        #expect(generated?.children == nil)
    }

    @Test func preservingLazyChildrenGraftsPriorSubtreeOntoNotLoadedDirectory() {
        // Fresh tree rebuilds the lazy directory as `.notLoaded` with no
        // children, as `GitService.fileTree` does for ignored/excluded roots.
        let fresh = [
            FileTreeNode(
                name: "build",
                path: "build",
                kind: .dir,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .notLoaded
            )
        ]
        let previous = [
            FileTreeNode(
                name: "build",
                path: "build",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "out.o",
                        path: "build/out.o",
                        kind: .file,
                        children: nil,
                        badge: nil,
                        visibility: .ignored,
                        childrenState: .loaded
                    )
                ],
                badge: nil,
                visibility: .ignored,
                childrenState: .loaded
            )
        ]

        let merged = RightPaneState.preservingLazyChildren(fresh: fresh, previous: previous)
        let build = merged.first

        #expect(build?.childrenState == .loaded)
        #expect(build?.children?.map(\.path) == ["build/out.o"])
    }

    @Test func preservingLazyChildrenGraftsNestedLazySubtreeInsideLoadedDirectory() {
        let fresh = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "Generated",
                        path: "Sources/Generated",
                        kind: .dir,
                        children: nil,
                        badge: nil,
                        visibility: .ignored,
                        childrenState: .notLoaded
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]
        let previous = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "Generated",
                        path: "Sources/Generated",
                        kind: .dir,
                        children: [
                            FileTreeNode(
                                name: "cache.log",
                                path: "Sources/Generated/cache.log",
                                kind: .file,
                                children: nil,
                                badge: nil,
                                visibility: .ignored,
                                childrenState: .loaded
                            )
                        ],
                        badge: nil,
                        visibility: .ignored,
                        childrenState: .loaded
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]

        let merged = RightPaneState.preservingLazyChildren(fresh: fresh, previous: previous)
        let generated = merged.first?.children?.first

        #expect(generated?.childrenState == .loaded)
        #expect(generated?.children?.map(\.path) == ["Sources/Generated/cache.log"])
    }

    @Test func preservingLazyChildrenLeavesUnmatchedAndUnloadedDirectoriesUntouched() {
        let fresh = [
            FileTreeNode(
                name: "build",
                path: "build",
                kind: .dir,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .notLoaded
            )
        ]
        // Previous never loaded this directory either, so there is nothing to
        // graft and the fresh node must stay `.notLoaded`.
        let previous = [
            FileTreeNode(
                name: "build",
                path: "build",
                kind: .dir,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .notLoaded
            )
        ]

        let merged = RightPaneState.preservingLazyChildren(fresh: fresh, previous: previous)

        #expect(merged.first?.childrenState == .notLoaded)
        #expect(merged.first?.children == nil)
    }

    @Test func replacingChildrenPrunesDeletedEntriesAndPreservesLoadedSubtrees() {
        // "build" was expanded: it had a stale file and a nested loaded dir.
        let tree = [
            FileTreeNode(
                name: "build",
                path: "build",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "old.o",
                        path: "build/old.o",
                        kind: .file,
                        children: nil,
                        badge: nil,
                        visibility: .ignored,
                        childrenState: .loaded
                    ),
                    FileTreeNode(
                        name: "gen",
                        path: "build/gen",
                        kind: .dir,
                        children: [
                            FileTreeNode(
                                name: "keep.o",
                                path: "build/gen/keep.o",
                                kind: .file,
                                children: nil,
                                badge: nil,
                                visibility: .ignored,
                                childrenState: .loaded
                            )
                        ],
                        badge: nil,
                        visibility: .ignored,
                        childrenState: .loaded
                    )
                ],
                badge: nil,
                visibility: .ignored,
                childrenState: .loaded
            )
        ]
        // Fresh filesystem listing: old.o is gone, gen still exists (relisted as
        // a lazy dir), and new.o appeared.
        let incoming = [
            FileTreeNode(
                name: "gen",
                path: "build/gen",
                kind: .dir,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .notLoaded
            ),
            FileTreeNode(
                name: "new.o",
                path: "build/new.o",
                kind: .file,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .loaded
            )
        ]

        let result = RightPaneState.replacingChildren(in: tree, for: "build", with: incoming, state: .loaded)
        let build = result.nodes.first
        let gen = build?.children?.first { $0.path == "build/gen" }

        #expect(result.didMerge)
        #expect(build?.children?.contains { $0.path == "build/old.o" } == false)
        #expect(build?.children?.contains { $0.path == "build/new.o" } == true)
        // Nested expanded subtree survives the reconcile.
        #expect(gen?.childrenState == .loaded)
        #expect(gen?.children?.map(\.path) == ["build/gen/keep.o"])
    }

    @Test func replacingChildrenReportsMissingTargetWithoutMutating() {
        let tree = [
            FileTreeNode(
                name: "build",
                path: "build",
                kind: .dir,
                children: nil,
                badge: nil,
                visibility: .ignored,
                childrenState: .notLoaded
            )
        ]

        let result = RightPaneState.replacingChildren(in: tree, for: "missing", with: [], state: .loaded)

        #expect(result.didMerge == false)
        #expect(result.nodes == tree)
    }

    @Test func fileTreeNodeFindsNestedNodeByPath() {
        let tree = [
            FileTreeNode(
                name: "Sources",
                path: "Sources",
                kind: .dir,
                children: [
                    FileTreeNode(
                        name: "Generated",
                        path: "Sources/Generated",
                        kind: .dir,
                        children: [
                            FileTreeNode(
                                name: "cache.log",
                                path: "Sources/Generated/cache.log",
                                kind: .file,
                                children: nil,
                                badge: nil,
                                visibility: .ignored,
                                childrenState: .loaded
                            )
                        ],
                        badge: nil,
                        visibility: .ignored,
                        childrenState: .loaded
                    )
                ],
                badge: nil,
                visibility: .tracked,
                childrenState: .loaded
            )
        ]

        #expect(RightPaneState.fileTreeNode(at: "Sources/Generated", in: tree)?.childrenState == .loaded)
        #expect(RightPaneState.fileTreeNode(at: "Sources/Generated/cache.log", in: tree)?.kind == .file)
        #expect(RightPaneState.fileTreeNode(at: "Missing", in: tree) == nil)
    }

    @Test func shouldAutoLoadFileTreeChildrenReconcilesOpenLoadedDirectoriesOnce() {
        #expect(RightPaneState.shouldAutoLoadFileTreeChildren(
            path: "Sources",
            childrenState: .loaded,
            loadedPaths: [""],
            loadingPaths: [],
            failedPaths: []
        ))
        #expect(RightPaneState.shouldAutoLoadFileTreeChildren(
            path: "Sources",
            childrenState: .notLoaded,
            loadedPaths: [""],
            loadingPaths: [],
            failedPaths: []
        ))
        #expect(!RightPaneState.shouldAutoLoadFileTreeChildren(
            path: "Sources",
            childrenState: .loaded,
            loadedPaths: ["", "Sources"],
            loadingPaths: [],
            failedPaths: []
        ))
        #expect(!RightPaneState.shouldAutoLoadFileTreeChildren(
            path: "Sources",
            childrenState: .loaded,
            loadedPaths: [""],
            loadingPaths: ["Sources"],
            failedPaths: []
        ))
        #expect(!RightPaneState.shouldAutoLoadFileTreeChildren(
            path: "Sources",
            childrenState: .loaded,
            loadedPaths: [""],
            loadingPaths: [],
            failedPaths: ["Sources"]
        ))
        #expect(!RightPaneState.shouldAutoLoadFileTreeChildren(
            path: "Sources",
            childrenState: .failed,
            loadedPaths: [""],
            loadingPaths: [],
            failedPaths: []
        ))
    }
}

@MainActor
struct RightPaneStateRevealTests {
    @Test func revealSetsActiveTabToFiles() {
        let state = makeTestState()
        state.reveal(path: "Sources/App.swift")
        #expect(state.activeTab == .files)
    }

    @Test func revealExpandsAncestorDirsAndSetsRevealPath() {
        let state = makeTestState()
        state.reveal(path: "Sources/Center/App.swift")
        #expect(state.openPaths.contains("Sources"))
        #expect(state.openPaths.contains("Sources/Center"))
        #expect(state.revealPath == "Sources/Center/App.swift")
    }

    @Test func revealBumpsRevealTick() {
        let state = makeTestState()
        let before = state.revealTick
        state.reveal(path: "Sources/App.swift")
        #expect(state.revealTick == before + 1)
    }

    @Test func clearRevealRemovesRevealPathWithoutChangingNavigationState() {
        let state = makeTestState()
        state.reveal(path: "Sources/Center/App.swift")
        let tick = state.revealTick

        state.clearReveal()

        #expect(state.revealPath == nil)
        #expect(state.revealTick == tick)
        #expect(state.activeTab == .files)
        #expect(state.openPaths.contains("Sources"))
        #expect(state.openPaths.contains("Sources/Center"))
    }

    @Test func revealForDirectoryDoesNotIncludeSelfInAncestors() {
        let state = makeTestState()
        state.reveal(path: "Sources/Center")
        #expect(state.openPaths.contains("Sources"))
        #expect(state.openPaths.contains("Sources/Center") == false)
        #expect(state.revealPath == "Sources/Center")
    }

    @Test func revealForTopLevelDirHasNoAncestors() {
        let state = makeTestState()
        state.reveal(path: "Sources")
        #expect(state.openPaths.isEmpty)
        #expect(state.revealPath == "Sources")
    }

    private func makeTestState() -> RightPaneState {
        RightPaneState(
            worktree: Worktree(
                id: "test",
                projectId: "proj",
                name: "main",
                branch: "main",
                path: URL(fileURLWithPath: "/tmp/test"),
                status: .clean,
                lastActivity: Date()
            ),
            baseBranch: "main"
        )
    }
}
