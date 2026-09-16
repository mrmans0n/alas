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

    @Test(arguments: ["Sources/Center", "/Sources/Center", "Sources/Center/"])
    func normalizesToRepoRelativePath(_ raw: String) {
        #expect(FileBookmarks.normalized(raw) == "Sources/Center")
    }

    @Test func preservesWhitespaceInPathComponents() {
        #expect(FileBookmarks.normalized(" folder / document ") == " folder / document ")
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

    @Test func nodeBookmarksIncludeKindInTheirIdentity() throws {
        let dirNode = dir("Entry", "Entry")
        let fileNode = file("Entry", "Entry")
        let bookmarks = FileBookmarks.toggled(fileNode, in: [])

        #expect(FileBookmarks.contains(fileNode, in: bookmarks))
        #expect(!FileBookmarks.contains(dirNode, in: bookmarks))
        #expect(FileBookmarks.path(for: try #require(bookmarks.first)) == "Entry")
        #expect(FileBookmarks.kind(for: try #require(bookmarks.first)) == .file)
    }

    @Test func nodeToggleCanRemoveLegacyPathBookmarks() {
        let dirNode = dir("Entry", "Entry")
        #expect(FileBookmarks.contains(dirNode, in: ["Entry"]))
        #expect(FileBookmarks.bookmarkValue(for: dirNode, in: ["Entry"]) == "Entry")
        #expect(FileBookmarks.toggled(dirNode, in: ["Entry"]) == [])
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

    @Test func resolvesKindSpecificBookmarkWhenFileAndDirectoryShareAPath() throws {
        let dirNode = dir("Entry", "Entry")
        let fileNode = file("Entry", "Entry")
        let tree = [dirNode, fileNode]
        let bookmark = try #require(FileBookmarks.toggled(fileNode, in: []).first)

        let resolution = FileBookmarks.resolve(bookmark: bookmark, in: tree)

        guard case .resolved(let node) = resolution else {
            Issue.record("Expected file bookmark to resolve")
            return
        }
        #expect(node.kind == .file)
        #expect(node.path == "Entry")
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
