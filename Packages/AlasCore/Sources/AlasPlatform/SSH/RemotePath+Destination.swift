import Foundation
import AlasFoundation
import AlasModel

extension RemotePath {
    /// Resolve existing ancestors on the host without creating the destination.
    /// Git reports physical paths, so optimistic rows must use the same identity.
    public static func resolvedWorktreeDestination(
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
public final class RemotePathStrippingTransport: JSONRPCStdioTransporting, @unchecked Sendable {
    private let host: String
    private let inner: JSONRPCStdioTransporting

    public init(host: String, inner: JSONRPCStdioTransporting) {
        self.host = host
        self.inner = inner
    }

    public var incoming: AsyncStream<JSONRPCStdioTransport.Incoming> { inner.incoming }
    public var requestIDPrefix: String? { inner.requestIDPrefix }
    public func start() throws { try inner.start() }
    public func terminate() { inner.terminate() }
    public func send(_ data: Data) throws { try inner.send(strip(data)) }
    public func send(_ data: Data, onWritten: @escaping @Sendable () -> Void) throws {
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
