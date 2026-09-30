import Foundation

/// In-app identity for remote project paths. A remote path is carried as
/// `/.alas-remote/<host><realPath>` so ids and path-keyed stores stay unique
/// across hosts; the real path is restored at the transport boundary.
enum RemotePath {
    static let root = "/.alas-remote"

    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && !host.contains("/")
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

    /// Inbound for protocols whose paths are all `file://` URIs (LSP).
    static func virtualizingFileURIs(host: String, in text: String) -> String {
        text.replacingOccurrences(of: "file:///", with: "file://\(root)/\(host)/")
    }

    /// Inbound: an absolute real path reported by a process on the same host
    /// as `anchor` becomes virtual; everything else is returned unchanged.
    static func virtualizing(_ path: String, like anchor: String) -> String {
        guard let host = split(anchor)?.host, path.hasPrefix("/"), split(path) == nil else { return path }
        return virtual(host: host, realPath: path)
    }
}

/// Strips this host's virtual paths from every ACP request and notification sent to a remote
/// agent. Frames come from JSONSerialization/JSONEncoder, which escape `/` as
/// `\/`, so both spellings are stripped rather than changing every encoder.
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
    private func strip(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains(".alas-remote"),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] == nil
        else { return data }
        let plain = RemotePath.stripping(host: host, in: text)
        return Data(plain.replacingOccurrences(
            of: "\\/.alas-remote\\/\(host)\\/", with: "\\/"
        ).utf8)
    }
}
