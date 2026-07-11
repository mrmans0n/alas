import Foundation

/// Maps absolute filesystem roots of remote projects and linked worktrees to
/// their SSH host. Local projects are never registered, preserving the local
/// git path unchanged.
final class RemoteHostRegistry: @unchecked Sendable {
    static let shared = RemoteHostRegistry()

    private let lock = NSLock()
    private var hostsByRoot: [String: String] = [:]

    private static func normalize(_ root: String) -> String {
        root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    }

    func register(root: String, host: String) {
        lock.lock()
        hostsByRoot[Self.normalize(root)] = host
        lock.unlock()
    }

    func unregister(root: String) {
        lock.lock()
        hostsByRoot.removeValue(forKey: Self.normalize(root))
        lock.unlock()
    }

    /// Finds the longest path-component root containing `path`.
    func host(forPath path: String?) -> String? {
        guard let path else { return nil }
        lock.lock()
        defer { lock.unlock() }

        var best: (root: String, host: String)?
        for (root, host) in hostsByRoot where path == root || path.hasPrefix(root + "/") {
            if best == nil || root.count > best!.root.count {
                best = (root, host)
            }
        }
        return best?.host
    }

    func removeAll() {
        lock.lock()
        hostsByRoot.removeAll()
        lock.unlock()
    }
}

extension URL {
    /// Direct local-filesystem operations cannot be used for registered paths.
    var isRemoteAlasPath: Bool {
        RemoteHostRegistry.shared.host(forPath: path) != nil
    }
}
