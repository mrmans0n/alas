import AppKit
import Testing
@testable import Alas

@Suite("ACP thumbnail image cache")
struct ACPThumbnailImageCacheTests {
    @Test("reuses decoded image for repeated cache key loads")
    func reusesDecodedImageForRepeatedCacheKeyLoads() async throws {
        let cache = ACPThumbnailImageCache(countLimit: 8)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let counter = LoadCounter()

        let first = await cache.image(for: "asset:one") {
            counter.increment()
            return image
        }
        let second = await cache.image(for: "asset:one") {
            counter.increment()
            return NSImage(size: NSSize(width: 2, height: 2))
        }

        #expect(first === image)
        #expect(second === image)
        #expect(counter.value == 1)
    }

    @Test("file cache key changes when file contents are replaced")
    func fileCacheKeyChangesWhenFileContentsAreReplaced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("screenshot.png")
        try Data([1]).write(to: fileURL)
        let firstKey = ACPThumbnailImageCache.fileCacheKey(for: fileURL)

        try Data([1, 2, 3]).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: fileURL.path
        )
        let secondKey = ACPThumbnailImageCache.fileCacheKey(for: fileURL)

        #expect(secondKey != firstKey)
    }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
