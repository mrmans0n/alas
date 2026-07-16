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

    @Test func resolvesAbsolutePathTargets() {
        let worktrees = [
            Self.worktree(branch: "main", path: "/repo/main"),
            Self.worktree(branch: "feature-x", path: "/repo/feature-x"),
        ]
        #expect(AlasCLIWorktreeResolver.resolve(target: "/repo/feature-x", worktrees: worktrees)
            == .matched(worktrees[1]))
        #expect(AlasCLIWorktreeResolver.resolve(target: "/repo/nope", worktrees: worktrees)
            == .missing("/repo/nope"))
    }

    @Test func resolvesSymlinkedTargetAgainstRealWorktreeRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-resolver-symlink-target-\(UUID().uuidString)")
        let realRoot = base.appendingPathComponent("real")
        let linkRoot = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        let worktree = Self.worktree(branch: "main", path: realRoot.path)
        let result = AlasCLIWorktreeResolver.resolve(target: linkRoot.path, worktrees: [worktree])
        #expect(result == .matched(worktree))
    }

    @Test func resolvesRealPathTargetAgainstSymlinkedWorktreeRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-resolver-symlink-worktree-\(UUID().uuidString)")
        let realRoot = base.appendingPathComponent("real")
        let linkRoot = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        let worktree = Self.worktree(branch: "main", path: linkRoot.path)
        let result = AlasCLIWorktreeResolver.resolve(
            target: realRoot.resolvingSymlinksInPath().path,
            worktrees: [worktree]
        )
        #expect(result == .matched(worktree))
    }

    @Test func nonexistentAbsolutePathWithNoSymlinkStillMissesWithoutCrashing() {
        let worktrees = [Self.worktree(branch: "main", path: "/repo/main")]
        let target = "/tmp/alas-resolver-does-not-exist-\(UUID().uuidString)/nested/nope"
        let result = AlasCLIWorktreeResolver.resolve(target: target, worktrees: worktrees)
        #expect(result == .missing(target))
    }

    @Test func resolvesNestedSubdirectoryToContainingWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-resolver-containing-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let worktree = Self.worktree(branch: "main", path: root.path)
        let result = AlasCLIWorktreeResolver.resolve(target: nested.path, worktrees: [worktree])
        #expect(result == .matched(worktree))
    }

    @Test func resolvesDeeplyNestedSubdirectoryToContainingWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-resolver-containing-deep-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/Deep/Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let worktree = Self.worktree(branch: "main", path: root.path)
        let result = AlasCLIWorktreeResolver.resolve(target: nested.path, worktrees: [worktree])
        #expect(result == .matched(worktree))
    }

    @Test func nestedWorktreePrefersDeepestContainingRoot() throws {
        let outerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-resolver-nested-outer-\(UUID().uuidString)")
        let innerRoot = outerRoot.appendingPathComponent("nested-worktree")
        let target = innerRoot.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerRoot) }

        let outer = Self.worktree(branch: "outer", path: outerRoot.path)
        let inner = Self.worktree(branch: "inner", path: innerRoot.path)
        let result = AlasCLIWorktreeResolver.resolve(target: target.path, worktrees: [outer, inner])
        #expect(result == .matched(inner))
    }

    @Test func pathOutsideAllWorktreesStillMisses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-resolver-worktree-root-\(UUID().uuidString)")
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-resolver-unrelated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: unrelated)
        }

        let worktree = Self.worktree(branch: "main", path: root.path)
        let result = AlasCLIWorktreeResolver.resolve(target: unrelated.path, worktrees: [worktree])
        #expect(result == .missing(unrelated.path))
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
