import Foundation

/// Per-coordinator snippet cache used by the multi-result picker. Reads a
/// single line lazily on first access for `(absolutePath, line)` and
/// returns the cached value on subsequent calls. Bounded to 64 entries.
final class DefinitionSnippetCache {
    private struct Key: Hashable { let path: String
    let line: Int }
    private struct NavigationKey: Hashable {
        let host: String?
        let uri: String
        let freshness: Date?
        let line: Int
    }
    private var cache: [Key: String] = [:]
    private var navigationCache: [NavigationKey: String] = [:]
    private var order: [Key] = []
    private let limit = 64

    func line(at url: URL, line: Int) -> String {
        let key = Key(path: url.path, line: line)
        if let cached = cache[key] { return cached }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return store(key: key, value: "")
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 0, line < lines.count else {
            return store(key: key, value: "")
        }
        return store(key: key, value: String(lines[line]).trimmingCharacters(in: .whitespaces))
    }

    func line(host: String?, uri: String, freshness: Date?, contents: String, line: Int) -> String {
        let key = NavigationKey(host: host, uri: uri, freshness: freshness, line: line)
        if let cached = navigationCache[key] { return cached }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let value = lines.indices.contains(line)
            ? String(lines[line]).trimmingCharacters(in: .whitespaces)
            : ""
        navigationCache[key] = value
        return value
    }

    private func store(key: Key, value: String) -> String {
        cache[key] = value
        order.append(key)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return value
    }
}
