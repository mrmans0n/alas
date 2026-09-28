import Foundation
import Testing
@testable import Alas

struct NativePeerWorkspaceTests {
    private func changed(_ path: String, add: Int = 1) -> RemoteChangedFile {
        .init(path: path, status: "M", add: add, del: 0, conflict: nil, renameFrom: nil)
    }

    private func dir(_ path: String) -> RemoteFileNode {
        .init(name: (path as NSString).lastPathComponent, path: path, kind: "dir",
              badge: nil, childrenState: "notLoaded", isSubmodule: false)
    }

    private func file(_ path: String) -> RemoteFileNode {
        .init(name: (path as NSString).lastPathComponent, path: path, kind: "file",
              badge: "M", childrenState: "loaded", isSubmodule: false)
    }

    @Test func changeListFillsSectionsAndAFailedRefreshKeepsIt() {
        var workspace = NativePeerWorkspace()
        workspace.beginChangesLoad()
        #expect(workspace.changes == .loading)

        let applied = workspace.apply(.changeList(
            sessionId: "B:s", comparisonRef: "origin/main", metricsAvailable: true,
            files: [changed("a.swift"), changed("b.swift")], staged: [changed("a.swift")],
            unstaged: [changed("b.swift")], commits: [], truncated: false))
        #expect(applied)
        guard case .loaded(let changes) = workspace.changes else {
            Issue.record("expected loaded changes")
            return
        }
        #expect(changes.comparisonRef == "origin/main")
        #expect(changes.branchFiles.map(\.path) == ["a.swift", "b.swift"])
        #expect(changes.staged.map(\.stage) == [.staged])
        #expect(changes.unstaged.map(\.stage) == [.unstaged])

        workspace.beginChangesLoad()
        _ = workspace.apply(.changeListFailed(sessionId: "B:s", reason: .gitFailed, message: nil))
        #expect(workspace.changes == .loaded(changes))
    }

    @Test func lateReplyForAnEarlierDocumentIsIgnored() {
        var workspace = NativePeerWorkspace()
        workspace.beginDocument(.file(path: "a.swift"))
        workspace.beginDocument(.diff(path: "b.swift", stage: .staged))

        _ = workspace.apply(.fileContents(sessionId: "B:s", path: "a.swift", text: "old", truncated: false))
        #expect(workspace.documentContent == .loading)

        let hunk = RemoteDiffHunk(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [
            RemoteDiffLine(kind: "delete", text: "x", oldNumber: 1, newNumber: nil),
            RemoteDiffLine(kind: "add", text: "y", oldNumber: nil, newNumber: 1),
        ])
        // Same path, other stage: still not the open document.
        _ = workspace.apply(.fileDiffResult(sessionId: "B:s", path: "b.swift", stage: "unstaged",
                                            hunks: [hunk], truncated: false))
        #expect(workspace.documentContent == .loading)

        _ = workspace.apply(.fileDiffResult(sessionId: "B:s", path: "b.swift", stage: "staged",
                                            hunks: [hunk], truncated: false))
        guard case .loaded(.diff(let diff, truncated: false)) = workspace.documentContent else {
            Issue.record("expected a loaded diff")
            return
        }
        #expect(diff.hunks.first?.lines.map(\.kind) == [.delete, .add])
    }

    @Test func childListingMergesUnderItsDirectoryOnce() {
        var workspace = NativePeerWorkspace()
        let rootLoadStarted = workspace.beginRootLoad()
        #expect(rootLoadStarted)
        let rootLoadStartedAgain = workspace.beginRootLoad()
        #expect(!rootLoadStartedAgain)
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        #expect(workspace.shouldLoadChildren(path: "src", childrenState: .notLoaded))

        let childLoadStarted = workspace.beginChildrenLoad(path: "src")
        #expect(childLoadStarted)
        let childLoadStartedAgain = workspace.beginChildrenLoad(path: "src")
        #expect(!childLoadStartedAgain)
        let revision = workspace.fileTreeRevision
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: "src", nodes: [file("src/main.swift")], truncated: false))

        guard case .loaded(let nodes) = workspace.fileTree else {
            Issue.record("expected a loaded tree")
            return
        }
        #expect(nodes.first?.children?.map(\.path) == ["src/main.swift"])
        #expect(nodes.first?.childrenState == .loaded)
        #expect(workspace.fileTreeRevision != revision)
        #expect(!workspace.shouldLoadChildren(path: "src", childrenState: .loaded))
    }

    @Test func offlineFailsPendingLoadsButKeepsLoadedContent() {
        var workspace = NativePeerWorkspace()
        _ = workspace.beginRootLoad()
        _ = workspace.apply(.fileTree(sessionId: "B:s", path: nil, nodes: [dir("src")], truncated: false))
        workspace.beginChangesLoad()
        workspace.beginDocument(.file(path: "README.md"))
        _ = workspace.beginChildrenLoad(path: "src")

        workspace.markUnavailable()

        #expect(workspace.changes == .failed(NativePeerWorkspace.offlineMessage))
        #expect(workspace.documentContent == .failed(NativePeerWorkspace.offlineMessage))
        guard case .loaded = workspace.fileTree else {
            Issue.record("loaded tree should survive")
            return
        }
        // The pending child load is released so a later reconnect can retry it.
        let retried = workspace.beginChildrenLoad(path: "src")
        #expect(retried)
    }
}
