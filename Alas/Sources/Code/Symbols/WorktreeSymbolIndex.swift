import Foundation
import os

/// In-memory declarations per local worktree. Built lazily the first time a
/// picker asks, then refreshed incrementally: only files whose size or
/// modification date changed are parsed again.
///
/// Each root has at most one current refresh. A newer request supersedes the
/// older one, which is cancelled, commits nothing more, and hands its
/// consumers to the newer one, so every stream ends with the newest result.
actor WorktreeSymbolIndex {
    struct Snapshot: Sendable, Equatable {
        let symbols: [SymbolEntry]
        let indexedFiles: Int
        let totalFiles: Int
        var isComplete: Bool { indexedFiles >= totalFiles }
    }

    /// Lists the worktree-relative files to index (from `FileIndex`). `nil`
    /// means enumeration failed: the refresh replays the cache, changing nothing.
    typealias FileList = @Sendable () async -> [String]?

    static let maxFileBytes = SymbolSource.maxBytes
    /// Publish progress after this many files.
    static let snapshotInterval = 200
    /// Let newer requests and cancellations reach the actor after this many files.
    static let yieldInterval = 32

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private struct Record {
        let stamp: Stamp
        let symbols: [SymbolEntry]
    }

    private struct Refresh {
        let generation: Int
        let task: Task<Void, Never>
    }

    private struct Consumer {
        let key: String
        /// The refresh whose snapshots this consumer receives.
        var generation: Int
        let continuation: AsyncStream<Snapshot>.Continuation
    }

    private var records: [String: [String: Record]] = [:]
    /// The current refresh per root; superseded ones are absent.
    private var refreshes: [String: Refresh] = [:]
    /// Keyed by the generation of the request that opened the stream.
    private var consumers: [Int: Consumer] = [:]
    private var lastGeneration = 0
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "symbols.index")

    func isLoaded(root: URL) -> Bool { records[Self.key(root)] != nil }

    /// Streams progress while refreshing `root` against what `files` lists.
    /// Ends after a complete snapshot, or right away if `remove(root:)` drops
    /// the root. Only the newest progress is buffered. When every consumer of
    /// a refresh is gone, parsing stops; files committed with the last
    /// progress snapshot are kept.
    func updates(root: URL, files: @escaping FileList) -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let key = Self.key(root)
        let generation = start(root: root, key: key, files: files)
        consumers[generation] = Consumer(key: key, generation: generation, continuation: continuation)
        continuation.onTermination = { _ in Task { await self.consumerEnded(generation) } }
        return stream
    }

    /// Refreshes `root` only if a picker already built its index. Checked
    /// here, not by the caller, so it cannot bring back a removed root.
    func refreshIfLoaded(root: URL, files: @escaping FileList) {
        let key = Self.key(root)
        guard records[key] != nil else { return }
        start(root: root, key: key, files: files)
    }

    /// Drops the index of `root`, cancels its refresh, and ends its streams.
    func remove(root: URL) {
        let key = Self.key(root)
        refreshes.removeValue(forKey: key)?.task.cancel()
        records[key] = nil
        for (id, consumer) in consumers where consumer.key == key {
            consumers[id] = nil
            consumer.continuation.finish()
        }
    }

    @discardableResult
    private func start(root: URL, key: String, files: @escaping FileList) -> Int {
        lastGeneration += 1
        let generation = lastGeneration
        // Hand the superseded refresh's consumers over now: its file listing
        // may not notice cancellation and could keep them waiting.
        if let superseded = refreshes[key] {
            for (id, consumer) in consumers where consumer.generation == superseded.generation {
                consumers[id]?.generation = generation
            }
            superseded.task.cancel()
        }
        let task = Task { await self.refresh(root: root, key: key, generation: generation, files: files) }
        refreshes[key] = Refresh(generation: generation, task: task)
        return generation
    }

    private func isCurrent(_ key: String, _ generation: Int) -> Bool {
        refreshes[key]?.generation == generation
    }

    private func refresh(root: URL, key: String, generation: Int, files: FileList) async {
        let listed = await files()
        guard isCurrent(key, generation) else { return }
        guard let listed else {
            refreshes[key] = nil
            return end(generation, with: Self.cachedSnapshot(records[key]))
        }
        let candidates = listed.filter { LanguageRegistry.supportsSymbols(forPath: $0) }
        let wanted = Set(candidates)
        var current = (records[key] ?? [:]).filter { wanted.contains($0.key) }
        // Always publish first, so even a small or fully cached worktree
        // shows "Indexing symbols…" until the stat pass finishes.
        publish(generation, Self.snapshot(current, indexed: 0, total: candidates.count))
        let started = Date()
        var processed = 0
        var parsed = 0
        for path in candidates {
            if let url = SymbolSource.containedLocalURL(root: root, relativePath: path),
               let stamp = Self.stamp(of: url) {
                if current[path]?.stamp != stamp {
                    if stamp.size > Self.maxFileBytes {
                        current[path] = Record(stamp: stamp, symbols: [])
                    } else if let source = SymbolSource.readBounded(url, within: root) {
                        current[path] = Record(stamp: stamp, symbols: SymbolExtractor.symbols(in: source, relativePath: path))
                        parsed += 1
                    }
                    // A failed read commits nothing: the previous record (and
                    // its old stamp) stays, so the next refresh retries.
                }
            } else {
                current[path] = nil
            }
            processed += 1
            if processed % Self.snapshotInterval == 0 {
                records[key] = current
                publish(generation, Self.snapshot(current, indexed: processed, total: candidates.count))
            }
            if processed % Self.yieldInterval == 0 {
                await Task.yield()
                guard isCurrent(key, generation) else { return }
            }
        }
        records[key] = current
        refreshes[key] = nil
        end(generation, with: Self.snapshot(current, indexed: processed, total: candidates.count))
        logger.debug("refreshed \(key, privacy: .private): \(candidates.count) files, \(parsed) parsed in \(Date().timeIntervalSince(started), format: .fixed(precision: 3))s")
    }

    private func publish(_ generation: Int, _ snapshot: @autoclosure () -> Snapshot) {
        let waiting = consumers.values.filter { $0.generation == generation }
        guard !waiting.isEmpty else { return }
        let snapshot = snapshot()
        for consumer in waiting { consumer.continuation.yield(snapshot) }
    }

    private func end(_ generation: Int, with snapshot: @autoclosure () -> Snapshot) {
        let waiting = consumers.filter { $0.value.generation == generation }
        guard !waiting.isEmpty else { return }
        let snapshot = snapshot()
        for (id, consumer) in waiting {
            consumers[id] = nil
            consumer.continuation.yield(snapshot)
            consumer.continuation.finish()
        }
    }

    /// A refresh nobody consumes any more stops.
    private func consumerEnded(_ id: Int) {
        guard let consumer = consumers.removeValue(forKey: id),
              let refresh = refreshes[consumer.key],
              refresh.generation == consumer.generation,
              !consumers.values.contains(where: { $0.generation == refresh.generation })
        else { return }
        refresh.task.cancel()
        refreshes[consumer.key] = nil
    }

    private static func key(_ root: URL) -> String { root.standardizedFileURL.path }

    private static func stamp(of url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let modified = values.contentModificationDate,
              let size = values.fileSize else { return nil }
        return Stamp(modified: modified, size: size)
    }

    private static func cachedSnapshot(_ records: [String: Record]?) -> Snapshot {
        let records = records ?? [:]
        return snapshot(records, indexed: records.count, total: records.count)
    }

    private static func snapshot(_ records: [String: Record], indexed: Int, total: Int) -> Snapshot {
        let symbols = records.keys.sorted().flatMap { records[$0]?.symbols ?? [] }
        return Snapshot(symbols: symbols, indexedFiles: indexed, totalFiles: total)
    }
}
