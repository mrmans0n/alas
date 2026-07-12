import Foundation

/// Small in-memory cache for remote image bytes shown in ACP tool cards.
/// Failed reads are deliberately not cached so a recovered SSH connection can
/// retry the image on the next render.
actor RemoteImageCache {
    static let shared = RemoteImageCache()

    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private let capacity = 32

    func imageData(host: String, path: String) async -> Data? {
        let key = "\(host)\u{0}\(path)"
        if let cached = cache[key] { return cached }

        guard case let .file(data, _) = try? await RemoteFileAccess.read(host: host, path: path)
        else { return nil }

        // Another task can complete the same read while this actor awaits.
        // Reuse the cached result instead of recording the key twice.
        if let cached = cache[key] { return cached }

        while order.count >= capacity, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[key] = data
        order.append(key)
        return data
    }
}
