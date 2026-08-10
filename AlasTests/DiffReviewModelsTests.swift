import Foundation
import Testing
@testable import Alas

struct DiffReviewModelsTests {
    @Test func fileIdentityIncludesNamespaceAndPath() {
        let staged = DiffReviewFileID(namespace: "staged", path: "Sources/App.swift")
        let commit = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")

        #expect(staged.rawValue == "staged:Sources/App.swift")
        #expect(commit.rawValue == "commit:Sources/App.swift")
        #expect(staged != commit)
    }

    @Test func expandedRailFileRowsDoNotReserveStatusGlyphSpace() {
        #expect(DiffReviewFileStatus.added.expandedRailGlyph == nil)
        #expect(DiffReviewFileStatus.modified.expandedRailGlyph == nil)
        #expect(DiffReviewFileStatus.deleted.expandedRailGlyph == nil)
        #expect(DiffReviewFileStatus.renamed.expandedRailGlyph == nil)
        #expect(DiffReviewFileStatus.copied.expandedRailGlyph == nil)
        #expect(DiffReviewFileStatus.conflicted.expandedRailGlyph == nil)
        #expect(DiffReviewFileStatus.unknown.expandedRailGlyph == nil)
    }

    @Test func ungroupedSessionPreservesIncomingOrderAndBuildsTree() {
        let files = [
            summary(path: "b.swift", additions: 2, deletions: 1),
            summary(path: "Sources/a.swift", status: .added, additions: 4, deletions: 0),
        ]

        let session = DiffReviewSessionModel(files: files, groupsEnabled: false)

        #expect(session.files.map(\.path) == ["b.swift", "Sources/a.swift"])
        #expect(session.groups.isEmpty)
        #expect(session.fileCount == 2)
        #expect(session.totalAdditions == 6)
        #expect(session.totalDeletions == 1)
        #expect(session.tree.map(\.name) == ["Sources", "b.swift"])
        #expect(session.tree.first?.children?.map(\.name) == ["a.swift"])
    }

