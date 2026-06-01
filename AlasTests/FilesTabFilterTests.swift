import Foundation
import Testing
@testable import Alas

struct FilesTabFilterTests {
    private func node(
        name: String,
        path: String,
        kind: FileTreeNode.Kind,
        visibility: FileVisibility,
        children: [FileTreeNode]? = nil
    ) -> FileTreeNode {
        FileTreeNode(
            name: name,
            path: path,
            kind: kind,
            children: children,
            badge: nil,
            visibility: visibility,
            childrenState: .loaded
        )
    }

    @Test func showIgnoredTrueReturnsInputUnchanged() {
        let tree = [
            node(name: "Sources", path: "Sources", kind: .dir, visibility: .tracked, children: [
                node(name: "App.swift", path: "Sources/App.swift", kind: .file, visibility: .tracked),
                node(name: "cache.log", path: "Sources/cache.log", kind: .file, visibility: .ignored)
            ]),
            node(name: ".build", path: ".build", kind: .dir, visibility: .ignored)
        ]
        let result = FilesTabView.filteredNodes(tree, showIgnored: true)
        #expect(result == tree)
    }

    @Test func showIgnoredFalseDropsTopLevelIgnoredAndExcluded() {
        let tree = [
            node(name: "Sources", path: "Sources", kind: .dir, visibility: .tracked),
            node(name: ".build", path: ".build", kind: .dir, visibility: .ignored),
            node(name: "DerivedData", path: "DerivedData", kind: .dir, visibility: .excluded),
            node(name: "README.md", path: "README.md", kind: .file, visibility: .tracked)
        ]
        let result = FilesTabView.filteredNodes(tree, showIgnored: false)
        #expect(result.map(\.path) == ["Sources", "README.md"])
    }

    @Test func showIgnoredFalseDropsNestedIgnoredChildren() {
        let tree = [
            node(name: "Sources", path: "Sources", kind: .dir, visibility: .tracked, children: [
                node(name: "App.swift", path: "Sources/App.swift", kind: .file, visibility: .tracked),
                node(name: "cache.log", path: "Sources/cache.log", kind: .file, visibility: .ignored),
                node(name: "secrets.env", path: "Sources/secrets.env", kind: .file, visibility: .excluded)
            ])
        ]
        let result = FilesTabView.filteredNodes(tree, showIgnored: false)
        let sources = result.first
        #expect(sources?.path == "Sources")
        #expect(sources?.children?.map(\.path) == ["Sources/App.swift"])
    }

    @Test func showIgnoredFalsePreservesIgnoredDirectoryWithTrackedDescendant() {
        // GitService can build a tree where a top-level directory is marked
        // ignored but still contains tracked descendants (e.g., a file inside
        // an ignored dir that was committed before the gitignore rule). The
        // filter must not drop such a directory or the tracked descendant
        // becomes unreachable.
        let tree = [
            node(name: ".build", path: ".build", kind: .dir, visibility: .ignored, children: [
                node(name: "out.swift", path: ".build/out.swift", kind: .file, visibility: .tracked),
                node(name: "cache.log", path: ".build/cache.log", kind: .file, visibility: .ignored)
            ])
        ]
        let result = FilesTabView.filteredNodes(tree, showIgnored: false)
        #expect(result.map(\.path) == [".build"])
        #expect(result.first?.children?.map(\.path) == [".build/out.swift"])
    }

    @Test func showIgnoredFalseDropsIgnoredDirectoryWithOnlyIgnoredChildren() {
        let tree = [
            node(name: ".build", path: ".build", kind: .dir, visibility: .ignored, children: [
                node(name: "cache.log", path: ".build/cache.log", kind: .file, visibility: .ignored)
            ])
        ]
        let result = FilesTabView.filteredNodes(tree, showIgnored: false)
        #expect(result.isEmpty)
    }

    @Test func showIgnoredFalsePreservesIgnoredDirectoryWithTrackedNestedDescendant() {
        let tree = [
            node(name: ".build", path: ".build", kind: .dir, visibility: .ignored, children: [
                node(name: "gen", path: ".build/gen", kind: .dir, visibility: .ignored, children: [
                    node(name: "kept.swift", path: ".build/gen/kept.swift", kind: .file, visibility: .tracked)
                ])
            ])
        ]
        let result = FilesTabView.filteredNodes(tree, showIgnored: false)
        #expect(result.map(\.path) == [".build"])
        #expect(result.first?.children?.map(\.path) == [".build/gen"])
        #expect(result.first?.children?.first?.children?.map(\.path) == [".build/gen/kept.swift"])
    }

    @Test func showIgnoredFalsePreservesTrackedDirectoryWithOnlyIgnoredChildren() {
        let tree = [
            node(name: "Sources", path: "Sources", kind: .dir, visibility: .tracked, children: [
                node(name: "cache.log", path: "Sources/cache.log", kind: .file, visibility: .ignored)
            ])
        ]
        let result = FilesTabView.filteredNodes(tree, showIgnored: false)
        #expect(result.map(\.path) == ["Sources"])
        #expect(result.first?.children?.isEmpty == true)
    }

    @Test func revealDisplayNameUsesLastPathComponent() {
        #expect(FilesTabView.revealDisplayName(for: "Sources/Center/App.swift") == "App.swift")
        #expect(FilesTabView.revealDisplayName(for: "README.md") == "README.md")
    }
}
