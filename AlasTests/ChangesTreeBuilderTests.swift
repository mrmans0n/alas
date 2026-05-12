import Testing
@testable import Alas

struct ChangesTreeBuilderTests {
    @Test func buildsNestedTree() {
        let tree = ChangesTreeBuilder.build(files: [
            changedFile("a/b/c.swift", status: "M"),
            changedFile("a/d.swift", status: "A"),
            changedFile("e.swift", status: "D")
        ])

        #expect(tree.map(\.name) == ["a", "e.swift"])
        let aDir = tree.first { $0.name == "a" }!
        #expect(aDir.kind == .dir)
        #expect(aDir.children?.map(\.name) == ["b", "d.swift"])
        let bDir = aDir.children!.first { $0.name == "b" }!
        #expect(bDir.children?.first?.name == "c.swift")
        #expect(bDir.children?.first?.badge == "M")
    }

    @Test func compactsSingleChildDirectoryChains() {
        let tree = ChangesTreeBuilder.build(files: [
            changedFile("d/e/f/g/ThisIsDeep.ext")
        ])

        #expect(tree.count == 1)
        #expect(tree[0].name == "d/e/f/g")
        #expect(tree[0].path == "d/e/f/g")
        #expect(tree[0].children?.first?.name == "ThisIsDeep.ext")
    }

    @Test func preservesBranchesWhileCompactingNestedChains() {
        let tree = ChangesTreeBuilder.build(files: [
            changedFile("a/b/c/MyFileWithChanges.ext"),
            changedFile("a/b/d/MyOtherFile.ext"),
            changedFile("a/b/d/e/f/g/ThisIsDeep.ext")
        ])

        #expect(tree.map(\.name) == ["a/b"])
        let ab = tree[0]
        #expect(ab.children?.map(\.name) == ["c", "d"])
        let d = ab.children!.first { $0.name == "d" }!
        #expect(d.children?.map(\.name) == ["e/f/g", "MyOtherFile.ext"])
    }

    @Test func handlesRootFilesAndEmptyInput() {
        #expect(ChangesTreeBuilder.build(files: []).isEmpty)

        let tree = ChangesTreeBuilder.build(files: [
            changedFile("Root.swift"),
            changedFile("Sources/App.swift")
        ])

        #expect(tree.map(\.name) == ["Sources", "Root.swift"])
        #expect(tree.first { $0.name == "Root.swift" }?.kind == .file)
    }

    @Test func propagatesStatusBadgeToFileLeaves() {
        let tree = ChangesTreeBuilder.build(files: [
            changedFile("Sources/App.swift", status: "R")
        ])

        let file = tree[0].children![0]
        #expect(file.name == "App.swift")
        #expect(file.path == "Sources/App.swift")
        #expect(file.badge == "R")
    }

    @Test func preservesFileAndDirectoryPathCollisions() {
        assertPreservesFileAndDirectoryPathCollisions([
            changedFile("foo", status: "D"),
            changedFile("foo/bar.swift", status: "A")
        ])

        assertPreservesFileAndDirectoryPathCollisions([
            changedFile("foo/bar.swift", status: "A"),
            changedFile("foo", status: "D")
        ])
    }

    private func assertPreservesFileAndDirectoryPathCollisions(_ files: [ChangedFile]) {
        let tree = ChangesTreeBuilder.build(files: files)

        #expect(tree.count == 2)
        #expect(tree[0].name == "foo")
        #expect(tree[0].path == "foo")
        #expect(tree[0].kind == .dir)
        #expect(tree[0].id == "dir:foo")
        #expect(tree[0].children?.first?.name == "bar.swift")

        #expect(tree[1].name == "foo")
        #expect(tree[1].path == "foo")
        #expect(tree[1].kind == .file)
        #expect(tree[1].id == "file:foo")
        #expect(tree[1].badge == "D")
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
