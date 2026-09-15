import Foundation
import Testing
@testable import Alas

@MainActor
struct ProjectsManagerFileBookmarksTests {
    private func manager(bookmarks: [String] = []) -> ProjectsManager {
        ProjectsManager(persistedProjects: [
            ProjectConfig(
                id: "abc", name: "alpha", path: "/tmp/alpha",
                color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0),
                fileBookmarks: bookmarks
            )
        ])
    }

    @Test func togglingAddsThenRemovesTheBookmark() {
        let mgr = manager()
        mgr.toggleFileBookmark(projectId: "abc", path: "Sources/Center")
        #expect(mgr.fileBookmarks(projectId: "abc") == ["Sources/Center"])
        mgr.toggleFileBookmark(projectId: "abc", path: "Sources/Center")
        #expect(mgr.fileBookmarks(projectId: "abc") == [])
    }

    @Test func togglingAnUnknownProjectIsANoOp() {
        let mgr = manager(bookmarks: ["Sources"])
        mgr.toggleFileBookmark(projectId: "nope", path: "docs")
        #expect(mgr.fileBookmarks(projectId: "abc") == ["Sources"])
    }

    @Test func fileBookmarksOfAnUnknownProjectIsEmpty() {
        #expect(manager(bookmarks: ["Sources"]).fileBookmarks(projectId: "nope") == [])
    }

    @Test func removingAStaleBookmarkDropsOnlyThatEntry() {
        let mgr = manager(bookmarks: ["Sources", "docs"])
        mgr.removeFileBookmark(projectId: "abc", path: "Sources")
        #expect(mgr.fileBookmarks(projectId: "abc") == ["docs"])
    }
}
