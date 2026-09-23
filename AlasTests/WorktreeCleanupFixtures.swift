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
    let temporaryRoot: URL
    let registeredWorktreePaths: [URL]
    let attentionStoreURL: URL
    let persistence: WorktreeCleanupMemoryStore

    var persistenceReadPaths: Set<String> {
        persistence.readPaths
    }

    func removeFiles() throws {
        for path in registeredWorktreePaths {
            WorktreeRegistrationLookup.shared.unregister(worktreePath: path)
        }
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func cleanUpAfterTest() {
        do {
            try removeFiles()
        } catch {
            Issue.record("Failed to remove cleanup fixture at \(temporaryRoot.path): \(error.localizedDescription)")
        }
    }
}

/// Builds a real temporary git repository with `worktreeCount` worktrees and
/// an `AppState` with a project pointed at it. `sortedWorktrees` always pins
/// the main worktree at position 0, so `fixture.worktrees[0]` is always main
/// and the rest are ordinary feature worktrees named `feature-1`, `feature-2`, ….
///
/// `worktreeCleanupLauncher` lets a test observe the point inside a deletion
/// that runs after the removal succeeded but before the refresh that
/// reconciles the removed row away.
///
/// Modeled on `WorktreeServiceTests.makeRepo` (repo + sibling worktrees) and
/// `AppStateCleanupTests` (an `AppState` with a project registered against a
/// real temporary repo).
@MainActor
func makeCleanupFixture(
    worktreeCount: Int,
    worktreeCleanupLauncher: @escaping AppState.WorktreeCleanupLauncher = {
        try WorktreeTrashCleaner.launch($0)
    }
) async throws -> WorktreeCleanupFixture {
    precondition(worktreeCount >= 1, "a fixture needs at least the main worktree")

    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("alas-cleanup-fixture-\(UUID().uuidString)")
    let repoPath = temporaryRoot.appendingPathComponent("repo")
    var registeredWorktreePaths: [URL] = []
    let persistence = WorktreeCleanupMemoryStore()
    let attentionStoreURL = temporaryRoot.appendingPathComponent("attention-events.json")
    do {
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repoPath)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repoPath)

        for index in 1..<worktreeCount {
            let branch = "feature-\(index)"
            _ = try await Process.git(["branch", branch, "main"], cwd: repoPath)
            let destination = temporaryRoot.appendingPathComponent("worktree-\(index)")
            _ = try await Process.git(["worktree", "add", "-q", destination.path, branch], cwd: repoPath)
            WorktreeRegistrationLookup.shared.register(worktreePath: destination, repoPath: repoPath)
            registeredWorktreePaths.append(destination)
        }

        let state = AppState(
            store: persistence,
            worktreeCleanupLauncher: worktreeCleanupLauncher,
            attentionStore: AttentionStore(url: attentionStoreURL, persistence: persistence)
        )
        let project = try await state.projectsManager.addProject(
            path: repoPath,
            displayName: "cleanup-fixture",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktrees = state.projectsManager.worktrees(projectId: project.id)

        return WorktreeCleanupFixture(
            state: state,
            project: project,
            worktrees: worktrees,
            repoPath: repoPath,
            temporaryRoot: temporaryRoot,
            registeredWorktreePaths: registeredWorktreePaths,
            attentionStoreURL: attentionStoreURL,
            persistence: persistence
        )
    } catch {
        for path in registeredWorktreePaths {
            WorktreeRegistrationLookup.shared.unregister(worktreePath: path)
        }
        try? FileManager.default.removeItem(at: temporaryRoot)
        throw error
    }
}

final class WorktreeCleanupMemoryStore: PersistenceStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    fileprivate(set) var readPaths: Set<String> = []
    /// Last `ProjectsFile` written, so tests can assert what a code path
    /// actually persisted (not just what it left in memory).
    private(set) var writtenProjectsFile: ProjectsFile?

    func write<T: Encodable>(_ value: T, to _: URL) throws {
        guard let projects = value as? ProjectsFile else { return }
        lock.lock()
        defer { lock.unlock() }
        writtenProjectsFile = projects
    }

    func readIfExists<T: Decodable>(_: T.Type, from url: URL) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        readPaths.insert(url.path)
        return nil
    }
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

    func unregister(worktreePath: URL) {
        lock.lock()
        defer { lock.unlock() }
        repoPathsByWorktreePath.removeValue(forKey: normalizedKey(for: worktreePath))
    }
}

extension Process {
    /// Recreates a git worktree registration for a checkout at `destination` —
    /// the inverse of `corruptWorktreeRegistration`, and the only way a test
    /// can put a checkout at a path *inside* the window between a successful
    /// removal and the refresh that reconciles the removed row away
    /// (`worktreeCleanupLauncher`).
    ///
    /// Written as files rather than `git worktree add` because that window is
    /// the whole point of the test: a child process started there, with the
    /// runner capturing output, wedges the test invocation instead of failing a
    /// test. git discovers a checkout purely from its administrative files, so
    /// a copied registration (with `gitdir` repointed) is indistinguishable
    /// from a spawned one as far as `git worktree list` is concerned.
    ///
    /// `template` is a checkout the repository already lists — the fixture's
    /// `worktree-1` — whose administrative directory carries the index, refs,
    /// and `commondir` a live registration needs. The repository must already
    /// contain `branch`; the fixture branches its worktrees off `main` up
    /// front.
    static func registerWorktree(
        _ destination: URL,
        branch: String,
        repoPath: URL,
        template: URL
    ) throws {
        let worktreesDir = repoPath.appendingPathComponent(".git/worktrees")
        let templateAdmin = worktreesDir.appendingPathComponent(template.lastPathComponent)
        let adminDir = worktreesDir.appendingPathComponent(destination.lastPathComponent)
        if FileManager.default.fileExists(atPath: adminDir.path) {
            try FileManager.default.removeItem(at: adminDir)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: templateAdmin, to: adminDir)
        try "\(destination.appendingPathComponent(".git").path)\n".write(
            to: adminDir.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/\(branch)\n".write(
            to: adminDir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(adminDir.path)\n".write(
            to: destination.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
    }

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
