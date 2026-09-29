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
}
