import Testing
@testable import AlasRemoteKit

struct RemoteWorkspaceRulesTests {
    private func node(_ path: String, dir: Bool = false) -> RemoteFileNode {
        RemoteFileNode(name: String(path.split(separator: "/").last!), path: path, kind: dir ? "dir" : "file",
                       badge: nil, childrenState: "loaded", isSubmodule: false)
    }

    private func tree() -> RemoteFileTree {
        var t = RemoteFileTree()
        t.apply(path: nil, nodes: [node("b.txt"), node("src", dir: true), node("A.txt"), node("lib", dir: true)])
        t.apply(path: "src", nodes: [node("src/deep", dir: true), node("src/x.swift")])
        t.apply(path: "src/deep", nodes: [node("src/deep/y.swift")])
        t.expanded = ["src", "src/deep"]
        return t
    }

    @Test func applySortsDirectoriesFirstThenCaseInsensitiveName() {
        #expect(tree().children[""]?.map(\.name) == ["lib", "src", "A.txt", "b.txt"])
    }

    @Test func vanishedDirectoryTakesDescendantsWithIt() {
        var t = tree()
        t.apply(path: nil, nodes: [node("lib", dir: true), node("A.txt")])
        #expect(t.children["src"] == nil && t.children["src/deep"] == nil)
        #expect(t.expanded.isEmpty)
    }

    @Test func rowsShowOnlyChildrenOfExpandedDirectories() {
        var t = tree()
        #expect(t.rows().map(\.node.path) == ["lib", "src", "src/deep", "src/deep/y.swift", "src/x.swift", "A.txt", "b.txt"])
        t.expanded = ["src"]
        let rows = t.rows()
        #expect(rows.map(\.node.path) == ["lib", "src", "src/deep", "src/x.swift", "A.txt", "b.txt"])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 0, 0])
    }

    @Test func pathsToRefreshAreParentsFirstAndSkipForgotten() {
        var t = tree()
        t.expanded.insert("lib")
        #expect(t.pathsToRefresh() == ["lib", "src", "src/deep"])
        t.apply(path: nil, nodes: [node("A.txt")])
        #expect(t.pathsToRefresh().isEmpty)
    }

    @Test(arguments: [
        ("main", 1, 0, false, "vs main · 1 file · +3 −1"),
        (nil, 2, 0, false, "2 files · +3 −1"),
        ("main", 2, 1, false, "vs main · 2 files · +3 −1 · 1 commit"),
        ("main", 2, 4, false, "vs main · 2 files · +3 −1 · 4 commits"),
        ("main", 2, 100, true, "vs main · 2 files · +3 −1 · 100+ commits"),
    ] as [(String?, Int, Int, Bool, String)])
    func summaryFormat(ref: String?, files: Int, commits: Int, truncated: Bool, expected: String) {
        #expect(RemoteChangesRules.summary(comparisonRef: ref, fileCount: files, add: 3, del: 1, commitCount: commits, commitsTruncated: truncated) == expected)
    }

    @Test func badgePrefersLoadedCountAndMarksTruncation() {
        #expect(RemoteChangesRules.badge(loaded: 5, truncated: true, fallback: 9) == "5+")
        #expect(RemoteChangesRules.badge(loaded: 5, truncated: false, fallback: 9) == "5")
        #expect(RemoteChangesRules.badge(loaded: nil, truncated: true, fallback: 9) == "9")
        #expect(RemoteChangesRules.badge(loaded: nil, truncated: false, fallback: 0) == nil)
    }

    @Test func groupedSplitsByDirectorySortedByPath() {
        func f(_ p: String) -> RemoteChangedFile {
            RemoteChangedFile(path: p, status: "M", add: 0, del: 0, conflict: nil, renameFrom: nil)
        }
        let groups = RemoteChangesRules.grouped([f("src/b.swift"), f("z.md"), f("src/a.swift"), f("a/c.swift")])
        #expect(groups.map(\.directory) == ["", "a", "src"])
        #expect(groups.map { $0.files.map(\.path) } == [["z.md"], ["a/c.swift"], ["src/a.swift", "src/b.swift"]])
    }

    @Test(arguments: [
        (RemoteFileAccessReason.binary, nil, nil, "Binary file — not shown."),
        (.tooLarge, nil, 2048, "File is 2 KB — too large to view."),
        (.tooLarge, nil, nil, "File is too large to view."),
        (.pathRejected, nil, nil, "That path is outside this worktree."),
        (.notFound, nil, nil, "File not found."),
        (.worktreeUnavailable, nil, nil, "This session's worktree is unavailable."),
        (.sessionUnknown, nil, nil, "This session is no longer open on the host."),
        (.gitFailed, nil, nil, "Could not read this file."),
        (.unknown, "boom", nil, "boom"),
    ] as [(RemoteFileAccessReason, String?, Int?, String)])
    func accessMessageTexts(reason: RemoteFileAccessReason, message: String?, size: Int?, expected: String) {
        #expect(RemoteChangesRules.accessMessage(reason, message: message, byteSize: size) == expected)
    }
}
