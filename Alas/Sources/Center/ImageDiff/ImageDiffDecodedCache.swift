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
    private var inFlightSides: [Key: Task<ImageDiffSide, Never>] = [:]

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

    func side(
        for key: Key,
        cost: @escaping @MainActor (NSImage) -> Int,
        makeImageSide: @escaping @MainActor (NSImage) -> ImageDiffSide,
        load: @escaping @MainActor () async -> ImageDiffSide
    ) async -> ImageDiffSide {
        if let cached = cache.object(forKey: cacheKey(for: key)) {
            return makeImageSide(cached.image)
        }
        if let task = inFlightSides[key] {
            return await task.value
        }

        let task = Task { @MainActor in
            defer { self.inFlightSides.removeValue(forKey: key) }

            let side = await load()
            if case .image(let image, _) = side {
                self.cache.setObject(Box(image), forKey: self.cacheKey(for: key), cost: cost(image))
            }
            return side
        }
        inFlightSides[key] = task
        return await task.value
    }

    static func decodedImageCost(for image: NSImage) -> Int {
        var bitmapBytes = 0
        for case let bitmap as NSBitmapImageRep in image.representations {
            let (bytes, bytesOverflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: bitmap.pixelsHigh)
            let (total, totalOverflow) = bitmapBytes.addingReportingOverflow(bytes)
            if bytesOverflow || totalOverflow {
                return Int.max
            }
            bitmapBytes = total
        }
        guard bitmapBytes > 0 else {
            let width = max(1, Int(image.size.width.rounded(.up)))
            let height = max(1, Int(image.size.height.rounded(.up)))
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            return overflow ? Int.max : pixels.multipliedReportingOverflow(by: 4).partialValue
        }
        return bitmapBytes
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
