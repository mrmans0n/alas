import Foundation
import Testing
@testable import Alas

struct RemoteHostRegistryTests {
    private func makeRegistry() -> RemoteHostRegistry {
        let registry = RemoteHostRegistry()
        registry.register(root: "/srv/repo", host: "devbox")
        return registry
    }

    @Test func exactRootMatches() {
        #expect(makeRegistry().host(forPath: "/srv/repo") == "devbox")
    }

    @Test func trailingSlashOnRootIsNormalized() {
        let registry = RemoteHostRegistry()
        registry.register(root: "/srv/repo/", host: "devbox")
        #expect(registry.host(forPath: "/srv/repo") == "devbox")
    }

    @Test func nestedPathMatches() {
        #expect(makeRegistry().host(forPath: "/srv/repo/src/main.swift") == "devbox")
    }

    @Test func siblingWithSharedPrefixDoesNotMatch() {
        #expect(makeRegistry().host(forPath: "/srv/repo-other") == nil)
    }

    @Test func unregisteredPathReturnsNil() {
        #expect(makeRegistry().host(forPath: "/Users/nacho/local") == nil)
        #expect(makeRegistry().host(forPath: nil) == nil)
    }

    @Test func longestRootWins() {
        let registry = makeRegistry()
        registry.register(root: "/srv/repo/vendored", host: "otherbox")
        #expect(registry.host(forPath: "/srv/repo/vendored/lib.c") == "otherbox")
        #expect(registry.host(forPath: "/srv/repo/src.c") == "devbox")
    }

    @Test func unregisterRemovesRoot() {
        let registry = makeRegistry()
        registry.unregister(root: "/srv/repo")
        #expect(registry.host(forPath: "/srv/repo") == nil)
    }

    @Test func urlConvenienceReflectsSharedRegistry() {
        RemoteHostRegistry.shared.register(root: "/srv/only-in-test", host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: "/srv/only-in-test") }
        #expect(URL(fileURLWithPath: "/srv/only-in-test/a.txt").isRemoteAlasPath)
        #expect(!URL(fileURLWithPath: "/tmp").isRemoteAlasPath)
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
