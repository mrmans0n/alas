import Testing
@testable import Alas

struct WorkingTreeFlatRowTests {
    @Test func flattensVisibleTreeAndRespectsCollapsedFolders() {
        let groups = WorkingTreeChangeGroup.group(files: [
            ChangedFile(path: "Sources/App.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil),
            ChangedFile(path: "Sources/UI/Button.swift", status: "A", stage: .unstaged, add: 2, del: 0, renameFrom: nil),
            ChangedFile(path: "README.md", status: "M", stage: .staged, add: 1, del: 1, renameFrom: nil),
        ])

        let expanded = WorkingTreeFlatRow.make(groups: groups, collapsedPaths: [])
        #expect(expanded.map(\.id) == [
            "dir:Sources", "dir:Sources/UI", "file:Sources/UI/Button.swift",
            "file:Sources/App.swift", "file:README.md",
        ])
        #expect(expanded.map(\.depth) == [0, 1, 2, 1, 0])

        let collapsed = WorkingTreeFlatRow.make(
            groups: groups,
            collapsedPaths: ["working-tree:Sources"]
        )
        #expect(collapsed.map(\.id) == ["dir:Sources", "file:README.md"])
    }
}
