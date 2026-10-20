import Foundation
import AlasFoundation

/// In-app identity for remote project paths. A remote path is carried as
/// `/.alas-remote/<host><realPath>` so ids and path-keyed stores stay unique
/// across hosts; the real path is restored at the transport boundary.
public enum RemotePath: Sendable {
    public static let root = "/.alas-remote"
    /// Host for a persisted remote project that cannot be routed. Never
    /// routable: the ssh transport refuses it explicitly (`SSHCommand`), and
    /// the `.invalid` TLD (RFC 2606) is a second, independent layer.
    public static let unavailableHost = "unavailable.invalid"

    /// True for the namespace root itself and anything under it, as written
    /// or once standardized. The bare root is not a remote path, but a local
    /// project there would make its children parse as remote.
    public static func isReserved(_ path: String) -> Bool {
        [path, URL(fileURLWithPath: path).standardizedFileURL.path].contains { $0 == root || $0.hasPrefix(root + "/") }
    }

    /// Error for a local path inside the reserved namespace: such a path
    /// would be classified as remote and run on a made-up ssh host.
    public static func reservedForRemoteError(_ path: String) -> NSError {
        NSError(domain: "ProjectsManager", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "\(path) is inside \(root)/, which is reserved for remote projects.",
        ])
    }

    /// A host must survive `virtual` → path standardization → `split`
    /// unchanged: no `/`, no `.`/`..` segment (standardizing collapses them),
    /// and no whitespace or control characters. A leading `-` would read as
    /// an ssh option. Every ordinary alias, `host.domain`, and `user@host`
    /// stays valid.
    public static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host != "." && host != ".." && !host.hasPrefix("-")
            && !host.unicodeScalars.contains {
                $0 == "/" || CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
    }

    public static func virtual(host: String, realPath: String) -> String {
        precondition(isValidHost(host), "invalid ssh host \(host)")
        return "\(root)/\(host)\(realPath)"
    }

    public static func split(_ path: String) -> (host: String, realPath: String)? {
        guard path.hasPrefix(root + "/") else { return nil }
        let rest = path.dropFirst(root.count + 1)
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
        return (String(rest[..<slash]), String(rest[slash...]))
    }

    public static func realPath(_ path: String) -> String {
        split(path)?.realPath ?? path
    }

    public static func display(_ path: String) -> String {
        split(path).map { "\($0.host):\($0.realPath)" } ?? path
    }

    /// Outbound: rewrite every virtual path for `host` inside an opaque
    /// script or JSON payload. Matching on the trailing slash keeps `mini`
    /// from eating `mini.lan`.
    public static func stripping(host: String, in text: String) -> String {
        text.replacingOccurrences(of: "\(root)/\(host)/", with: "/")
    }

    /// Re-encodes a decoded JSON-RPC frame after passing each string, and each
    /// object key, through `rewrite` with the object keys leading to it (a key
    /// gets its own object's path). Returning the input unchanged leaves that
    /// string byte-for-byte intact, so callers pick which fields are paths.
    public static func rewritingJSONStrings(in json: Any, _ rewrite: ([String], String) -> String) -> Data? {
        func walk(_ node: Any, _ path: [String]) -> Any {
            switch node {
            case let string as String:
                return rewrite(path, string)
            case let array as [Any]:
                return array.map { walk($0, path) }
            case let object as [String: Any]:
                return Dictionary(object.map { (rewrite(path, $0.key), walk($0.value, path + [$0.key])) }) { a, _ in a }
            default:
                return node
            }
        }
        return try? JSONSerialization.data(withJSONObject: walk(json, []), options: .withoutEscapingSlashes)
    }

    /// Inbound: an absolute real path reported by a process on the same host
    /// as `anchor` becomes virtual; everything else is returned unchanged.
    public static func virtualizing(_ path: String, like anchor: String) -> String {
        guard let host = split(anchor)?.host, path.hasPrefix("/"), split(path) == nil else { return path }
        return virtual(host: host, realPath: path)
    }
}
