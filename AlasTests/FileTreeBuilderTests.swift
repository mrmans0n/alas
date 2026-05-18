import Testing
@testable import Alas

struct FileTreeBuilderTests {
    @Test func buildsNestedTree() {
        let paths = ["a/b/c.rs", "a/d.rs", "e.txt"]
        let badges = ["a/b/c.rs": "M"]
        let tree = FileTreeBuilder.build(paths: paths, badges: badges)
        #expect(tree.count == 2)
        let aDir = tree.first { $0.name == "a" }!
        #expect(aDir.kind == .dir)
        #expect(aDir.children?.count == 2)
        let bDir = aDir.children!.first { $0.name == "b" }!
        let cFile = bDir.children!.first { $0.name == "c.rs" }!
        #expect(cFile.badge == "M")
    }

    @Test func preservesFileAndDirectoryPathCollisions() {
        assertPreservesFileAndDirectoryPathCollisions(["foo", "foo/bar.swift"])
        assertPreservesFileAndDirectoryPathCollisions(["foo/bar.swift", "foo"])
    }

    private func assertPreservesFileAndDirectoryPathCollisions(_ paths: [String]) {
        let tree = FileTreeBuilder.build(paths: paths, badges: ["foo": "D"])

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
}
