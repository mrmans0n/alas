import Foundation

/// Process-wide memo for tree-sitter highlight spans keyed by exact source
/// text and file extension. Virtualized diff rows re-highlight identical
/// content every time they remount during scrolling; this cache makes those
/// remounts cheap and lets background prewarming pay the parse cost off the
/// scroll path. Spans depend only on the source text and language, never on
/// theme or font, so entries stay valid across appearance changes.
final class HighlightSpanCache: @unchecked Sendable {
    static let shared = HighlightSpanCache()

    /// Whole-file sources (merge editor, markdown blocks) can be large;
    /// parsing those is not on the diff fling path and caching them would
    /// evict many row-sized entries.
    private static let maximumSourceUTF16Length = 64 * 1024

    private final class Entry {
        let spans: [HighlightSpan]
        init(spans: [HighlightSpan]) { self.spans = spans }
    }

    private let storage = NSCache<NSString, Entry>()

    #if DEBUG
    private let statsLock = NSLock()
    private var hits = 0
    private var misses = 0

    /// Tokenization work avoided (`hits`) versus performed (`misses`).
    var statisticsForTests: (hits: Int, misses: Int) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (hits, misses)
    }

    func resetStatisticsForTests() {
        statsLock.lock()
        defer { statsLock.unlock() }
        hits = 0
        misses = 0
    }

    private func record(hit: Bool) {
        statsLock.lock()
        defer { statsLock.unlock() }
        if hit { hits += 1 } else { misses += 1 }
    }
    #endif

    /// `countLimit` alone bounds entry count, not bytes: each key can retain
    /// up to `maximumSourceUTF16Length` of source text plus its span array,
    /// so an eagerly-prewarmed large review could otherwise grow this cache
    /// into the hundreds of megabytes. Mirrors `ImageDiffDecodedCache`'s use
    /// of a byte-cost limit for the same reason.
    init(countLimit: Int = 8192, totalCostLimit: Int = 64 * 1024 * 1024) {
        storage.countLimit = countLimit
        storage.totalCostLimit = totalCostLimit
    }

    func spans(source: String, fileExtension: String) -> [HighlightSpan]? {
        guard (source as NSString).length <= Self.maximumSourceUTF16Length else { return nil }
        let spans = storage.object(forKey: Self.key(source: source, fileExtension: fileExtension))?.spans
        #if DEBUG
        record(hit: spans != nil)
        #endif
        return spans
    }

    func store(_ spans: [HighlightSpan], source: String, fileExtension: String) {
        guard (source as NSString).length <= Self.maximumSourceUTF16Length else { return }
        let cost = (source as NSString).length * 2 + spans.count * MemoryLayout<HighlightSpan>.stride
        storage.setObject(Entry(spans: spans), forKey: Self.key(source: source, fileExtension: fileExtension), cost: cost)
    }

    func removeAll() {
        storage.removeAllObjects()
    }

    private static func key(source: String, fileExtension: String) -> NSString {
        "\(fileExtension)\u{1}\(source)" as NSString
    }
}
