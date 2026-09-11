import Testing
import Foundation
@testable import Alas

/// A temporary git repository, its `AppState`-registered project, and the
/// worktrees git reports for it — ready to drive batch-cleanup tests without
/// each test standing up its own repo.
struct WorktreeCleanupFixture {
    let state: AppState
    let project: ProjectConfig
    let worktrees: [Worktree]
    let repoPath: URL
}

/// Builds a real temporary git repository with `worktreeCount` worktrees and
/// an `AppState` with a project pointed at it. `sortedWorktrees` always pins
/// the main worktree at position 0, so `fixture.worktrees[0]` is always main
/// and the rest are ordinary feature worktrees named `feature-1`, `feature-2`, ….
///
/// Modeled on `WorktreeServiceTests.makeRepo` (repo + sibling worktrees) and
/// `AppStateCleanupTests` (an `AppState` with a project registered against a
/// real temporary repo).
@MainActor
func makeCleanupFixture(worktreeCount: Int) async throws -> WorktreeCleanupFixture {
    precondition(worktreeCount >= 1, "a fixture needs at least the main worktree")

    let repoPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("alas-cleanup-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
    _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repoPath)
    _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repoPath)

    let root = repoPath.deletingLastPathComponent()
    for index in 1..<worktreeCount {
        let branch = "feature-\(index)"
        _ = try await Process.git(["branch", branch, "main"], cwd: repoPath)
        let destination = root.appendingPathComponent("\(repoPath.lastPathComponent)-wt\(index)")
        _ = try await Process.git(["worktree", "add", "-q", destination.path, branch], cwd: repoPath)
        WorktreeRegistrationLookup.shared.register(worktreePath: destination, repoPath: repoPath)
    }

    let state = AppState()
    let project = try await state.projectsManager.addProject(
        path: repoPath,
        displayName: "cleanup-fixture",
        color: "#5fb7c4"
    )
    try await state.projectsManager.refreshWorktrees(projectId: project.id)
    let worktrees = state.projectsManager.worktrees(projectId: project.id)

    return WorktreeCleanupFixture(state: state, project: project, worktrees: worktrees, repoPath: repoPath)
}

/// Thread-safe lookup from a worktree's on-disk path to the repository that
/// registered it with git, so test helpers can still find the repository
/// after the worktree's own directory (and the `.git` file inside it) has
/// been deleted out from under it.
///
/// Keyed by a normalized path *string*, not `URL`: the destination URL built
/// at registration time (via `appendingPathComponent`, before symlinks like
/// `/var` → `/private/var` are resolved) and the path `WorktreeService`
/// reports back (parsed from `git worktree list --porcelain`, which git
/// reports already resolved) otherwise disagree even when they name the same
/// file. Resolving only the *parent* directory keeps this correct even after
/// the worktree's own leaf directory has been deleted, when the leaf itself
/// can no longer be resolved.
private final class WorktreeRegistrationLookup: @unchecked Sendable {
    static let shared = WorktreeRegistrationLookup()

    private let lock = NSLock()
    private var repoPathsByWorktreePath: [String: URL] = [:]

    private func normalizedKey(for worktreePath: URL) -> String {
        worktreePath.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(worktreePath.lastPathComponent)
            .path
    }

    func register(worktreePath: URL, repoPath: URL) {
        lock.lock()
        defer { lock.unlock() }
        repoPathsByWorktreePath[normalizedKey(for: worktreePath)] = repoPath
    }

    func repoPath(forWorktreePath worktreePath: URL) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return repoPathsByWorktreePath[normalizedKey(for: worktreePath)]
    }
}

extension Process {
    /// Breaks worktree removal for `worktree` at the git-administrative
    /// level, independent of whether the worktree's own directory still
    /// exists on disk (deleting its directory alone leaves git able to
    /// prune it silently — `git worktree remove` treats that as success).
    /// Repoints the main repository's `worktrees/<name>/gitdir` registration
    /// at a path that does not exist, so `git worktree remove` fails
    /// validation instead.
    static func corruptWorktreeRegistration(_ worktree: Worktree) throws {
        guard let repoPath = WorktreeRegistrationLookup.shared.repoPath(forWorktreePath: worktree.path) else {
            throw ProcessError.launchFailed("no repository registered for \(worktree.path.path)")
        }
        let adminDir = repoPath
            .appendingPathComponent(".git")
            .appendingPathComponent("worktrees")
            .appendingPathComponent(worktree.path.lastPathComponent)
        let gitdirFile = adminDir.appendingPathComponent("gitdir")
        try "/nonexistent/\(UUID().uuidString)/.git\n".write(
            to: gitdirFile,
            atomically: true,
            encoding: .utf8
        )
    }
}
