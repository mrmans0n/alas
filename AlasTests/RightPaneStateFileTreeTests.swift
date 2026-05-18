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
        #expect(generated?.childrenState == .notLoaded)
        #expect(keep?.path == "Sources/Generated/keep.txt")
        #expect(keep?.badge == "A")
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
}
