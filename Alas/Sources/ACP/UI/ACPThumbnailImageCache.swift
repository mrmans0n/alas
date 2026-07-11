import AppKit
import Foundation
import SwiftUI

final class ACPThumbnailImageCache: @unchecked Sendable {
    static let shared = ACPThumbnailImageCache()

    private let cache = NSCache<NSString, NSImage>()

    init(countLimit: Int = 128) {
        cache.countLimit = countLimit
    }

    func cachedImage(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: NSImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    static func fileCacheKey(for fileURL: URL) -> String {
        let standardizedURL = fileURL.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: standardizedURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "file:\(standardizedURL.path):\(size):\(modified)"
    }

    func image(
        for key: String,
        load: @escaping @Sendable () -> NSImage?
    ) async -> NSImage? {
        if let cached = cachedImage(for: key) {
            return cached
        }

        let loaded = await Task.detached(priority: .utility) {
            load()
        }.value

        if let loaded {
            store(loaded, for: key)
        }
        return loaded
    }
}

struct ACPCachedThumbnail<Thumbnail: View, Placeholder: View, Failure: View>: View {
    let cacheKey: String
    let loadImage: @Sendable () -> NSImage?
    @ViewBuilder var thumbnail: (NSImage) -> Thumbnail
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var image: NSImage?
    @State private var didFinishLoading = false

    init(
        cacheKey: String,
        loadImage: @escaping @Sendable () -> NSImage?,
        @ViewBuilder thumbnail: @escaping (NSImage) -> Thumbnail,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.cacheKey = cacheKey
        self.loadImage = loadImage
        self.thumbnail = thumbnail
        self.placeholder = placeholder
        self.failure = failure
        _image = State(initialValue: ACPThumbnailImageCache.shared.cachedImage(for: cacheKey))
    }

    var body: some View {
        Group {
            if let image {
                thumbnail(image)
            } else if didFinishLoading {
                failure()
            } else {
                placeholder()
            }
        }
        .onChange(of: cacheKey) { _, newValue in
            image = ACPThumbnailImageCache.shared.cachedImage(for: newValue)
            didFinishLoading = false
        }
        .task(id: cacheKey) {
            if let cached = ACPThumbnailImageCache.shared.cachedImage(for: cacheKey) {
                image = cached
                didFinishLoading = false
                return
            }
            let loaded = await ACPThumbnailImageCache.shared.image(for: cacheKey, load: loadImage)
            guard !Task.isCancelled else { return }
            image = loaded
            didFinishLoading = true
        }
    }
}

extension ACPCachedThumbnail where Failure == Placeholder {
    init(
        cacheKey: String,
        loadImage: @escaping @Sendable () -> NSImage?,
        @ViewBuilder thumbnail: @escaping (NSImage) -> Thumbnail,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            cacheKey: cacheKey,
            loadImage: loadImage,
            thumbnail: thumbnail,
            placeholder: placeholder,
            failure: placeholder
        )
    }
}
