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
}
