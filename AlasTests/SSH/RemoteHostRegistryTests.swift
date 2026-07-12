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
}
