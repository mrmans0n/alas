// AlasTests/ZmxEnvTests.swift
import Foundation
import Testing
@testable import Alas

@Suite
struct ZmxEnvTests {
    /// Build a temp directory that looks like a macOS app bundle:
    ///   <bundle>/Contents/Resources/zmx/zmx
    /// Returns the bundle URL and a closure to delete it.
    private func makeFakeBundle(includeBinary: Bool, executable: Bool) throws -> (Bundle, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-zmxenv-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Contents/Resources/zmx")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if includeBinary {
            let binURL = resources.appendingPathComponent("zmx")
            try Data("#!/bin/sh\necho ok\n".utf8).write(to: binURL)
            if executable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: binURL.path
                )
            } else {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o644)],
                    ofItemAtPath: binURL.path
                )
            }
        }
        // Bundle(url:) requires the root to be a real bundle layout; this
        // satisfies it for `resourceURL` lookups.
        guard let bundle = Bundle(url: root) else {
            throw NSError(domain: "ZmxEnvTests", code: 1)
        }
        return (bundle, { try? FileManager.default.removeItem(at: root) })
    }

    @Test
    func resolveReportsAvailableWhenBinaryIsExecutable() throws {
        let (bundle, cleanup) = try makeFakeBundle(includeBinary: true, executable: true)
        defer { cleanup() }
        let env = ZmxEnv.resolve(bundle: bundle)
        #expect(env.isAvailable == true)
        #expect(env.binaryURL?.lastPathComponent == "zmx")
    }

    @Test
    func resolveReportsUnavailableWhenBinaryMissing() throws {
        let (bundle, cleanup) = try makeFakeBundle(includeBinary: false, executable: false)
        defer { cleanup() }
        let env = ZmxEnv.resolve(bundle: bundle)
        #expect(env.isAvailable == false)
        #expect(env.binaryURL == nil)
    }

    @Test
    func resolveReportsUnavailableWhenBinaryNotExecutable() throws {
        let (bundle, cleanup) = try makeFakeBundle(includeBinary: true, executable: false)
        defer { cleanup() }
        let env = ZmxEnv.resolve(bundle: bundle)
        #expect(env.isAvailable == false)
    }

    @Test
    func resolveReturnsCreatedZmxDirOnHappyPath() throws {
        // Default Caches dir under the test bundle's $HOME is user-private
        // and short → always resolves to a non-nil URL with the dir created.
        let (bundle, cleanup) = try makeFakeBundle(includeBinary: true, executable: true)
        defer { cleanup() }
        let env = ZmxEnv.resolve(bundle: bundle)
        let dir = try #require(env.zmxDir)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        #expect(exists && isDir.boolValue)
    }
}
