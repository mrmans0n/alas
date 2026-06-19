import Foundation
import Testing
@testable import Alas

@MainActor
struct AlasCLIWorktreeResolverTests {
    @Test func rowsMarkCurrentWorktree() {
        let current = Self.worktree(branch: "main", path: "/tmp/repo")
        let other = Self.worktree(branch: "feature/review", path: "/tmp/repo-feature")
        let rows = AlasCLIWorktreeResolver.rows(worktrees: [current, other], currentWorktreeId: current.id)
        #expect(rows == ["* main              /tmp/repo", "  feature/review    /tmp/repo-feature"])
    }

    @Test func exactBranchMatchWins() {
        let main = Self.worktree(branch: "main", path: "/tmp/main")
        let match = Self.worktree(branch: "feature/review", path: "/tmp/review")
        let result = AlasCLIWorktreeResolver.resolve(target: "feature/review", worktrees: [main, match])
        #expect(result == .matched(match))
    }

    @Test func exactNameMatchWinsBeforeBasename() {
        let nameMatch = Self.worktree(name: "review", branch: "feature/review", path: "/tmp/name-match")
        let basenameMatch = Self.worktree(branch: "other", path: "/tmp/review")
        let result = AlasCLIWorktreeResolver.resolve(target: "review", worktrees: [basenameMatch, nameMatch])
        #expect(result == .matched(nameMatch))
    }

    @Test func basenameMatchWorks() {
        let match = Self.worktree(branch: "other", path: "/tmp/repo-feature")
        let result = AlasCLIWorktreeResolver.resolve(target: "repo-feature", worktrees: [match])
        #expect(result == .matched(match))
    }

    @Test func ambiguousPrefixListsCandidates() {
        let b = Self.worktree(branch: "feat/b", path: "/tmp/b")
        let a = Self.worktree(branch: "feat/a", path: "/tmp/a")
        let result = AlasCLIWorktreeResolver.resolve(target: "feat", worktrees: [b, a])
        #expect(result == .ambiguous(["feat/a", "feat/b"]))
    }

    @Test func ambiguousDuplicateLabelsIncludePaths() {
        let b = Self.worktree(branch: "main", path: "/tmp/repo-b")
        let a = Self.worktree(branch: "main", path: "/tmp/repo-a")
        let result = AlasCLIWorktreeResolver.resolve(target: "main", worktrees: [b, a])
        #expect(result == .ambiguous(["main (/tmp/repo-a)", "main (/tmp/repo-b)"]))
    }

    @Test func emptyTargetIsMissing() {
        let result = AlasCLIWorktreeResolver.resolve(target: "   ", worktrees: [])
        #expect(result == .missing(""))
    }

    private static func worktree(name: String? = nil, branch: String, path: String) -> Worktree {
        Worktree(
            id: Worktree.makeId(path: URL(fileURLWithPath: path)),
            projectId: "project",
            name: name ?? branch,
            branch: branch,
            path: URL(fileURLWithPath: path),
            status: .clean,
            lastActivity: Date()
        )
    }
}
