import Foundation

/// Restores real paths for a remote language server and re-virtualizes the
/// `file://` URIs it returns. Only URI fields are rewritten: document text,
/// edits, and hover content pass through untouched, or incremental sync and
/// completions would see a different document than the editor.
final class RemotePathLSPTransport: LSPTransporting, @unchecked Sendable {
    private let inner: LSPTransporting
    private let host: String
    let incoming: AsyncStream<LSPTransport.Incoming>

    /// `changes` is a WorkspaceEdit's map keyed by document URI.
    private static let uriKeys: Set<String> = [
        "uri", "targetUri", "rootUri", "rootPath", "oldUri", "newUri", "scopeUri", "changes",
    ]

    init(inner: LSPTransporting, host: String) {
        self.inner = inner
        self.host = host
        let source = inner.incoming
        incoming = AsyncStream { continuation in
            let task = Task {
                for await event in source {
                    if case .frame(let data) = event {
                        continuation.yield(.frame(Self.rewriting(data, marker: "file:///") { uri in
                            uri.hasPrefix("file:///") ? "file://" + RemotePath.virtual(host: host, realPath: String(uri.dropFirst(7))) : uri
                        }))
                    } else {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func start() throws { try inner.start() }
    func send(_ data: Data) throws {
        try inner.send(Self.rewriting(data, marker: RemotePath.root) { RemotePath.stripping(host: host, in: $0) })
    }

    func terminate() { inner.terminate() }

    /// Frames without `marker` skip the decode and go through byte-identical.
    private static func rewriting(_ data: Data, marker: String, _ uri: (String) -> String) -> Data {
        guard String(decoding: data, as: UTF8.self).contains(marker),
              let frame = try? JSONSerialization.jsonObject(with: data)
        else { return data }
        return RemotePath.rewritingJSONStrings(in: frame) { path, string in
            path.last.map(uriKeys.contains) == true ? uri(string) : string
        } ?? data
    }
}
