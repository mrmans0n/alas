import Foundation

/// In-app identity for remote project paths. A remote path is carried as
/// `/.alas-remote/<host><realPath>` so ids and path-keyed stores stay unique
/// across hosts; the real path is restored at the transport boundary.
enum RemotePath {
    static let root = "/.alas-remote"

    static func virtual(host: String, realPath: String) -> String {
        precondition(!host.isEmpty && !host.contains("/"), "invalid ssh host \(host)")
        return "\(root)/\(host)\(realPath)"
    }

    static func split(_ path: String) -> (host: String, realPath: String)? {
        guard path.hasPrefix(root + "/") else { return nil }
        let rest = path.dropFirst(root.count + 1)
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
        return (String(rest[..<slash]), String(rest[slash...]))
    }

    static func realPath(_ path: String) -> String {
        split(path)?.realPath ?? path
    }

    static func display(_ path: String) -> String {
        split(path).map { "\($0.host):\($0.realPath)" } ?? path
    }

    /// Outbound: rewrite every virtual path for `host` inside an opaque
    /// script or JSON payload. Matching on the trailing slash keeps `mini`
    /// from eating `mini.lan`.
    static func stripping(host: String, in text: String) -> String {
        text.replacingOccurrences(of: "\(root)/\(host)/", with: "/")
    }

    /// Inbound for protocols whose paths are all `file://` URIs (LSP).
    static func virtualizingFileURIs(host: String, in text: String) -> String {
        text.replacingOccurrences(of: "file:///", with: "file://\(root)/\(host)/")
    }
}
