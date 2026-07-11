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
