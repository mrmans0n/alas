import Foundation
import CoreServices

final class WorktreeWatcher {
    private final class StreamContext {
        weak var watcher: WorktreeWatcher?

        init(watcher: WorktreeWatcher) {
            self.watcher = watcher
        }
    }

    var onChange: (() -> Void)?
    private let path: URL
    private var stream: FSEventStreamRef?
    private var gitDirStream: FSEventStreamRef?
    private var isRunning = false
    private let eventQueueKey = DispatchSpecificKey<Void>()
    private let eventQueue = DispatchQueue(label: "io.nlopez.alas.worktree-watcher", qos: .utility)
    // `maxWait: 2.0` guarantees a refresh fires within 2s of the first event
    // in a burst, even when something (agent, build, LSP) keeps poking faster
    // than the 0.5s trailing window. Without the ceiling the trailing timer
    // can be cancelled-and-rescheduled indefinitely, leaving the changes
    // pane stuck on stale data.
    private let debouncer = DebounceTimer(interval: 0.5, maxWait: 2.0)

    init(path: URL) {
        self.path = path
        self.eventQueue.setSpecific(key: eventQueueKey, value: ())
        self.debouncer.onFire = { [weak self] in
            self?.onChange?()
        }
    }

    func start() {
        stop()
        isRunning = true
        stream = makeStream(paths: [path.path], includeFileEvents: true)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, eventQueue)
            FSEventStreamStart(stream)
        }
        // Resolve git-dir asynchronously so a slow or hung git invocation
        // never blocks watcher startup. Worktree-file events still flow.
        Task { [weak self] in
            guard let self else { return }
            guard let gitDir = await Self.resolveGitDir(at: self.path) else { return }
            await MainActor.run {
                guard self.stream != nil else { return }  // already stopped
                self.gitDirStream = self.makeStream(paths: [gitDir.path], includeFileEvents: true)
                if let s = self.gitDirStream {
                    FSEventStreamSetDispatchQueue(s, self.eventQueue)
                    FSEventStreamStart(s)
                }
            }
        }
    }

    func stop() {
        isRunning = false
        if let stream {
            self.stream = nil
            releaseStream(stream)
        }
        if let gitDirStream {
            self.gitDirStream = nil
            releaseStream(gitDirStream)
        }
        debouncer.cancel()
    }

    deinit { stop() }

    private func releaseStream(_ stream: FSEventStreamRef) {
        let release = {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if DispatchQueue.getSpecific(key: eventQueueKey) != nil {
            release()
        } else {
            eventQueue.sync(execute: release)
        }
    }

    private func makeStream(paths: [String], includeFileEvents: Bool) -> FSEventStreamRef? {
        let streamContext = StreamContext(watcher: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(streamContext).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<StreamContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, ctx, numEvents, eventPaths, _, _ in
            guard let ctx else { return }
            let streamContext = Unmanaged<StreamContext>.fromOpaque(ctx).takeUnretainedValue()
            guard let watcher = streamContext.watcher else { return }

            // With `kFSEventStreamCreateFlagUseCFTypes` set on the stream,
            // `eventPaths` is a `CFArrayRef` of `CFStringRef`. Bridge to
            // Swift `[String]`, then ask the filter whether anything in this
            // batch is worth a refresh. If the bridge ever fails (unexpected
            // — would only happen if the flag was lost), fall back to the
            // previous always-poke behavior so we never silently drop real
            // change events.
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let paths = cfArray as? [String], paths.count == numEvents else {
                watcher.pokeDebouncerFromStream()
                return
            }

            if WorktreeWatcher.shouldRefresh(forEventPaths: paths) {
                watcher.pokeDebouncerFromStream()
            }
        }
        var flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )
        if includeFileEvents {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            Unmanaged<StreamContext>.fromOpaque(context.info!).release()
            return nil
        }
        return stream
    }

    private func pokeDebouncerFromStream() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.debouncer.poke()
        }
    }

    /// Returns `true` iff at least one event path represents a change we want
    /// to react to. Transient git-write files are filtered out: lockfiles
    /// appear when another git process is mid-write, and `FETCH_HEAD` is
    /// updated by fetches that the sync-status probe itself can trigger.
    /// Reacting would schedule redundant refreshes during the user's
    /// operation. Project lockfiles outside `.git/` (e.g. `Cargo.lock`,
    /// `package-lock.json`) are real changes and DO trigger a refresh.
    static func shouldRefresh(forEventPaths paths: [String]) -> Bool {
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
