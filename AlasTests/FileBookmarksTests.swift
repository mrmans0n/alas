import Foundation
import Testing
@testable import Alas

struct FileBookmarksTests {
    // MARK: - Helpers

    private func dir(
        _ name: String,
        _ path: String,
        children: [FileTreeNode]? = nil,
        childrenState: DirectoryChildrenState = .loaded
    ) -> FileTreeNode {
        FileTreeNode(
            name: name,
            path: path,
            kind: .dir,
            children: children,
            badge: nil,
            childrenState: childrenState
        )
    }

    private func file(_ name: String, _ path: String) -> FileTreeNode {
        FileTreeNode(name: name, path: path, kind: .file, children: nil, badge: nil)
    }

    /// `Sources/Center/App.swift`, fully loaded at every level.
    private var loadedTree: [FileTreeNode] {
        [dir("Sources", "Sources", children: [
            dir("Center", "Sources/Center", children: [file("App.swift", "Sources/Center/App.swift")])
        ])]
    }

    // MARK: - Normalization

    @Test(arguments: ["Sources/Center", "/Sources/Center", "Sources/Center/", "  Sources/Center  "])
    func normalizesToRepoRelativePath(_ raw: String) {
        #expect(FileBookmarks.normalized(raw) == "Sources/Center")
    }

    @Test(arguments: ["", "   ", "/", "."])
    func rejectsPathsThatCannotBeBookmarked(_ raw: String) {
        #expect(FileBookmarks.normalized(raw) == nil)
    }

    // MARK: - Toggle

    @Test func togglingUnbookmarkedPathAppendsItLast() {
        #expect(FileBookmarks.toggled("docs", in: ["Sources"]) == ["Sources", "docs"])
    }

    @Test func togglingBookmarkedPathRemovesIt() {
        #expect(FileBookmarks.toggled("Sources", in: ["Sources", "docs"]) == ["docs"])
    }

    @Test func togglingNormalizesBeforeComparing() {
        #expect(FileBookmarks.toggled("/Sources/", in: ["Sources"]) == [])
    }

    @Test func togglingUnbookmarkablePathLeavesListUnchanged() {
        #expect(FileBookmarks.toggled("", in: ["Sources"]) == ["Sources"])
    }

    @Test func containsMatchesNormalizedPaths() {
        #expect(FileBookmarks.contains("/Sources/", in: ["Sources"]))
        #expect(!FileBookmarks.contains("docs", in: ["Sources"]))
    }

    // MARK: - Resolution

    @Test func resolvesNodeWhenEveryAncestorIsLoaded() {
        let resolution = FileBookmarks.resolve(path: "Sources/Center", in: loadedTree)
        #expect(resolution == .resolved(
            dir("Center", "Sources/Center", children: [file("App.swift", "Sources/Center/App.swift")])
        ))
    }

    @Test func resolvesBookmarkedFileLeaf() {
        let resolution = FileBookmarks.resolve(path: "Sources/Center/App.swift", in: loadedTree)
        #expect(resolution == .resolved(file("App.swift", "Sources/Center/App.swift")))
    }

    @Test func reportsLoadingWhileAnAncestorHasNotLoadedItsChildren() {
        let tree = [dir("Sources", "Sources", children: nil, childrenState: .notLoaded)]
        #expect(FileBookmarks.resolve(path: "Sources/Center", in: tree) == .loading)
    }

    @Test func reportsMissingWhenALoadedParentDoesNotContainThePath() {
        #expect(FileBookmarks.resolve(path: "Sources/Gone", in: loadedTree) == .missing)
    }

    @Test func reportsMissingWhenTopLevelEntryIsAbsent() {
        #expect(FileBookmarks.resolve(path: "vendor/thing", in: loadedTree) == .missing)
    }

    @Test func reportsFailedWhenAnAncestorFailedToLoad() {
        let tree = [dir("Sources", "Sources", children: nil, childrenState: .failed)]
        #expect(FileBookmarks.resolve(path: "Sources/Center", in: tree) == .failed("Sources"))
    }

    @Test func reportsMissingWhenAnAncestorIsAFile() {
        let tree = [file("Sources", "Sources")]
        #expect(FileBookmarks.resolve(path: "Sources/Center", in: tree) == .missing)
    }

    // MARK: - Pending loads

    @Test func pendingLoadPathNamesTheShallowestUnloadedAncestor() {
        let tree = [dir("Sources", "Sources", children: nil, childrenState: .notLoaded)]
        #expect(FileBookmarks.pendingLoadPath(for: "Sources/Center/App.swift", in: tree) == "Sources")
    }

    @Test func pendingLoadPathAdvancesAsLevelsArrive() {
        let tree = [dir("Sources", "Sources", children: [
            dir("Center", "Sources/Center", children: nil, childrenState: .notLoaded)
        ])]
        #expect(FileBookmarks.pendingLoadPath(for: "Sources/Center/App.swift", in: tree) == "Sources/Center")
    }

    @Test func pendingLoadPathIsNilOnceResolved() {
        #expect(FileBookmarks.pendingLoadPath(for: "Sources/Center", in: loadedTree) == nil)
    }

    @Test func pendingLoadPathIsNilWhileAnAncestorIsAlreadyLoading() {
        let tree = [dir("Sources", "Sources", children: nil, childrenState: .loading)]
        #expect(FileBookmarks.pendingLoadPath(for: "Sources/Center", in: tree) == nil)
    }

    @Test func pendingLoadPathIsNilWhileAnAncestorHasFailed() {
        let tree = [dir("Sources", "Sources", children: nil, childrenState: .failed)]
        #expect(FileBookmarks.pendingLoadPath(for: "Sources/Center", in: tree) == nil)
    }

    @Test func pendingLoadPathIsNilForAMissingPath() {
        #expect(FileBookmarks.pendingLoadPath(for: "Sources/Gone", in: loadedTree) == nil)
    }
}
