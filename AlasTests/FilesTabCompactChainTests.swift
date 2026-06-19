import Testing
@testable import Alas

struct FilesTabCompactChainTests {
    // MARK: - Helpers

    private func dir(
        name: String,
        path: String,
        children: [FileTreeNode]? = nil,
        childrenState: DirectoryChildrenState = .loaded,
        visibility: FileVisibility = .tracked,
        isSubmodule: Bool = false
    ) -> FileTreeNode {
        FileTreeNode(
            name: name,
            path: path,
            kind: .dir,
            children: children,
            badge: nil,
            visibility: visibility,
            childrenState: childrenState,
            isSubmodule: isSubmodule
        )
    }

    private func file(name: String, path: String) -> FileTreeNode {
        FileTreeNode(name: name, path: path, kind: .file, children: nil, badge: nil)
    }

    // MARK: - Tests

    @Test func fileNodeReturnsItself() {
        let node = file(name: "App.swift", path: "App.swift")
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "App.swift")
        #expect(result.chainPaths == ["App.swift"])
        #expect(result.terminal.path == "App.swift")
    }

    @Test func dirWithNoChildrenReturnsItself() {
        let node = dir(name: "src", path: "src", children: [])
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "src")
        #expect(result.chainPaths == ["src"])
        #expect(result.terminal.path == "src")
    }

    @Test func dirWithTwoChildrenReturnsItself() {
        let node = dir(name: "src", path: "src", children: [
            dir(name: "main", path: "src/main"),
            dir(name: "test", path: "src/test")
        ])
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "src")
        #expect(result.chainPaths == ["src"])
        #expect(result.terminal.path == "src")
    }

    @Test func dirWithOneFileChildReturnsItself() {
        let node = dir(name: "src", path: "src", children: [
            file(name: "main.swift", path: "src/main.swift")
        ])
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "src")
        #expect(result.chainPaths == ["src"])
        #expect(result.terminal.path == "src")
    }

    @Test func singleChildDirChainDepth1() {
        let node = dir(name: "src", path: "src", children: [
            dir(name: "main", path: "src/main", children: [
                file(name: "App.swift", path: "src/main/App.swift")
            ])
        ])
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "src/main")
        #expect(result.chainPaths == ["src", "src/main"])
        #expect(result.terminal.path == "src/main")
    }

    @Test func singleChildDirChainDepth3() {
        let leaf = dir(name: "example", path: "src/main/java/example", children: [
            file(name: "Main.java", path: "src/main/java/example/Main.java")
        ])
        let java = dir(name: "java", path: "src/main/java", children: [leaf])
        let main = dir(name: "main", path: "src/main", children: [java])
        let src = dir(name: "src", path: "src", children: [main])
        let result = FilesTabView.compactChain(from: src)
        #expect(result.displayName == "src/main/java/example")
        #expect(result.chainPaths == ["src", "src/main", "src/main/java", "src/main/java/example"])
        #expect(result.terminal.path == "src/main/java/example")
    }

    @Test func chainStopsAtNotLoadedChild() {
        let node = dir(name: "src", path: "src", children: [
            dir(name: "main", path: "src/main", childrenState: .notLoaded)
        ])
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "src")
        #expect(result.chainPaths == ["src"])
        #expect(result.terminal.path == "src")
    }

    @Test func chainStopsAtLoadingChild() {
        let node = dir(name: "src", path: "src", children: [
            dir(name: "main", path: "src/main", childrenState: .loading)
        ])
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "src")
        #expect(result.chainPaths == ["src"])
        #expect(result.terminal.path == "src")
    }

    @Test func submoduleDirIsNotCompacted() {
        let node = dir(name: "vendor", path: "vendor", isSubmodule: true)
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "vendor")
        #expect(result.chainPaths == ["vendor"])
        #expect(result.terminal.path == "vendor")
    }

    @Test func chainStopsBeforeSubmoduleChild() {
        let node = dir(name: "src", path: "src", children: [
            dir(name: "sub", path: "src/sub", isSubmodule: true)
        ])
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "src")
        #expect(result.chainPaths == ["src"])
        #expect(result.terminal.path == "src")
    }

    @Test func chainStopsAtVisibilityBoundary() {
        let node = dir(name: "ignored", path: "ignored", children: [
            dir(name: "tracked", path: "ignored/tracked", children: [
                file(name: "App.swift", path: "ignored/tracked/App.swift")
            ])
        ], visibility: .ignored)
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "ignored")
        #expect(result.chainPaths == ["ignored"])
        #expect(result.terminal.path == "ignored")
    }

    @Test func chainContinuesWithSameVisibility() {
        let node = dir(name: "ignored", path: "ignored", children: [
            dir(name: "child", path: "ignored/child", children: [
                file(name: "cache.log", path: "ignored/child/cache.log")
            ], visibility: .ignored)
        ], visibility: .ignored)
        let result = FilesTabView.compactChain(from: node)
        #expect(result.displayName == "ignored/child")
        #expect(result.chainPaths == ["ignored", "ignored/child"])
        #expect(result.terminal.path == "ignored/child")
    }
}
