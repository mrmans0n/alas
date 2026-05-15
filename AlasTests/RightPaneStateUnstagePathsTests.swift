import Testing
@testable import Alas

@MainActor
struct RightPaneStateUnstagePathsTests {
    @Test func modifiedFileSendsSinglePath() {
        let file = ChangedFile(
            path: "a.txt",
            status: "M",
            stage: .staged,
            add: 1, del: 0,
            renameFrom: nil
        )
        #expect(RightPaneState.unstagePaths(for: file) == ["a.txt"])
    }

    @Test func renamedFileSendsBothPaths() {
        // Without this, `git restore --staged -- b.txt` would leave the
        // deletion of `a.txt` still staged and `b.txt` showing as untracked.
        let file = ChangedFile(
            path: "b.txt",
            status: "R",
            stage: .staged,
            add: 0, del: 0,
            renameFrom: "a.txt"
        )
        #expect(RightPaneState.unstagePaths(for: file) == ["b.txt", "a.txt"])
    }

    @Test func renameWithoutRenameFromIsTreatedAsSinglePath() {
        // Defensive: if `status == "R"` but renameFrom is nil/empty, don't
        // crash or invent paths — just pass the new path.
        let file = ChangedFile(
            path: "b.txt",
            status: "R",
            stage: .staged,
            add: 0, del: 0,
            renameFrom: nil
        )
        #expect(RightPaneState.unstagePaths(for: file) == ["b.txt"])
    }
}
