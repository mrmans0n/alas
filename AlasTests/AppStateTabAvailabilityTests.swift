import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateTabAvailabilityTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-availability-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func hasActiveEditorTabFalseWhenNoWorktreeSelected() {
        let state = AppState()
        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseWhenNoActiveTab() async throws {
        let repo = try await makeRepo(name: "no-tab")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        #expect(state.activeTab == nil)
        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabTrueForEditor() async throws {
        let repo = try await makeRepo(name: "editor")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendEditor(worktreeId: trees[0].id, title: "a.txt", relativePath: "a.txt")

        #expect(state.hasActiveEditorTab)
    }

    @Test func hasActiveCodeEditorTabTrueForCodeEditor() async throws {
        let repo = try await makeRepo(name: "code-editor")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendEditor(worktreeId: trees[0].id, title: "a.txt", relativePath: "a.txt")

        #expect(state.hasActiveCodeEditorTab)
    }

    @Test func hasActiveCodeEditorTabFalseForMarkdownEditor() async throws {
        let repo = try await makeRepo(name: "markdown-editor")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendEditor(worktreeId: trees[0].id, title: "README.md", relativePath: "README.md")

        #expect(state.hasActiveEditorTab)
        #expect(!state.hasActiveCodeEditorTab)
    }

    @Test func hasActiveCodeEditorTabFalseForStandaloneMermaidPreview() async throws {
        let repo = try await makeRepo(name: "mermaid-preview")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendEditor(
            worktreeId: trees[0].id,
            title: "architecture.mmd",
            relativePath: "architecture.mmd"
        )

        #expect(state.hasActiveEditorTab)
        #expect(!state.hasActiveCodeEditorTab)
    }

    @Test func openStashDiffTabDoesNotReuseTabForDifferentStashSha() {
        let state = AppState()
        let worktree = Worktree(
            id: "wt-stash",
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date()
        )
        let file = GitStashFile(path: "Sources/App.swift", status: "M", add: 2, del: 1)
        let oldStash = GitStash(ref: "stash@{0}", subject: "old", relativeTime: "1 minute ago", sha: "old-sha")
        let newStash = GitStash(ref: "stash@{0}", subject: "new", relativeTime: "now", sha: "new-sha")

        state.openStashDiffTab(worktree: worktree, stash: oldStash, file: file)
        state.openStashDiffTab(worktree: worktree, stash: newStash, file: file)

        let tabs = state.tabs.tabs(forWorktree: worktree.id).compactMap { tab -> StashDiffTabState? in
            if case .stashDiff(let stashDiff) = tab { return stashDiff }
            return nil
        }
        #expect(tabs.map(\.stash.sha) == ["old-sha", "new-sha"])
    }

    @Test func openStashDiffTabKeepsTrackedAndUntrackedFilesWithTheSamePathDistinct() {
        let state = AppState()
        let worktreeId = "wt-stash-origin-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let worktree = Worktree(
            id: worktreeId,
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date()
        )
        let stash = GitStash(ref: "stash@{0}", subject: "same path", relativeTime: "now", sha: "stash-sha")
        let tracked = GitStashFile(path: "Assets/icon.png", status: "M", add: 1, del: 1)
        let untracked = GitStashFile(
            path: "Assets/icon.png",
            status: "A",
            add: 1,
            del: 0,
            isUntracked: true
        )

        #expect(tracked.id != untracked.id)
        state.openStashDiffTab(worktree: worktree, stash: stash, file: tracked)
        state.openStashDiffTab(worktree: worktree, stash: stash, file: untracked)

        let tabs = state.tabs.tabs(forWorktree: worktree.id).compactMap { tab -> StashDiffTabState? in
            if case .stashDiff(let stashDiff) = tab { return stashDiff }
            return nil
        }
        #expect(tabs.count == 2)
        #expect(tabs.map(\.file.isUntracked) == [false, true])
        if tabs.count == 2 {
            #expect(tabs[0].id != tabs[1].id)
        }
    }

    @Test func hasActiveCodeEditorTabFalseForExternalMarkdownEditor() async throws {
        let repo = try await makeRepo(name: "external-markdown-editor")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.openExternalEditor(
            worktreeId: trees[0].id,
            absoluteURL: repo.appendingPathComponent("../README.md").standardizedFileURL,
            revealLine: nil,
            revealCharacter: nil,
            originatingRelativePath: nil
        )

        #expect(state.hasActiveEditorTab)
        #expect(!state.hasActiveCodeEditorTab)
    }

    @Test func hasActiveEditorTabFalseForTerminal() async throws {
        let repo = try await makeRepo(name: "terminal")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendTerminal(worktreeId: trees[0].id, title: "main", sessionId: "s1")

        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseForDiff() async throws {
        let repo = try await makeRepo(name: "diff")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendDiff(worktreeId: trees[0].id, title: "a.txt", relativePath: "a.txt")

        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseForCommit() async throws {
        let repo = try await makeRepo(name: "commit")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendCommit(worktreeId: trees[0].id, sha: "abc", title: "abc msg")

        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseForImagePreview() async throws {
        let repo = try await makeRepo(name: "image")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.openImagePreview(worktreeId: trees[0].id, relativePath: "logo.png")

        #expect(!state.hasActiveEditorTab)
    }

    @Test func openFileWithRevealBypassesImagePreviewForSearchableSvg() async throws {
        let repo = try await makeRepo(name: "svg-reveal")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        state.openFile(relativePath: "Assets/icon.svg", worktreeId: trees[0].id)
        if case .imagePreview = state.activeTab {
            // Expected path for normal image opens.
        } else {
            Issue.record("expected image preview tab")
        }

        state.openFile(
            relativePath: "Assets/icon.svg",
            worktreeId: trees[0].id,
            revealLine: 4,
            revealCharacter: 2
        )

        if case .editor(let tab) = state.activeTab {
            #expect(tab.relativePath == "Assets/icon.svg")
            #expect(tab.revealLine == 4)
            #expect(tab.revealCharacter == 2)
        } else {
            Issue.record("expected editor tab")
        }
    }

    @Test func openFileWithRevealKeepsBinaryImagesInPreview() async throws {
        let repo = try await makeRepo(name: "binary-image-reveal")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        state.openFile(
            relativePath: "Assets/logo.png",
            worktreeId: trees[0].id,
            revealLine: 12,
            revealCharacter: 4
        )

        if case .imagePreview(let tab) = state.activeTab {
            #expect(tab.relativePath == "Assets/logo.png")
        } else {
            Issue.record("expected image preview tab")
        }
    }

    @Test func hasAnyDirtyEditorTabFalseWhenEmpty() {
        let state = AppState()
        #expect(!state.hasAnyDirtyEditorTab)
    }

    @Test func hasAnyDirtyEditorTabTrueWhenBufferDirty() async throws {
        let repo = try await makeRepo(name: "dirty")
        defer { try? FileManager.default.removeItem(at: repo) }

        try "hello\n".write(
            to: repo.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        let tab = state.tabs.appendEditor(
            worktreeId: trees[0].id, title: "a.txt", relativePath: "a.txt"
        )
        let buffer = state.tabs.buffer(
            worktreeId: trees[0].id,
            tabId: tab.id,
            worktreeRoot: trees[0].path,
            relativePath: "a.txt"
        )
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")

        #expect(state.hasAnyDirtyEditorTab)
    }

    @Test func hasAnyDirtyEditorTabTrueEvenWhenActiveTabIsTerminal() async throws {
        let repo = try await makeRepo(name: "dirty-terminal")
        defer { try? FileManager.default.removeItem(at: repo) }

        try "hello\n".write(
            to: repo.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        let editorTab = state.tabs.appendEditor(
            worktreeId: trees[0].id, title: "a.txt", relativePath: "a.txt"
        )
        let buffer = state.tabs.buffer(
            worktreeId: trees[0].id,
            tabId: editorTab.id,
            worktreeRoot: trees[0].path,
            relativePath: "a.txt"
        )
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        _ = state.tabs.appendTerminal(worktreeId: trees[0].id, title: "main", sessionId: "s1")

        #expect(!state.hasActiveEditorTab)
        #expect(state.hasAnyDirtyEditorTab)
    }
}
