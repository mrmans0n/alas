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

    @Test func preservesFileAndDirectoryPathCollisionsWithExplicitDirectories() {
        assertPreservesFileAndDirectoryPathCollisions(["foo", "foo/bar.swift"], directories: ["foo"])
        assertPreservesFileAndDirectoryPathCollisions(["foo/bar.swift", "foo"], directories: ["foo"])
    }

    @Test func preservesFileAndDirectoryPathCollisionsWithLazyDirectories() {
        assertPreservesFileAndDirectoryPathCollisions(
            ["foo", "foo/bar.swift"],
            lazyDirectories: ["foo"],
            expectLazyDirectory: true
        )
        assertPreservesFileAndDirectoryPathCollisions(
            ["foo/bar.swift", "foo"],
            lazyDirectories: ["foo"],
            expectLazyDirectory: true
        )
    }

    @Test func assignsVisibilityAndLazyDirectoryState() {
        let tree = FileTreeBuilder.build(
            paths: ["Sources/App.swift", ".build"],
            badges: [:],
            visibility: [".build": .ignored],
            directories: [".build"],
            lazyDirectories: [".build"]
        )

        let buildDir = tree.first { $0.path == ".build" }!
        #expect(buildDir.kind == .dir)
        #expect(buildDir.visibility == .ignored)
        #expect(buildDir.childrenState == .notLoaded)
        #expect(buildDir.children == nil)

        let sources = tree.first { $0.path == "Sources" }!
        #expect(sources.visibility == .tracked)
        #expect(sources.childrenState == .loaded)
    }

    @Test func treatsLazyDirectoryPathAsUnloadedDirectory() {
        let tree = FileTreeBuilder.build(
            paths: [".build"],
            badges: [:],
            lazyDirectories: [".build"]
        )

        let buildDir = tree.first { $0.path == ".build" }!
        #expect(buildDir.kind == .dir)
        #expect(buildDir.childrenState == .notLoaded)
        #expect(buildDir.children == nil)
    }

    @Test func preservesUntrackedStatusBadgeSeparatelyFromVisibility() {
        let tree = FileTreeBuilder.build(
            paths: ["new.txt"],
            badges: ["new.txt": "A"],
            visibility: ["new.txt": .untracked]
        )

        let file = tree.first { $0.path == "new.txt" }!
        #expect(file.kind == .file)
        #expect(file.badge == "A")
        #expect(file.visibility == .untracked)
        #expect(file.childrenState == .loaded)
    }

    private func assertPreservesFileAndDirectoryPathCollisions(
        _ paths: [String],
        directories: Set<String> = [],
        lazyDirectories: Set<String> = [],
        expectLazyDirectory: Bool = false
    ) {
        let tree = FileTreeBuilder.build(
            paths: paths,
            badges: ["foo": "D"],
            directories: directories,
            lazyDirectories: lazyDirectories
        )

        #expect(tree.count == 2)
        #expect(tree[0].name == "foo")
        #expect(tree[0].path == "foo")
        #expect(tree[0].kind == .dir)
        #expect(tree[0].id == "dir:foo")
        #expect(tree[0].badge == nil)
        #expect(tree[0].childrenState == (expectLazyDirectory ? .notLoaded : .loaded))
        if expectLazyDirectory {
            #expect(tree[0].children == nil)
        } else {
            #expect(tree[0].children?.first?.name == "bar.swift")
        }

        #expect(tree[1].name == "foo")
        #expect(tree[1].path == "foo")
        #expect(tree[1].kind == .file)
        #expect(tree[1].id == "file:foo")
        #expect(tree[1].badge == "D")
    }
}
