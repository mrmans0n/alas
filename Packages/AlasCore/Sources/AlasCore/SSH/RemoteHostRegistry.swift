import Foundation

/// Resolves the SSH host of an in-app path. Remote paths carry their host
/// in the `RemotePath` prefix; everything else is local.
public final class RemoteHostRegistry: Sendable {
    public static let shared = RemoteHostRegistry()

    public func host(forPath path: String?) -> String? {
        path.flatMap(RemotePath.split)?.host
    }

    public init() {}
}

extension URL {
    /// Direct local-filesystem operations cannot be used for remote paths.
    public var isRemoteAlasPath: Bool {
        path.hasPrefix(RemotePath.root + "/")
    }
}
