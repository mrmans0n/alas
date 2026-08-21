import AppKit

/// Memoizes built diff text documents so row mounts don't rebuild them on the
/// main thread inside the scroll tick.
///
/// The prewarmer already performs the full document build on a background
/// queue; before this cache existed it threw the result away and only the
/// tree-sitter span cache survived, so every mount still paid the whole
/// attributed-string assembly (and every *re*mount paid it again, because the
/// signature guard lives on the text view instance that recycling replaces).
/// Keying on content + presentation inputs makes entries immutable, so there
/// is no invalidation: stale entries age out via the size cap.
///
/// Thread safety: lock-guarded, populated from the background prewarm queue
/// and read on the main actor. The cached values are immutable
/// (`NSAttributedString` plus value-type metadata); text views copy the
/// attributed string into their own storage on set, so sharing is safe.
final class DiffPaneDocumentCache: @unchecked Sendable {
    static let shared = DiffPaneDocumentCache()

    private let lock = NSLock()
    private var splitStorage: [Int: SplitEntry] = [:]
    private var stackedStorage: [Int: StackedEntry] = [:]
    private let entryLimit: Int
    /// Monotonic stamp bumped on every read and write, so recency is tracked
    /// without comparing keys or reordering an array. A full review can
    /// easily exceed `entryLimit` distinct hunks, and clearing the whole
    /// storage on overflow would wipe every already-warmed document each
    /// time a new one arrives — negating the prewarmer for exactly the
    /// large reviews it matters most for. Evict only the single oldest
    /// entry instead.
    private var accessStamp: UInt64 = 0

    private struct SplitEntry {
        let result: DiffPaneTextDocumentBuilder.SplitResult
        var lastAccess: UInt64
    }

    private struct StackedEntry {
        let result: DiffPaneTextDocumentBuilder.StackedResult
        var lastAccess: UInt64
    }

    init(entryLimit: Int = 64) {
        self.entryLimit = entryLimit
    }

    #if DEBUG
    private var hits = 0
    private var misses = 0

    /// Document builds avoided (`hits`) versus performed (`misses`).
    var statisticsForTests: (hits: Int, misses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hits, misses)
    }

    func resetStatisticsForTests() {
        lock.lock()
        defer { lock.unlock() }
        hits = 0
        misses = 0
    }
    #endif

    func splitResult(
        rows: [DiffDisplayRow],
        rowsSignature: DiffDisplayRowsSignature? = nil,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> DiffPaneTextDocumentBuilder.SplitResult {
        let key = key(
            rowsSignature: rowsSignature ?? DiffDisplayRowsSignature(rows),
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        )
        if let cached = cachedSplit(forKey: key) { return cached }
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            rows: rows,
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        )
        store(result, forKey: key)
        return result
    }

    func stackedResult(
        rows: [DiffDisplayRow],
        rowsSignature: DiffDisplayRowsSignature? = nil,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> DiffPaneTextDocumentBuilder.StackedResult {
        let key = key(
            rowsSignature: rowsSignature ?? DiffDisplayRowsSignature(rows),
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        )
        if let cached = cachedStacked(forKey: key) { return cached }
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            rows: rows,
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        )
        store(result, forKey: key)
        return result
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        splitStorage.removeAll(keepingCapacity: true)
        stackedStorage.removeAll(keepingCapacity: true)
        accessStamp = 0
    }

    private func key(
        rowsSignature: DiffDisplayRowsSignature,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(rowsSignature)
        hasher.combine(fileExtension)
        hasher.combine(font.fontName)
        hasher.combine(font.pointSize)
        hasher.combine(showWhitespace)
        hasher.combine(theme)
        return hasher.finalize()
    }

    private func cachedSplit(forKey key: Int) -> DiffPaneTextDocumentBuilder.SplitResult? {
        lock.lock()
        defer { lock.unlock() }
        accessStamp &+= 1
        guard let entry = splitStorage[key] else {
            #if DEBUG
            misses += 1
            #endif
            return nil
        }
        #if DEBUG
        hits += 1
        #endif
        splitStorage[key]?.lastAccess = accessStamp
        return entry.result
    }

    private func cachedStacked(forKey key: Int) -> DiffPaneTextDocumentBuilder.StackedResult? {
        lock.lock()
        defer { lock.unlock() }
        accessStamp &+= 1
        guard let entry = stackedStorage[key] else {
            #if DEBUG
            misses += 1
            #endif
            return nil
        }
        #if DEBUG
        hits += 1
        #endif
        stackedStorage[key]?.lastAccess = accessStamp
        return entry.result
    }

    private func store(_ result: DiffPaneTextDocumentBuilder.SplitResult, forKey key: Int) {
        lock.lock()
        defer { lock.unlock() }
        accessStamp &+= 1
        if splitStorage.count >= entryLimit, splitStorage[key] == nil {
            evictOldest(from: &splitStorage)
        }
        splitStorage[key] = SplitEntry(result: result, lastAccess: accessStamp)
    }

    private func store(_ result: DiffPaneTextDocumentBuilder.StackedResult, forKey key: Int) {
        lock.lock()
        defer { lock.unlock() }
        accessStamp &+= 1
        if stackedStorage.count >= entryLimit, stackedStorage[key] == nil {
            evictOldest(from: &stackedStorage)
        }
        stackedStorage[key] = StackedEntry(result: result, lastAccess: accessStamp)
    }

    private func evictOldest(from storage: inout [Int: SplitEntry]) {
        guard let oldest = storage.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { return }
        storage.removeValue(forKey: oldest)
    }

    private func evictOldest(from storage: inout [Int: StackedEntry]) {
        guard let oldest = storage.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { return }
        storage.removeValue(forKey: oldest)
    }
}
