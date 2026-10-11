import Foundation

struct ImageDiffCacheKey: Hashable, Sendable {
    let repository: String
    let revision: String
    let path: String
}

/// Decodes and caches review images. The app installs the AppKit
/// implementation at launch (`PlatformServices.install()`); until then every
/// image reports as failed to decode.
@MainActor
struct ImageDiffDecoding {
    /// Returns the cached side for `key`, or runs `load` once for concurrent callers.
    var cachedSide: (_ key: ImageDiffCacheKey, _ load: @escaping @MainActor () async -> ImageDiffSide) async -> ImageDiffSide
    var decode: (_ data: Data, _ worktreePath: URL) async -> ImageDiffSide

    static var shared = ImageDiffDecoding(
        cachedSide: { _, load in await load() },
        decode: { _, _ in .failed(ImageDiffLoadFailure(message: "Image decoding is unavailable.")) }
    )
}
