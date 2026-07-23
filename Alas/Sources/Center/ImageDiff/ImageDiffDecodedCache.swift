import AppKit

@MainActor
final class ImageDiffDecodedCache {
    struct Key: Hashable, Sendable {
        let repository: String
        let revision: String
        let path: String
    }

    static let shared = ImageDiffDecodedCache(totalCostLimit: 256 * 1024 * 1024)

    let totalCostLimit: Int

    private let cache = NSCache<NSString, Box>()
    private var inFlight: [Key: Task<NSImage?, Never>] = [:]

    init(totalCostLimit: Int = 256 * 1024 * 1024) {
        self.totalCostLimit = totalCostLimit
        cache.totalCostLimit = totalCostLimit
    }

    func image(
        for key: Key,
        cost: Int,
        load: @escaping @MainActor () async -> NSImage?
    ) async -> NSImage? {
        if let cached = cache.object(forKey: cacheKey(for: key)) {
            return cached.image
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task { @MainActor in
            defer { self.inFlight.removeValue(forKey: key) }

            let image = await load()
            if let image {
                self.cache.setObject(Box(image), forKey: self.cacheKey(for: key), cost: cost)
            }
            return image
        }
        inFlight[key] = task
        return await task.value
    }

    private func cacheKey(for key: Key) -> NSString {
        "\(key.repository)\u{0}\(key.revision)\u{0}\(key.path)" as NSString
    }
}

private final class Box: NSObject {
    let image: NSImage

    init(_ image: NSImage) {
        self.image = image
    }
}
