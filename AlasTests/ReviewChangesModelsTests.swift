import Testing
@testable import Alas

struct ReviewChangesModelsTests {
    @Test func fileIdentityIncludesSourceAndPath() {
        let unstaged = ReviewChangesFileID(source: .unstaged, path: "Sources/App.swift")
        let staged = ReviewChangesFileID(source: .staged, path: "Sources/App.swift")

        #expect(unstaged.rawValue == "unstaged:Sources/App.swift")
        #expect(staged.rawValue == "staged:Sources/App.swift")
        #expect(unstaged != staged)
    }

    @Test func buildsFlattenedDirectoryTreeWithDirectoriesBeforeFiles() {
        let files = [
            ReviewChangesFileSummary(
                id: .init(source: .unstaged, path: "Sources/Center/DiffPaneView.swift"),
                path: "Sources/Center/DiffPaneView.swift",
                source: .unstaged,
                status: .modified,
                additions: 12,
                deletions: 3,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                id: .init(source: .unstaged, path: "README.md"),
                path: "README.md",
                source: .unstaged,
                status: .added,
                additions: 4,
                deletions: 0,
                isRenderable: true
            ),
        ]

        let tree = ReviewChangesFileTreeBuilder.build(files: files)

        #expect(tree.map(\.name) == ["Sources/Center", "README.md"])
        #expect(tree[0].kind == .directory)
        #expect(tree[0].path == "Sources/Center")
        #expect(tree[0].children?.map(\.name) == ["DiffPaneView.swift"])
        #expect(tree[0].children?.first?.file?.path == "Sources/Center/DiffPaneView.swift")
    }

    @Test func sessionTotalsIncludeAllFiles() {
        let files = [
            ReviewChangesFileSummary(
                id: .init(source: .unstaged, path: "a.swift"),
                path: "a.swift",
                source: .unstaged,
                status: .modified,
                additions: 3,
                deletions: 1,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                id: .init(source: .staged, path: "b.swift"),
                path: "b.swift",
                source: .staged,
                status: .deleted,
                additions: 0,
                deletions: 5,
                isRenderable: false
            ),
        ]

        let session = ReviewChangesSessionModel(files: files)

        #expect(session.fileCount == 2)
        #expect(session.totalAdditions == 3)
        #expect(session.totalDeletions == 6)
        #expect(session.sections.map(\.source) == [.unstaged, .staged])
    }
}
