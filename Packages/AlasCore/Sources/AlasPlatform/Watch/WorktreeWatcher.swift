import Foundation
import AlasFoundation
import AlasModel

/// Main-actor confined. Every stored property is created, read, and torn
/// down on the main actor (`RightPaneState`, itself `@MainActor`, is the
/// only owner). The two entry points that genuinely arrive off-main — the
/// file event stream's handler and `DebounceTimer`'s work item — are `nonisolated`
/// and hop explicitly.
@MainActor
public final class WorktreeWatcher {
    public var onChange: (() -> Void)?
    private let path: URL
    private let watchesGitDir: Bool
    private var stream: FileEventStream?
    private var gitDirStream: FileEventStream?
    private var isRunning = false
    private let eventQueue = DispatchQueue(label: "io.nlopez.alas.worktree-watcher", qos: .utility)
    // `maxWait: 2.0` guarantees a refresh fires within 2s of the first event
    // in a burst, even when something (agent, build, LSP) keeps poking faster
    // than the 0.5s trailing window. Without the ceiling the trailing timer
    // can be cancelled-and-rescheduled indefinitely, leaving the changes
    // pane stuck on stale data.
    private let debouncer = DebounceTimer(interval: 0.5, maxWait: 2.0)

    public init(path: URL, watchesGitDir: Bool = true) {
        self.path = path
        self.watchesGitDir = watchesGitDir
        self.debouncer.onFire = { [weak self] in
            self?.onChange?()
        }
    }

    public func start() {
        stop()
        isRunning = true
        stream = makeStream(paths: [path.path])
        // Resolve git-dir asynchronously so a slow or hung git invocation
        // never blocks watcher startup. Worktree-file events still flow.
        // `Task` inherits the main actor here, so the continuation after the
        // await is already back on main — no explicit `MainActor.run` needed.
        guard watchesGitDir else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let gitDir = await Self.resolveGitDir(at: self.path) else { return }
            guard self.stream != nil else { return }  // already stopped
            self.gitDirStream = self.makeStream(paths: [gitDir.path])
        }
    }

    public func stop() {
        isRunning = false
        stream?.stop()
        stream = nil
        gitDirStream?.stop()
        gitDirStream = nil
        debouncer.cancel()
    }

    isolated deinit { stop() }

    private func makeStream(paths: [String]) -> FileEventStream? {
        FileEventStream(paths: paths, fileEvents: true, queue: eventQueue) { [weak self] paths in
            // Unreadable paths fall back to a refresh, so no real change is dropped.
            if paths.map(WorktreeWatcher.shouldRefresh(forEventPaths:)) ?? true {
                self?.pokeDebouncerFromStream()
            }
        }
    }

    /// Called from the file event stream, which runs on `eventQueue`.
    /// `DispatchQueue.main` is the main actor's executor, so by the time the
    /// block runs the assumption below always holds.
    nonisolated private func pokeDebouncerFromStream() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.debouncer.poke()
            }
        }
    }

    /// Returns `true` iff at least one event path represents a change we want
    /// to react to. Transient git-write files are filtered out: lockfiles
    /// appear when another git process is mid-write, and `FETCH_HEAD` is
    /// updated by fetches that the sync-status probe itself can trigger.
    /// Reacting would schedule redundant refreshes during the user's
    /// operation. Project lockfiles outside `.git/` (e.g. `Cargo.lock`,
    /// `package-lock.json`) are real changes and DO trigger a refresh.
    public nonisolated static func shouldRefresh(forEventPaths paths: [String]) -> Bool {
        for path in paths {
            if path.contains("/.git/"),
               path.hasSuffix(".lock") || path.hasSuffix("/FETCH_HEAD") {
                continue
            }
            return true
        }
        return false
    }

    /// Resolves the real git-dir for a worktree. For a normal repo this is
    /// `<worktree>/.git`; for a linked worktree it points into
    /// `<repo>/.git/worktrees/<name>/` instead. Returns nil if `git
    /// rev-parse` fails (not a repo, etc.).
    nonisolated private static func resolveGitDir(at worktree: URL) async -> URL? {
        guard let result = try? await Process.git(
            ["rev-parse", "--absolute-git-dir"],
            cwd: worktree
        ), result.exitCode == 0 else {
            return nil
        }
        let dir = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir)
    }
}
