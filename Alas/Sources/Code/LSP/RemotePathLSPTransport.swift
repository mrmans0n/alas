import Foundation

/// Restores real paths for a remote language server and re-virtualizes the
/// `file://` URIs it returns.
final class RemotePathLSPTransport: LSPTransporting, @unchecked Sendable {
    private let inner: LSPTransporting
    private let host: String
    let incoming: AsyncStream<LSPTransport.Incoming>

    init(inner: LSPTransporting, host: String) {
        self.inner = inner
        self.host = host
        let source = inner.incoming
        incoming = AsyncStream { continuation in
            let task = Task {
                for await event in source {
                    if case .frame(let data) = event {
                        let text = RemotePath.virtualizingFileURIs(host: host, in: String(decoding: data, as: UTF8.self))
                        continuation.yield(.frame(Data(text.utf8)))
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
        try inner.send(Data(RemotePath.stripping(host: host, in: String(decoding: data, as: UTF8.self)).utf8))
    }
    func terminate() { inner.terminate() }
}
