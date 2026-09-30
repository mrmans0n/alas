import Foundation
import Testing
@testable import Alas

struct RemoteHostRegistryTests {
    @Test(arguments: [
        ("/.alas-remote/mini.lan/Volumes/Workspace/alas/Sources/a.swift", "mini.lan"),
        ("/Volumes/Workspace/alas/Sources/a.swift", nil),
    ])
    func hostComesFromThePathItself(path: String, host: String?) {
        #expect(RemoteHostRegistry.shared.host(forPath: path) == host)
        #expect(URL(fileURLWithPath: path).isRemoteAlasPath == (host != nil))
    }

    @Test(arguments: [
        ("mini.lan", "/Volumes/Workspace/alas", "/.alas-remote/mini.lan/Volumes/Workspace/alas"),
        ("nacho@mini", "/srv/repo/sub", "/.alas-remote/nacho@mini/srv/repo/sub"),
    ])
    func virtualPathRoundTrips(host: String, real: String, virtual: String) throws {
        #expect(RemotePath.virtual(host: host, realPath: real) == virtual)
        let split = try #require(RemotePath.split(virtual))
        #expect(split.host == host)
        #expect(split.realPath == real)
        #expect(RemotePath.realPath(virtual) == real)
        #expect(RemotePath.display(virtual) == "\(host):\(real)")
        #expect(RemotePath.virtualizing(real, like: virtual) == virtual)
        #expect(RemotePath.virtualizing(virtual, like: virtual) == virtual)
        #expect(RemotePath.virtualizing(real, like: real) == real)
    }

    @Test(arguments: ["/Volumes/Workspace/alas", "/.alas-remote", "/.alas-remote/", "/.alas-remote/host"])
    func nonVirtualPathsPassThrough(path: String) {
        #expect(RemotePath.split(path) == nil)
        #expect(RemotePath.realPath(path) == path)
    }

    @Test func strippingOnlyTouchesTheExactHost() {
        let script = "cd '/.alas-remote/mini/a' && ls '/.alas-remote/mini.lan/b'"
        #expect(RemotePath.stripping(host: "mini", in: script) == "cd '/a' && ls '/.alas-remote/mini.lan/b'")
    }

    @Test func virtualizingFileURIsPrefixesEveryFileURI() {
        let json = #"{"uri":"file:///srv/a.swift","other":"file:///usr/include/x.h"}"#
        #expect(
            RemotePath.virtualizingFileURIs(host: "mini", in: json)
                == #"{"uri":"file:///.alas-remote/mini/srv/a.swift","other":"file:///.alas-remote/mini/usr/include/x.h"}"#
        )
    }

    @Test(arguments: [
        #"{"cwd":"/.alas-remote/mini/srv/repo","n":"/.alas-remote/mini.lan/x"}"#,
        #"{"cwd":"\/.alas-remote\/mini\/srv\/repo","n":"\/.alas-remote\/mini.lan\/x"}"#,
    ])
    func outboundTransportStripsPlainAndEscapedSlashes(payload: String) throws {
        let inner = RecordingTransport()
        let transport = RemotePathStrippingTransport(host: "mini", inner: inner)
        try transport.send(Data(payload.utf8))
        try transport.send(Data(payload.utf8), onWritten: {})
        let sent = inner.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.contains("mini.lan") && !$0.contains("alas-remote/mini/") && !$0.contains("alas-remote\\/mini\\/") })
    }

    @Test func outboundTransportLeavesSuccessResponsesByteIdentical() throws {
        let inner = RecordingTransport()
        let transport = RemotePathStrippingTransport(host: "mini", inner: inner)
        let response = Data(#"{"jsonrpc":"2.0","id":7,"result":{"content":"cd /.alas-remote/mini/srv"}}"#.utf8)
        try transport.send(response)
        #expect(inner.sent == [response])
    }
}

private final class RecordingTransport: JSONRPCStdioTransporting, @unchecked Sendable {
    let incoming = AsyncStream<JSONRPCStdioTransport.Incoming> { _ in }
    private(set) var sent: [Data] = []
    func start() throws {}
    func send(_ data: Data) throws { sent.append(data) }
    func terminate() {}
}
