import Foundation
import CoreServices
import os

private final class ProjectGitWatcherStreamContext {
    weak var watcher: ProjectGitWatcher?
    let gitDir: URL
    let worktreeRoot: URL

    init(watcher: ProjectGitWatcher, gitDir: URL, worktreeRoot: URL) {
        self.watcher = watcher
        self.gitDir = gitDir
        self.worktreeRoot = worktreeRoot
    }
}

private struct ProjectGitWatcherStreamBatch {
    var headFiles: Set<URL> = []
    var sawRevision = false
    var sawTopology = false

    var hasChanges: Bool {
        !headFiles.isEmpty || sawRevision || sawTopology
    }
}

/// Per-project FSEvents watcher rooted at the project's resolved `.git`
/// directory. Splits events into a fast HEAD-only path (callback emits
/// `[worktreeRoot: branchLabel]` read directly from disk) and a slow
/// topology path (callback fires `onTopologyChanged` for the caller to
/// reconcile via `git worktree list`). See the design doc:
/// docs/superpowers/specs/2026-05-14-sidebar-auto-refresh-on-branch-change-design.md
@MainActor
final class ProjectGitWatcher {
    typealias GitInfo = (gitDir: URL, worktreeRoot: URL)

    nonisolated private static let eventQueueKey = DispatchSpecificKey<Void>()
    nonisolated private static let eventQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "io.nlopez.alas.project-git-watcher", qos: .utility)
        queue.setSpecific(key: eventQueueKey, value: ())
        return queue
    }()

    var onHeadChanged: (([URL: String]) -> Void)?
    var onRevisionChanged: (() -> Void)?
    var onTopologyChanged: (() -> Void)?

    private let repoPath: URL
    private let gitInfoResolver: (URL) async -> GitInfo?
    private let startStreamOverride: ((ProjectGitWatcher, URL) -> Void)?
    private var resolvedGitDir: URL?
    private var resolvedWorktreeRoot: URL?
    private var stream: FSEventStreamRef?
    private var isRunning = false
    private var startGeneration = 0
    private let headDebouncer: DebounceTimer
    private let topologyDebouncer: DebounceTimer
    private var pendingHeadFiles: Set<URL> = []
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "project-git-watcher")

    /// Production initializer: resolves git-dir asynchronously via
    /// `git rev-parse` after `start()` is called.
    convenience init(repoPath: URL) {
        self.init(
            repoPath: repoPath,
            resolvedGitDir: nil,
            resolvedWorktreeRoot: nil,
            headDebounceInterval: 0.1,
            headDebounceMaxWait: 0.5,
            topologyDebounceInterval: 0.5,
            topologyDebounceMaxWait: 2.0
        )
    }

    /// Test initializer: caller supplies the resolved git-dir (and worktree
    /// root) plus tighter debounce timings so tests don't sleep for seconds.
    /// When `resolvedGitDir` is non-nil, no `git` invocation happens — the
    /// watcher is ready to `processEvents` immediately.
    init(
        repoPath: URL,
        resolvedGitDir: URL?,
        resolvedWorktreeRoot: URL?,
        headDebounceInterval: TimeInterval,
        headDebounceMaxWait: TimeInterval,
        topologyDebounceInterval: TimeInterval,
        topologyDebounceMaxWait: TimeInterval,
        gitInfoResolver: @escaping (URL) async -> GitInfo? = ProjectGitWatcher.resolveGitInfo,
        startStreamOverride: ((ProjectGitWatcher, URL) -> Void)? = nil
    ) {
        self.repoPath = repoPath
        self.gitInfoResolver = gitInfoResolver
        self.startStreamOverride = startStreamOverride
        self.resolvedGitDir = resolvedGitDir
        self.resolvedWorktreeRoot = resolvedWorktreeRoot
        self.headDebouncer = DebounceTimer(
            interval: headDebounceInterval,
            queue: .main,
            maxWait: headDebounceMaxWait
        )
        self.topologyDebouncer = DebounceTimer(
            interval: topologyDebounceInterval,
            queue: .main,
            maxWait: topologyDebounceMaxWait
        )
        self.headDebouncer.onFire = { [weak self] in self?.fireHead() }
        self.topologyDebouncer.onFire = { [weak self] in self?.fireTopology() }
    }

    func start() {
        stop()
        startGeneration += 1
        isRunning = true
        let generation = startGeneration
        if let gitDir = resolvedGitDir, resolvedWorktreeRoot != nil {
            startStream(gitDir: gitDir)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let info = await self.gitInfoResolver(self.repoPath) else {
                self.logger.warning("could not resolve git-dir for \(self.repoPath.path, privacy: .public)")
                return
            }
            await MainActor.run {
                guard self.isRunning, self.startGeneration == generation, self.resolvedGitDir == nil else { return }
                self.resolvedGitDir = info.gitDir
                self.resolvedWorktreeRoot = info.worktreeRoot
                self.startStream(gitDir: info.gitDir)
            }
        }
    }

    func stop() {
        startGeneration += 1
        isRunning = false
        if let stream {
            self.stream = nil
            Self.releaseStream(stream)
        }
        headDebouncer.cancel()
        topologyDebouncer.cancel()
        pendingHeadFiles.removeAll()
    }

    deinit { MainActor.assumeIsolated { stop() } }

    /// Test seam: feed paths in directly without going through FSEvents.
    /// Public so tests can drive the classifier + debouncer paths
    /// deterministically.
    func processEvents(_ paths: [String]) {
        guard let gitDir = resolvedGitDir, let worktreeRoot = resolvedWorktreeRoot else { return }
        let batch = Self.classifyStreamEvents(paths, gitDir: gitDir, worktreeRoot: worktreeRoot)
        processStreamBatch(batch, requireRunning: false)
    }

    // MARK: - Private

    private func fireHead() {
        let pending = pendingHeadFiles
        pendingHeadFiles.removeAll()
        guard !pending.isEmpty else { return }
        guard let gitDir = resolvedGitDir else { return }
        var map: [URL: String] = [:]
        var sawFailure = false
        for headFile in pending {
            guard let value = HeadReader.read(headFile: headFile) else {
                sawFailure = true
                continue
            }
            let root = worktreeRoot(forHeadFile: headFile, gitDir: gitDir)
            switch value {
            case .branch(let name): map[root] = name
            case .detached:         map[root] = "(detached)"
            }
        }
        if !map.isEmpty { onHeadChanged?(map) }
        if sawFailure { topologyDebouncer.poke() }
    }

    private func worktreeRoot(forHeadFile headFile: URL, gitDir: URL) -> URL {
        // gitDir/HEAD → resolved worktree root (not necessarily parent of gitDir,
        // since gitDir may live outside the worktree for submodules/separate-gitdir).
        if headFile.deletingLastPathComponent().standardizedFileURL.path == gitDir.standardizedFileURL.path {
            return (resolvedWorktreeRoot ?? gitDir.deletingLastPathComponent()).standardizedFileURL
        }
        // gitDir/worktrees/<name>/HEAD → read sibling gitdir to find root.
        let dir = headFile.deletingLastPathComponent()
        let gitdirFile = dir.appendingPathComponent("gitdir")
        if let contents = try? String(contentsOf: gitdirFile, encoding: .utf8) {
            let gitlink = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: gitlink).deletingLastPathComponent().standardizedFileURL
        }
        return gitDir.deletingLastPathComponent().standardizedFileURL
    }

    private func fireTopology() {
        // Slow path supersedes any pending head batch.
        pendingHeadFiles.removeAll()
        onTopologyChanged?()
    }

    private func startStream(gitDir: URL) {
        if let startStreamOverride {
            startStreamOverride(self, gitDir)
            return
        }
        guard let worktreeRoot = resolvedWorktreeRoot else { return }
        let streamContext = ProjectGitWatcherStreamContext(
            watcher: self,
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        )
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(streamContext).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<ProjectGitWatcherStreamContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, ctx, numEvents, eventPaths, _, _ in
            guard let ctx else { return }
            let streamContext = Unmanaged<ProjectGitWatcherStreamContext>.fromOpaque(ctx).takeUnretainedValue()
            guard let watcher = streamContext.watcher else { return }
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let paths = cfArray as? [String], paths.count == numEvents else { return }
            let batch = ProjectGitWatcher.classifyStreamEvents(
                paths,
                gitDir: streamContext.gitDir,
                worktreeRoot: streamContext.worktreeRoot
            )
            guard batch.hasChanges else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    watcher.processStreamBatch(batch, requireRunning: true)
                }
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &context,
            [gitDir.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            Unmanaged<ProjectGitWatcherStreamContext>.fromOpaque(context.info!).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, Self.eventQueue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    nonisolated private static func releaseStream(_ stream: FSEventStreamRef) {
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

    nonisolated private static func classifyStreamEvents(
        _ paths: [String],
        gitDir: URL,
        worktreeRoot: URL
    ) -> ProjectGitWatcherStreamBatch {
        var batch = ProjectGitWatcherStreamBatch()
        for path in paths {
            switch GitEventFilter.classify(eventPath: path, gitDir: gitDir, worktreeRoot: worktreeRoot) {
            case .ignored, .other:
                continue
            case .headChange:
                batch.headFiles.insert(URL(fileURLWithPath: path).standardizedFileURL)
            case .revisionChange:
                batch.sawRevision = true
            case .revisionAndTopologyChange:
                batch.sawRevision = true
                batch.sawTopology = true
            case .topologyChange:
                batch.sawTopology = true
            }
        }
        return batch
    }

    private func processStreamBatch(_ batch: ProjectGitWatcherStreamBatch, requireRunning: Bool) {
        guard !requireRunning || isRunning else { return }
        if !batch.headFiles.isEmpty {
            pendingHeadFiles.formUnion(batch.headFiles)
            headDebouncer.poke()
        }
        if batch.sawRevision {
            onRevisionChanged?()
        }
        if batch.sawTopology {
            topologyDebouncer.poke()
        }
    }

    /// Resolves the *common* git directory and the main worktree root.
    ///
    /// We use `--git-common-dir` (not `--absolute-git-dir`) so that when a
    /// project is added pointing at a linked worktree, the watcher is still
    /// rooted at `<repo>/.git` instead of `<repo>/.git/worktrees/<name>`.
    /// That way HEAD events for *any* worktree (main + linked) are visible.
    ///
    /// We also resolve `--show-toplevel` alongside `--git-common-dir` so that
    /// for submodules and repos created with `--separate-git-dir` (where the
    /// gitDir lives *outside* the worktree), we have the true worktree root
    /// rather than having to infer it from `gitDir.deletingLastPathComponent()`.
    ///
    /// `--git-common-dir` may be relative (`.git`) when run from inside the
    /// repo, so we resolve it under `repo` via `appendingPathComponent`.
    /// `URL(fileURLWithPath:relativeTo:)` is NOT correct here — it treats the
    /// base as a file URL, so `.git` resolves to a sibling of `repo` rather
    /// than into it.
    private static func resolveGitInfo(at repo: URL) async -> (gitDir: URL, worktreeRoot: URL)? {
        async let common = Process.git(["rev-parse", "--git-common-dir"], cwd: repo)
        async let top = Process.git(["rev-parse", "--show-toplevel"], cwd: repo)
        guard
            let cR = try? await common, cR.exitCode == 0,
            let tR = try? await top, tR.exitCode == 0
        else { return nil }
        let cdir = cR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let tdir = tR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cdir.isEmpty, !tdir.isEmpty else { return nil }
        let gitDirURL: URL = cdir.hasPrefix("/")
            ? URL(fileURLWithPath: cdir)
            : repo.appendingPathComponent(cdir)
        let worktreeURL = URL(fileURLWithPath: tdir)
        return (gitDirURL.standardizedFileURL, worktreeURL.standardizedFileURL)
    }
}
