import AppKit
import Foundation

/// Resolves and loads markdown image references. Local images are loaded
/// synchronously on call; remote `https://` images are fetched
/// asynchronously and cached. The caller is responsible for applying the
/// fetched image to the placeholder attachment and invalidating layout.
///
/// `@unchecked Sendable` is sound because the only mutable state is
/// `NSCache`, which is documented thread-safe, and the main-actor-confined
/// remote-load coalescing table. `URLSession` is itself `Sendable`.
final class MarkdownImageLoader: @unchecked Sendable {
    static let shared = MarkdownImageLoader()

    enum Source: Equatable {
        case local(String)
        case remote(URL)
        case invalid
    }

    /// Categorize a markdown image `src` attribute. Empty → invalid.
    /// `http(s)://` → remote. Anything else → local.
    static func classify(_ src: String) -> Source {
        guard !src.isEmpty else { return .invalid }
        if let url = URL(string: src),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .remote(url)
        }
        return .local(src)
    }

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession
    private var inFlightRemoteCompletions: [URL: [@MainActor (NSImage?) -> Void]] = [:]

    init(session: URLSession = .shared) {
        self.session = session
        cache.countLimit = 64
    }

    /// Load a local image relative to `baseDirectory`. Returns nil if the
    /// file cannot be loaded.
    func loadLocal(src: String, baseDirectory: URL) -> NSImage? {
        let resolved = baseDirectory.appendingPathComponent(src).standardizedFileURL
        return NSImage(contentsOf: resolved)
    }

    /// Returns a cached image immediately if available; otherwise schedules
    /// an async fetch and calls `completion` on the main actor when the
    /// image arrives. If the fetch fails, `completion` is called with nil.
    @MainActor
    func loadRemote(url: URL, completion: @escaping @MainActor (NSImage?) -> Void) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        if inFlightRemoteCompletions[url] != nil {
            inFlightRemoteCompletions[url, default: []].append(completion)
            return nil
        }
        inFlightRemoteCompletions[url] = [completion]

        let task = session.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            Task { @MainActor in
                guard let self else {
                    completion(image)
                    return
                }
                if let image {
                    self.cache.setObject(image, forKey: url as NSURL)
                }
                let completions = self.inFlightRemoteCompletions.removeValue(forKey: url) ?? [completion]
                for completion in completions {
                    completion(image)
                }
            }
        }
        task.resume()
        return nil
    }
}
