import Testing
@testable import Alas

struct WorkingTreeChangeGroupTests {
    @Test func groupsStagedAndUnstagedEntriesForSamePathIntoMixedRow() {
        let staged = changedFile("Sources/App.swift", status: "M", stage: .staged, add: 4)
        let unstaged = changedFile("Sources/App.swift", status: "M", stage: .unstaged, add: 2)

        let groups = WorkingTreeChangeGroup.group(files: [staged, unstaged])

        #expect(groups.count == 1)
        #expect(groups[0].path == "Sources/App.swift")
        #expect(groups[0].stageState == .mixed)
        #expect(groups[0].stagedEntries == [staged])
        #expect(groups[0].unstagedEntries == [unstaged])
        #expect(groups[0].primaryEntry == unstaged)
    }

    @Test func reportsCheckedAndUncheckedStateForSingleStageRows() {
        let staged = changedFile("A.swift", stage: .staged)
        let unstaged = changedFile("B.swift", stage: .unstaged)

        let groups = WorkingTreeChangeGroup.group(files: [unstaged, staged])

        #expect(groups.map(\.path) == ["A.swift", "B.swift"])
        #expect(groups.first { $0.path == "A.swift" }?.stageState == .staged)
        #expect(groups.first { $0.path == "B.swift" }?.stageState == .unstaged)
    }

    @Test func returnsRecursiveEntriesForFolderStageMenus() {
        let stagedRoot = changedFile("README.md", stage: .staged)
        let stagedChild = changedFile("Sources/App.swift", stage: .staged)
        let unstagedChild = changedFile("Sources/App.swift", stage: .unstaged)
        let unstagedSibling = changedFile("Sources/View.swift", stage: .unstaged)
        let stagedNested = changedFile("Sources/Models/User.swift", stage: .staged)

        let groups = WorkingTreeChangeGroup.group(files: [
            stagedRoot,
            stagedChild,
            unstagedChild,
            unstagedSibling,
            stagedNested
        ])

        #expect(groups.stagedEntries(under: "Sources") == [stagedChild, stagedNested])
        #expect(groups.unstagedEntries(under: "Sources") == [unstagedChild, unstagedSibling])
    }

    private func changedFile(
        _ path: String,
        status: String = "M",
        stage: ChangeStage = .unstaged,
        add: Int = 1,
        del: Int = 0
    ) -> ChangedFile {
        ChangedFile(path: path, status: status, stage: stage, add: add, del: del, renameFrom: nil)
    }
}