    @Test func groupedSessionSortsByReviewChangesSourceThenLexicalGroupID() {
        let files = [
            summary(path: "z.swift", namespace: "other", groupID: "z-other", groupTitle: "Z Other"),
            summary(path: "staged.swift", namespace: "staged", groupID: "staged", groupTitle: "Staged", status: .deleted, additions: 0, deletions: 3),
            summary(path: "alpha.swift", namespace: "alpha", groupID: "alpha", groupTitle: "Alpha"),
            summary(path: "unstaged.swift", namespace: "unstaged", groupID: "unstaged", groupTitle: "Unstaged"),
        ]

        let session = DiffReviewSessionModel(files: files, groupsEnabled: true)

        #expect(session.groups.map(\.id) == ["unstaged", "staged", "alpha", "z-other"])
        #expect(session.groups.map(\.title) == ["Unstaged", "Staged", "Alpha", "Z Other"])
        #expect(session.groups.flatMap(\.files).map(\.id.rawValue) == [
            "unstaged:unstaged.swift",
            "staged:staged.swift",
            "alpha:alpha.swift",
            "other:z.swift",
        ])
        #expect(session.tree.isEmpty)
    }

    @Test func railRowsEmitHeadersOnlyForGroupedSessions() {
        let grouped = DiffReviewSessionModel(files: [
            summary(path: "Sources/App.swift", namespace: "unstaged", groupID: "unstaged", groupTitle: "Unstaged"),
            summary(path: "Tests/AppTests.swift", namespace: "staged", groupID: "staged", groupTitle: "Staged", status: .added, additions: 2, deletions: 0),
        ], groupsEnabled: true)
        let ungrouped = DiffReviewSessionModel(files: [
            summary(path: "Sources/App.swift"),
            summary(path: "Tests/AppTests.swift", status: .added, additions: 2, deletions: 0),
        ], groupsEnabled: false)

        let groupedRows = DiffReviewRailRows.rows(for: grouped)
        let ungroupedRows = DiffReviewRailRows.rows(for: ungrouped)

        #expect(groupedRows.contains { $0.id == "source:unstaged" })
        #expect(groupedRows.contains { $0.id == "source:staged" })
        #expect(groupedRows.contains { $0.id == "file:unstaged:unstaged:Sources/App.swift" })
        #expect(!ungroupedRows.contains { $0.id.hasPrefix("source:") })
        #expect(ungroupedRows.contains { $0.id == "file:commit:Sources/App.swift" })
        #expect(ungroupedRows.contains { $0.id == "file:commit:Tests/AppTests.swift" })
    }

    @Test func railRowsGroupFilesByDirectParentDirectoryWithoutDeepTreeIndentation() {
        let session = DiffReviewSessionModel(files: [
            summary(path: "Alas/Sources/ACP/Protocol/ACPConfigOption.swift"),
            summary(path: "Alas/Sources/ACP/UI/ACPComposerShell.swift"),
            summary(path: "AlasTests/ACP/Protocol/ACPConfigOptionTests.swift"),
            summary(path: "README.md"),
        ], groupsEnabled: false)

        let rows = DiffReviewRailRows.rows(for: session).map(\.kind)

        #expect(rows == [
            .directory("Alas/Sources/ACP/Protocol", depth: 0),
            .file(summary(path: "Alas/Sources/ACP/Protocol/ACPConfigOption.swift"), depth: 1, name: "ACPConfigOption.swift"),
            .directory("Alas/Sources/ACP/UI", depth: 0),
            .file(summary(path: "Alas/Sources/ACP/UI/ACPComposerShell.swift"), depth: 1, name: "ACPComposerShell.swift"),
            .directory("AlasTests/ACP/Protocol", depth: 0),
            .file(summary(path: "AlasTests/ACP/Protocol/ACPConfigOptionTests.swift"), depth: 1, name: "ACPConfigOptionTests.swift"),
            .file(summary(path: "README.md"), depth: 0, name: "README.md"),
        ])
    }

    @Test func groupedRailRowIDsAreUniqueForRepeatedDirectoryPaths() {
        let session = DiffReviewSessionModel(files: [
            summary(path: "Sources/App.swift", namespace: "unstaged", groupID: "unstaged", groupTitle: "Unstaged"),
            summary(path: "Sources/App.swift", namespace: "staged", groupID: "staged", groupTitle: "Staged"),
        ], groupsEnabled: true)

        let ids = DiffReviewRailRows.rows(for: session).map(\.id)

        #expect(ids.count == Set(ids).count)
        #expect(ids.contains("directory:unstaged:Sources:0"))
        #expect(ids.contains("directory:staged:Sources:0"))
        #expect(ids.contains("file:unstaged:unstaged:Sources/App.swift"))
        #expect(ids.contains("file:staged:staged:Sources/App.swift"))
    }

    @Test func railFilterFuzzyMatchesFullRelativePathsWithoutReorderingFiles() {
        let firstMatch = summary(path: "Sources/Auth/LoginView.swift")
        let skipped = summary(path: "Sources/EditorView.swift")
        let secondMatch = summary(path: "Tests/Auth/LoginViewTests.swift")
        let session = DiffReviewSessionModel(
            files: [firstMatch, skipped, secondMatch],
            groupsEnabled: false
        )

        let filtered = DiffReviewRailFilter.session(session, matching: "AUTHLOGIN")

        #expect(filtered.files.map(\.id) == [firstMatch.id, secondMatch.id])
    }

    @Test func railFilterTreatsWhitespaceOnlyQueryAsInactive() {
        let session = DiffReviewSessionModel(files: [
            summary(path: "Sources/App.swift"),
            summary(path: "Tests/AppTests.swift"),
        ], groupsEnabled: false)

        let filtered = DiffReviewRailFilter.session(session, matching: "  \n\t ")

        #expect(filtered == session)
        #expect(!DiffReviewRailFilter.isActive("  \n\t "))
    }

    @Test func railFilterPrunesEmptyGroupsDirectoriesAndDividers() {
        let session = DiffReviewSessionModel(files: [
            summary(
                path: "Sources/Auth/LoginView.swift",
                namespace: "unstaged",
                groupID: "unstaged",
                groupTitle: "Unstaged"
            ),
            summary(
                path: "Sources/EditorView.swift",
                namespace: "unstaged",
                groupID: "unstaged",
                groupTitle: "Unstaged"
            ),
            summary(
                path: "Tests/Auth/LoginViewTests.swift",
                namespace: "staged",
                groupID: "staged",
                groupTitle: "Staged"
            ),
            summary(
                path: "Docs/ReleaseNotes.md",
                namespace: "other",
                groupID: "other",
                groupTitle: "Other"
            ),
        ], groupsEnabled: true)

        let filtered = DiffReviewRailFilter.session(session, matching: "authlogin")
        let rows = DiffReviewRailRows.rows(for: filtered)

        #expect(filtered.groups.map(\.id) == ["unstaged", "staged"])
        #expect(filtered.groups.map(\.fileCount) == [1, 1])
        #expect(rows.map(\.id) == [
            "source:unstaged",
            "directory:unstaged:Sources/Auth:0",
            "file:unstaged:unstaged:Sources/Auth/LoginView.swift",
            "divider:unstaged",
            "source:staged",
            "directory:staged:Tests/Auth:0",
            "file:staged:staged:Tests/Auth/LoginViewTests.swift",
        ])
    }

    @Test func fileSummaryCodableRoundTripDerivesIdentityFromNamespaceAndPath() throws {
        let data = Data("""
        {
          "id": {
            "namespace": "wrong",
            "path": "Wrong.swift"
          },
          "path": "Sources/App.swift",
          "namespace": "commit",
          "groupID": "commit-group",
          "groupTitle": "Commit",
          "status": "renamed",
          "additions": 8,
          "deletions": 2,
          "isRenderable": true,
          "originalPath": "Sources/OldApp.swift"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(DiffReviewFileSummary.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(DiffReviewFileSummary.self, from: encoded)
        let encodedObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(decoded.id == DiffReviewFileID(namespace: "commit", path: "Sources/App.swift"))
        #expect(encodedObject["id"] == nil)
        #expect(roundTripped == decoded)
        #expect(roundTripped.id.rawValue == "commit:Sources/App.swift")
    }

    @Test func fileTreeNodeJSONRoundTripsDirectoryWithFileChild() throws {
        let file = summary(path: "Sources/App.swift")
        let node = DiffReviewFileTreeNode(
            name: "Sources",
            path: "Sources",
            kind: .directory,
            children: [
                DiffReviewFileTreeNode(
                    name: "App.swift",
                    path: "Sources/App.swift",
                    kind: .file,
                    children: nil,
                    file: file
                ),
            ],
            file: nil
        )

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(DiffReviewFileTreeNode.self, from: data)

        #expect(decoded == node)
        #expect(decoded.children?.first?.file?.id.rawValue == "commit:Sources/App.swift")
    }
}

private func summary(
    path: String,
    namespace: String = "commit",
    groupID: String? = nil,
    groupTitle: String? = nil,
    status: DiffReviewFileStatus = .modified,
    additions: Int = 1,
    deletions: Int = 0,
    isRenderable: Bool = true,
    originalPath: String? = nil
) -> DiffReviewFileSummary {
    DiffReviewFileSummary(
        path: path,
        namespace: namespace,
        groupID: groupID,
        groupTitle: groupTitle,
        status: status,
        additions: additions,
        deletions: deletions,
        isRenderable: isRenderable,
        originalPath: originalPath
    )
}
