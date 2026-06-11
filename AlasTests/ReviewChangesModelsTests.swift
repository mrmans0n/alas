import Foundation
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
                path: "Sources/Center/DiffPaneView.swift",
                source: .unstaged,
                status: .modified,
                additions: 12,
                deletions: 3,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
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
                path: "a.swift",
                source: .unstaged,
                status: .modified,
                additions: 3,
                deletions: 1,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
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

    @Test func fileSummaryDecodingDerivesIdentityFromSourceAndPath() throws {
        let data = Data("""
        {
          "id": {
            "source": "staged",
            "path": "Other.swift"
          },
          "path": "Sources/App.swift",
          "source": "unstaged",
          "status": "modified",
          "additions": 8,
          "deletions": 2,
          "isRenderable": true
        }
        """.utf8)

        let summary = try JSONDecoder().decode(ReviewChangesFileSummary.self, from: data)

        #expect(summary.id == ReviewChangesFileID(source: .unstaged, path: "Sources/App.swift"))
        #expect(summary.path == "Sources/App.swift")
        #expect(summary.source == .unstaged)
    }

    @Test func duplicatePathTreeFilesOrderUnstagedBeforeStaged() {
        let files = [
            ReviewChangesFileSummary(
                path: "Sources/App.swift",
                source: .staged,
                status: .modified,
                additions: 1,
                deletions: 0,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                path: "Sources/App.swift",
                source: .unstaged,
                status: .modified,
                additions: 2,
                deletions: 1,
                isRenderable: true
            ),
        ]

        let tree = ReviewChangesFileTreeBuilder.build(files: files)

        #expect(tree.count == 1)
        #expect(tree[0].name == "Sources")
        #expect(tree[0].children?.map(\.file?.id.rawValue) == [
            "unstaged:Sources/App.swift",
            "staged:Sources/App.swift",
        ])
    }
}
