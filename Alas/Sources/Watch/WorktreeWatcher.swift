import Foundation
import CoreServices

final class WorktreeWatcher {
    var onChange: (() -> Void)?
    private let path: URL
    private var stream: FSEventStreamRef?
    private var gitDirStream: FSEventStreamRef?
    private let debouncer = DebounceTimer(interval: 0.5)

    init(path: URL) {
        self.path = path
        self.debouncer.onFire = { [weak self] in
            self?.onChange?()
        }
    }

    func start() {
        stop()
        stream = makeStream(paths: [path.path])
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        // Resolve git-dir asynchronously so a slow or hung git invocation
        // never blocks watcher startup. Worktree-file events still flow.
        Task { [weak self] in
            guard let self else { return }
            guard let gitDir = await Self.resolveGitDir(at: self.path) else { return }
            await MainActor.run {
                guard self.stream != nil else { return }  // already stopped
                self.gitDirStream = self.makeStream(paths: [gitDir.path])
                if let s = self.gitDirStream {
                    FSEventStreamSetDispatchQueue(s, .main)
                    FSEventStreamStart(s)
                }
            }
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if let gitDirStream {
            FSEventStreamStop(gitDirStream)
            FSEventStreamInvalidate(gitDirStream)
            FSEventStreamRelease(gitDirStream)
            self.gitDirStream = nil
        }
        debouncer.cancel()
    }

    deinit { stop() }

    private func makeStream(paths: [String]) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, ctx, numEvents, eventPaths, _, _ in
            guard let ctx else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(ctx).takeUnretainedValue()

            // With `kFSEventStreamCreateFlagUseCFTypes` set on the stream,
            // `eventPaths` is a `CFArrayRef` of `CFStringRef`. Bridge to
            // Swift `[String]`, then ask the filter whether anything in this
            // batch is worth a refresh. If the bridge ever fails (unexpected
            // — would only happen if the flag was lost), fall back to the
            // previous always-poke behavior so we never silently drop real
            // change events.
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let paths = cfArray as? [String], paths.count == numEvents else {
                watcher.debouncer.poke()
                return
            }

            if WorktreeWatcher.shouldRefresh(forEventPaths: paths) {
                watcher.debouncer.poke()
            }
        }
        return FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            )
        )
    }

    /// Returns `true` iff at least one event path represents a change we want
    /// to react to. Git lockfiles (`*.lock` inside any `.git/` directory) are
    /// filtered out: they appear when another git process is mid-write
    /// (commit, rebase, fetch); reacting would (a) trigger a redundant
    /// refresh during the user's operation and (b) historically caused
    /// `.git/index.lock` contention with terminal git. Project lockfiles
    /// outside `.git/` (e.g. `Cargo.lock`, `package-lock.json`) are real
    /// changes and DO trigger a refresh.
    static func shouldRefresh(forEventPaths paths: [String]) -> Bool {
        for path in paths {
            if path.hasSuffix(".lock") && path.contains("/.git/") {
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
    private static func resolveGitDir(at worktree: URL) async -> URL? {
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
