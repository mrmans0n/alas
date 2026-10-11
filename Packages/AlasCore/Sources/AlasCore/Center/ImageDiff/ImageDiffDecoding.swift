import Foundation

public struct ImageDiffCacheKey: Hashable, Sendable {
    public let repository: String
    public let revision: String
    public let path: String

    public init(repository: String, revision: String, path: String) {
        self.repository = repository
        self.revision = revision
        self.path = path
    }
}

/// Decodes and caches review images. The app installs the AppKit
/// implementation at launch (`PlatformServices.install()`); until then every
/// image reports as failed to decode.
@MainActor
public struct ImageDiffDecoding: Sendable {
    /// Returns the cached side for `key`, or runs `load` once for concurrent callers.
    public var cachedSide: (_ key: ImageDiffCacheKey, _ load: @escaping @MainActor () async -> ImageDiffSide) async -> ImageDiffSide
    public var decode: (_ data: Data, _ worktreePath: URL) async -> ImageDiffSide

    public static var shared = ImageDiffDecoding(
        cachedSide: { _, load in await load() },
        decode: { _, _ in .failed(ImageDiffLoadFailure(message: "Image decoding is unavailable.")) }
    )

    public init(cachedSide: @escaping (_ key: ImageDiffCacheKey, _ load: @escaping @MainActor () async -> ImageDiffSide) async -> ImageDiffSide, decode: @escaping (_ data: Data, _ worktreePath: URL) async -> ImageDiffSide) {
        self.cachedSide = cachedSide
        self.decode = decode
    }
}
