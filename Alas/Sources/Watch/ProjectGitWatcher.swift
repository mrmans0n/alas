import Foundation
import CoreServices
import os

/// Per-project FSEvents watcher rooted at the project's resolved `.git`
/// directory. Splits events into a fast HEAD-only path (callback emits
/// `[worktreeRoot: branchLabel]` read directly from disk) and a slow
/// topology path (callback fires `onTopologyChanged` for the caller to
/// reconcile via `git worktree list`). See the design doc:
/// docs/superpowers/specs/2026-05-14-sidebar-auto-refresh-on-branch-change-design.md
@MainActor
final class ProjectGitWatcher {
    var onHeadChanged: (([URL: String]) -> Void)?
    var onTopologyChanged: (() -> Void)?

    private let repoPath: URL
    private var resolvedGitDir: URL?
    private var stream: FSEventStreamRef?
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
            headDebounceInterval: 0.1,
            headDebounceMaxWait: 0.5,
            topologyDebounceInterval: 0.5,
            topologyDebounceMaxWait: 2.0
        )
    }

    /// Test initializer: caller supplies the resolved git-dir and tighter
    /// debounce timings so tests don't sleep for seconds. When
    /// `resolvedGitDir` is non-nil, no `git` invocation happens — the
    /// watcher is ready to `processEvents` immediately.
    init(
        repoPath: URL,
        resolvedGitDir: URL?,
        headDebounceInterval: TimeInterval,
        headDebounceMaxWait: TimeInterval,
        topologyDebounceInterval: TimeInterval,
        topologyDebounceMaxWait: TimeInterval
    ) {
        self.repoPath = repoPath
        self.resolvedGitDir = resolvedGitDir
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
        if let gitDir = resolvedGitDir {
            startStream(gitDir: gitDir)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let gitDir = await Self.resolveGitDir(at: self.repoPath) else {
                self.logger.warning("could not resolve git-dir for \(self.repoPath.path, privacy: .public)")
                return
            }
            await MainActor.run {
                guard self.resolvedGitDir == nil else { return }  // started/stopped meanwhile
                self.resolvedGitDir = gitDir
                self.startStream(gitDir: gitDir)
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
        headDebouncer.cancel()
        topologyDebouncer.cancel()
        pendingHeadFiles.removeAll()
    }

    deinit { MainActor.assumeIsolated { stop() } }

    /// Test seam: feed paths in directly without going through FSEvents.
    /// Public so tests can drive the classifier + debouncer paths
    /// deterministically.
    func processEvents(_ paths: [String]) {
        guard let gitDir = resolvedGitDir else { return }
        var sawHead = false
        var sawTopology = false
        for path in paths {
            switch GitEventFilter.classify(eventPath: path, gitDir: gitDir) {
            case .ignored, .other:
                continue
            case .headChange(let worktreeRoot):
                pendingHeadFiles.insert(headFile(forWorktreeRoot: worktreeRoot, gitDir: gitDir))
                sawHead = true
            case .topologyChange:
                sawTopology = true
            }
        }
        if sawHead { headDebouncer.poke() }
        if sawTopology { topologyDebouncer.poke() }
    }

    // MARK: - Private

    private func headFile(forWorktreeRoot root: URL, gitDir: URL) -> URL {
        // Main worktree: HEAD lives at gitDir/HEAD.
        if root.standardizedFileURL.path == gitDir.deletingLastPathComponent().standardizedFileURL.path {
            return gitDir.appendingPathComponent("HEAD")
        }
        // Linked worktree: walk gitDir/worktrees/<name>/gitdir back to find
        // which name matches this root. Rare path; small N.
        let worktreesDir = gitDir.appendingPathComponent("worktrees")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: worktreesDir,
            includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries {
            let gitdirFile = entry.appendingPathComponent("gitdir")
            guard let contents = try? String(contentsOf: gitdirFile, encoding: .utf8) else { continue }
            let gitlink = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = URL(fileURLWithPath: gitlink).deletingLastPathComponent().standardizedFileURL
            if candidate.path == root.standardizedFileURL.path {
                return entry.appendingPathComponent("HEAD")
            }
        }
        // Fallback: treat as main-worktree HEAD if we can't find a match.
        // The follow-up topology refresh will reconcile.
        return gitDir.appendingPathComponent("HEAD")
    }

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
        // gitDir/HEAD → repo root (parent of .git).
        if headFile.deletingLastPathComponent().standardizedFileURL.path == gitDir.standardizedFileURL.path {
            return gitDir.deletingLastPathComponent().standardizedFileURL
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
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, ctx, numEvents, eventPaths, _, _ in
            guard let ctx else { return }
            let watcher = Unmanaged<ProjectGitWatcher>.fromOpaque(ctx).takeUnretainedValue()
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let paths = cfArray as? [String], paths.count == numEvents else { return }
            // FSEvents is dispatched on .main per FSEventStreamSetDispatchQueue below.
            MainActor.assumeIsolated { watcher.processEvents(paths) }
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
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private static func resolveGitDir(at repo: URL) async -> URL? {
        guard let result = try? await Process.git(
            ["rev-parse", "--absolute-git-dir"],
            cwd: repo
        ), result.exitCode == 0 else { return nil }
        let dir = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir).standardizedFileURL
    }
}
