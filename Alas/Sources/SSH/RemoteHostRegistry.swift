import Foundation

/// Resolves the SSH host of an in-app path. Remote paths carry their host
/// in the `RemotePath` prefix; everything else is local.
final class RemoteHostRegistry: Sendable {
    static let shared = RemoteHostRegistry()

    func host(forPath path: String?) -> String? {
        path.flatMap(RemotePath.split)?.host
    }
}

extension URL {
    /// Direct local-filesystem operations cannot be used for remote paths.
    var isRemoteAlasPath: Bool {
        path.hasPrefix(RemotePath.root + "/")
    }
}
