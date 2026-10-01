import Foundation

/// In-app identity for remote project paths. A remote path is carried as
/// `/.alas-remote/<host><realPath>` so ids and path-keyed stores stay unique
/// across hosts; the real path is restored at the transport boundary.
enum RemotePath {
    static let root = "/.alas-remote"
    /// Host for a persisted remote project that cannot be routed. Never
    /// routable: the ssh transport refuses it explicitly (`SSHCommand`), and
    /// the `.invalid` TLD (RFC 2606) is a second, independent layer.
    static let unavailableHost = "unavailable.invalid"

    /// True for the namespace root itself and anything under it, as written
    /// or once standardized. The bare root is not a remote path, but a local
    /// project there would make its children parse as remote.
    static func isReserved(_ path: String) -> Bool {
        [path, URL(fileURLWithPath: path).standardizedFileURL.path].contains { $0 == root || $0.hasPrefix(root + "/") }
    }

    /// Error for a local path inside the reserved namespace: such a path
    /// would be classified as remote and run on a made-up ssh host.
    static func reservedForRemoteError(_ path: String) -> NSError {
        NSError(domain: "ProjectsManager", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "\(path) is inside \(root)/, which is reserved for remote projects.",
        ])
    }

    /// A host must survive `virtual` → path standardization → `split`
    /// unchanged: no `/`, no `.`/`..` segment (standardizing collapses them),
    /// and no whitespace or control characters. A leading `-` would read as
    /// an ssh option. Every ordinary alias, `host.domain`, and `user@host`
    /// stays valid.
    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host != "." && host != ".." && !host.hasPrefix("-")
            && !host.unicodeScalars.contains {
                $0 == "/" || CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
    }

    static func virtual(host: String, realPath: String) -> String {
        precondition(isValidHost(host), "invalid ssh host \(host)")
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

    /// Re-encodes a decoded JSON-RPC frame after passing each string, and each
    /// object key, through `rewrite` with the object keys leading to it (a key
    /// gets its own object's path). Returning the input unchanged leaves that
    /// string byte-for-byte intact, so callers pick which fields are paths.
    static func rewritingJSONStrings(in json: Any, _ rewrite: ([String], String) -> String) -> Data? {
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
    static func virtualizing(_ path: String, like anchor: String) -> String {
        guard let host = split(anchor)?.host, path.hasPrefix("/"), split(path) == nil else { return path }
        return virtual(host: host, realPath: path)
    }

    /// Resolve existing ancestors on the host without creating the destination.
    /// Git reports physical paths, so optimistic rows must use the same identity.
    static func resolvedWorktreeDestination(
        _ path: String,
        anchor: String,
        runCommand: @Sendable (String) async throws -> ProcessResult
    ) async throws -> URL {
        let script = """
        target=\(SSHCommand.shellQuote(realPath(path)))
        parent=${target%/*}; leaf=${target##*/}; suffix=
        [ -n "$parent" ] || parent=/
        while [ ! -d "$parent" ]; do
            [ ! -e "$parent" ] && [ ! -L "$parent" ] || exit 1
            suffix="/${parent##*/}$suffix"
            parent=${parent%/*}
            [ -n "$parent" ] || parent=/
        done
        physical=$(cd "$parent" && pwd -P) || exit 1
        printf '%s%s/%s' "${physical%/}" "$suffix" "$leaf"
        """
        let result = try await runCommand(script)
        guard result.exitCode == 0, result.stdout.hasPrefix("/") else {
            throw NSError(domain: "RemoteWorktreeDestination", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "Could not resolve remote worktree destination: \(display(path)).",
            ])
        }
        return URL(fileURLWithPath: virtualizing(result.stdout, like: anchor))
    }
}

/// Strips this host's virtual paths from every ACP request and notification
/// sent to a remote agent. The frame is decoded, so `\/`-escaped encoders
/// need no special case. Prompt text blocks are stripped too: the app writes
/// worktree paths into them (review feedback's `Repository:` line).
final class RemotePathStrippingTransport: JSONRPCStdioTransporting, @unchecked Sendable {
    private let host: String
    private let inner: JSONRPCStdioTransporting

    init(host: String, inner: JSONRPCStdioTransporting) {
        self.host = host
        self.inner = inner
    }

    var incoming: AsyncStream<JSONRPCStdioTransport.Incoming> { inner.incoming }
    var requestIDPrefix: String? { inner.requestIDPrefix }
    func start() throws { try inner.start() }
    func terminate() { inner.terminate() }
    func send(_ data: Data) throws { try inner.send(strip(data)) }
    func send(_ data: Data, onWritten: @escaping @Sendable () -> Void) throws {
        try inner.send(strip(data), onWritten: onWritten)
    }

    /// Success responses are left alone: they carry file contents
    /// (`fs/read_text_file`) and terminal output that must reach the agent
    /// byte-identical, and never an in-app path the agent has to resolve.
    /// Embedded prompt resources (`resource.text`/`blob`) are file contents
    /// for the same reason.
    private func strip(_ data: Data) -> Data {
        guard String(decoding: data, as: UTF8.self).contains(".alas-remote"),
              let frame = try? JSONSerialization.jsonObject(with: data),
              (frame as? [String: Any])?["result"] == nil
        else { return data }
        return RemotePath.rewritingJSONStrings(in: frame) { path, string in
            path.dropLast().last == "resource" && ["text", "blob"].contains(path.last)
                ? string
                : RemotePath.stripping(host: host, in: string)
        } ?? data
    }
}
