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

    /// Prompt text is stripped (the app writes worktree paths into it), but
    /// embedded resources are file contents and must arrive unchanged.
    @Test(arguments: ["/", #"\/"#])
    func outboundTransportStripsPathsButNotEmbeddedResourceContents(slash: String) throws {
        let inner = RecordingTransport()
        let transport = RemotePathStrippingTransport(host: "mini", inner: inner)
        let virtual = ["", ".alas-remote", "mini", "srv", "a.md"].joined(separator: slash)
        let prompt = #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"prompt":["#
            + #"{"type":"text","text":"Repository: \#(virtual)"},"#
            + #"{"type":"resource","resource":{"uri":"file://\#(virtual)","text":"see \#(virtual)","blob":"\#(virtual)"}}]}}"#
        try transport.send(Data(prompt.utf8))

        let frame = try #require(inner.sent.first)
        let sent = try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        let blocks = try #require((sent["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
        let resource = try #require(blocks[1]["resource"] as? [String: String])
        #expect(blocks[0]["text"] as? String == "Repository: /srv/a.md")
        #expect(resource["uri"] == "file:///srv/a.md")
        #expect(resource["text"] == "see /.alas-remote/mini/srv/a.md")
        #expect(resource["blob"] == "/.alas-remote/mini/srv/a.md")
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
