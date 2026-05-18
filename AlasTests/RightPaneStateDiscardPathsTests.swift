import Testing
@testable import Alas

@MainActor
struct RightPaneStateDiscardPathsTests {
    private func cf(
        _ path: String,
        stage: ChangeStage = .unstaged,
        status: String = "M",
        renameFrom: String? = nil
    ) -> ChangedFile {
        ChangedFile(path: path, status: status, stage: stage, add: 0, del: 0, renameFrom: renameFrom)
    }

    @Test func discardPathsForFileReturnsSinglePath() {
        let changes = [cf("a.txt"), cf("b.txt")]
        #expect(RightPaneState.discardPaths(forFileAt: "a.txt", in: changes) == ["a.txt"])
    }

    @Test func discardPathsForStagedRenameIncludesOldAndNewPath() {
        let changes = [cf("b.txt", stage: .staged, status: "R", renameFrom: "a.txt")]
        #expect(RightPaneState.discardPaths(forFileAt: "b.txt", in: changes) == ["b.txt", "a.txt"])
    }

    @Test func discardPathsForFileMissingFromChangesReturnsEmpty() {
        let changes = [cf("a.txt")]
        #expect(RightPaneState.discardPaths(forFileAt: "missing.txt", in: changes).isEmpty)
    }

    @Test func discardPathsForFolderMatchesPrefix() {
        let changes = [
            cf("src/a.txt"),
            cf("src/sub/b.txt"),
            cf("docs/c.txt"),
            cf("srcfoo.txt"), // not under src/
        ]
        let paths = RightPaneState.discardPaths(forFolderAt: "src", in: changes)
        #expect(paths.sorted() == ["src/a.txt", "src/sub/b.txt"])
    }

    @Test func discardPathsForFolderIncludesRenameOrigins() {
        let changes = [
            cf("src/new.txt", stage: .staged, status: "R", renameFrom: "src/old.txt"),
        ]
        let paths = RightPaneState.discardPaths(forFolderAt: "src", in: changes)
        #expect(paths.sorted() == ["src/new.txt", "src/old.txt"])
    }

    @Test func discardPathsForFolderIncludesCrossFolderRenameOrigin() {
        // Staged rename whose origin lives OUTSIDE the folder being discarded.
        // The folder discard must still expand to both new and origin paths so
        // the deletion of the cross-folder origin is also restored.
        let changes = [
            cf("src/new.txt", stage: .staged, status: "R", renameFrom: "docs/old.txt"),
        ]
        let paths = RightPaneState.discardPaths(forFolderAt: "src", in: changes)
        #expect(paths.sorted() == ["docs/old.txt", "src/new.txt"])
    }

    @Test func discardPathsForAllExpandsRenamesAndDeduplicates() {
        let changes = [
            cf("a.txt"),
            cf("b.txt", stage: .staged, status: "R", renameFrom: "old.txt"),
            cf("c.txt"),
        ]
        let paths = RightPaneState.discardPaths(forAllIn: changes)
        #expect(Set(paths) == Set(["a.txt", "b.txt", "old.txt", "c.txt"]))
    }
}
