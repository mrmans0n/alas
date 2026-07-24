import AppKit
import Testing
@testable import Alas

@MainActor
struct ImageDiffDecodedCacheTests {
    @Test func identicalImmutableKeysCoalesceConcurrentLoads() async {
        let cache = ImageDiffDecodedCache(totalCostLimit: 1_024_000)
        let key = ImageDiffDecodedCache.Key(
            repository: "/repo",
            revision: "abc123",
            path: "Assets/logo.png"
        )
        let calls = LockedCounter()

        async let first = cache.image(for: key, cost: 4) {
            calls.increment()
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        async let second = cache.image(for: key, cost: 4) {
            calls.increment()
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        #expect(await first != nil)
        #expect(await second != nil)
        #expect(calls.value == 1)
    }

    @Test func providerIdentityIncludesBothRevisionsAndPaths() {
        let lhs = DiffReviewImageProviderID(
            source: .range,
            repository: "/repo",
            beforeRevision: "base-a",
            afterRevision: "head",
            beforePath: "Assets/old.png",
            afterPath: "Assets/new.png"
        )
        let rhs = DiffReviewImageProviderID(
            source: .range,
            repository: "/repo",
            beforeRevision: "base-b",
            afterRevision: "head",
            beforePath: "Assets/old.png",
            afterPath: "Assets/new.png"
        )

        #expect(lhs != rhs)
    }

    @Test func cacheUsesTheConfiguredDecodedPixelBudget() {
        let cache = ImageDiffDecodedCache(totalCostLimit: 4096)
        #expect(cache.totalCostLimit == 4096)
    }

    @Test func decodedImageCostUsesBitmapStorageBytes() throws {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 20,
            pixelsHigh: 10,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let bitmap = try #require(representation)
        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.addRepresentation(bitmap)

        #expect(ImageDiffDecodedCache.decodedImageCost(for: image) == bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    @Test func failedSideIsReturnedWithoutReloading() async {
        let cache = ImageDiffDecodedCache(totalCostLimit: 1_024_000)
        let key = ImageDiffDecodedCache.Key(repository: "/repo", revision: "abc123", path: "bad.png")
        let calls = LockedCounter()

        let side = await cache.side(
            for: key,
            cost: ImageDiffDecodedCache.decodedImageCost,
            makeImageSide: { .image($0, frameCount: 1) }
        ) {
            calls.increment()
            return .failed(ImageDiffLoadFailure(message: "decode"))
        }

        if case .failed(let failure) = side {
            #expect(failure == ImageDiffLoadFailure(message: "decode"))
        } else {
            Issue.record("Expected the original failed side")
        }
        #expect(calls.value == 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
