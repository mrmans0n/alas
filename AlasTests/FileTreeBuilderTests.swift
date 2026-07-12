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

    @Test func explicitDirectoryMetadataDoesNotCreateDuplicateFileLeafForLoadedChildren() {
        let tree = FileTreeBuilder.build(
            paths: ["generated", "generated/keep.txt"],
            badges: [:],
            visibility: ["generated": .ignored],
            directories: ["generated"]
        )

        let generatedNodes = tree.filter { $0.path == "generated" }
        #expect(generatedNodes.count == 1)
        let generated = generatedNodes.first
        #expect(generated?.id == "dir:generated")
        #expect(generated?.kind == .dir)
        #expect(generated?.visibility == .ignored)
        #expect(generated?.childrenState == .loaded)
        #expect(generated?.children?.contains { $0.path == "generated/keep.txt" } == true)
        #expect(!tree.contains { $0.id == "file:generated" })
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

    @Test func requestedDirectoryWithLoadedChildrenMustNotBeLazy() {
        let tree = FileTreeBuilder.build(
            paths: ["src", "src/App.swift"],
            badges: [:],
            directories: ["src"],
            lazyDirectories: []
        )

        let src = tree.first { $0.path == "src" }!
        #expect(src.childrenState == .loaded)
        #expect(src.children?.map(\.path) == ["src/App.swift"])
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

    @Test func nestedDirectoriesKeepExcludedVisibilityWhenPropagated() {
        // Simulates the visibility dict as built by GitService.fileTree()
        // after propagating excluded root visibility to intermediate dirs.
        let tree = FileTreeBuilder.build(
            paths: [".build", ".build/nested/keep.txt", "Sources/App.swift"],
            badges: [:],
            visibility: [".build": .excluded, ".build/nested": .excluded],
            directories: [".build"]
        )

        let buildDir = tree.first { $0.path == ".build" }!
        #expect(buildDir.visibility == .excluded)

        let nestedDir = buildDir.children!.first { $0.path == ".build/nested" }!
        #expect(nestedDir.visibility == .excluded)
    }

    @Test func trackedFilesInsideExcludedDirectoryStayTracked() {
        // When an excluded directory has tracked descendants, the tracked
        // files should keep .tracked visibility (defaulting from the dict).
        let tree = FileTreeBuilder.build(
            paths: [".build", ".build/nested/tracked.swift"],
            badges: [:],
            visibility: [".build": .excluded, ".build/nested": .excluded],
            directories: [".build"]
        )

        let buildDir = tree.first { $0.path == ".build" }!
        #expect(buildDir.visibility == .excluded)

        let nestedDir = buildDir.children!.first { $0.path == ".build/nested" }!
        #expect(nestedDir.visibility == .excluded)

        // Tracked file has no visibility entry → defaults to .tracked
        let trackedFile = nestedDir.children!.first { $0.path == ".build/nested/tracked.swift" }!
        #expect(trackedFile.visibility == .tracked)
    }

    @Test func marksSubmoduleDirectory() {
        let tree = FileTreeBuilder.build(
            paths: ["Submodule"],
            badges: [:],
            directories: ["Submodule"],
            submodules: ["Submodule"]
        )
        let node = tree.first { $0.path == "Submodule" }!
        #expect(node.kind == .dir)
        #expect(node.isSubmodule == true)
    }

    @Test func nonSubmoduleDirectoryStaysFalse() {
        let tree = FileTreeBuilder.build(
            paths: ["Sources/App.swift"],
            badges: [:],
            directories: ["Sources"]
        )
        let node = tree.first { $0.path == "Sources" }!
        #expect(node.kind == .dir)
        #expect(node.isSubmodule == false)
    }

    @Test func marksSubmoduleLeafAsDirectoryWithoutDirectoryMetadata() {
        // A submodule represented only by its gitlink path has no directory
        // metadata in the `directories` set, but should still be a dir.
        let tree = FileTreeBuilder.build(
            paths: ["Submodule"],
            badges: [:],
            submodules: ["Submodule"]
        )
        let node = tree.first { $0.path == "Submodule" }!
        #expect(node.kind == .dir)
        #expect(node.isSubmodule == true)
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
