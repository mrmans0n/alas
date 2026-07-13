import Foundation
import Testing
@testable import Alas

struct RemoteHelperInstallerTests {
    private let resources = URL(fileURLWithPath: "/App/Resources")
    private let handshake = RemoteHelperHandshake(
        name: "alas-helper",
        protocolVersion: 1,
        binaryVersion: "0.1.0"
    )

    @Test func picksEverySupportedBinary() {
        #expect(RemoteHelperInstaller.bundledBinaryPath(
            os: .linux, arch: "x86_64", resourceURL: resources
        )?.path == "/App/Resources/alas-helper/linux-x86_64/alas-helper")
        #expect(RemoteHelperInstaller.bundledBinaryPath(
            os: .linux, arch: "aarch64", resourceURL: resources
        )?.path == "/App/Resources/alas-helper/linux-aarch64/alas-helper")
        #expect(RemoteHelperInstaller.bundledBinaryPath(
            os: .macos, arch: "x86_64", resourceURL: resources
        )?.path == "/App/Resources/alas-helper/macos-x86_64/alas-helper")
        #expect(RemoteHelperInstaller.bundledBinaryPath(
            os: .macos, arch: "aarch64", resourceURL: resources
        )?.path == "/App/Resources/alas-helper/macos-aarch64/alas-helper")
    }

    @Test func rejectsUnsupportedTargets() {
        #expect(RemoteHelperInstaller.bundledBinaryPath(
            os: .other, arch: "x86_64", resourceURL: resources
        ) == nil)
        #expect(RemoteHelperInstaller.bundledBinaryPath(
            os: .linux, arch: nil, resourceURL: resources
        ) == nil)
    }

    @Test func decodesHandshakeAndDetectsVersionSkew() {
        #expect(RemoteHelperHandshake.decode(
            #"{"name":"alas-helper","protocolVersion":1,"binaryVersion":"0.1.0"}"#
        ) == handshake)
        #expect(!RemoteHelperInstaller.needsInstall(remote: handshake, bundled: handshake))
        #expect(RemoteHelperInstaller.needsInstall(
            remote: RemoteHelperHandshake(
                name: "alas-helper",
                protocolVersion: 0,
                binaryVersion: "0.1.0"
            ),
            bundled: handshake
        ))
        #expect(RemoteHelperInstaller.needsInstall(remote: nil, bundled: handshake))
    }

    @Test func readsBundledManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let helperRoot = root.appendingPathComponent("alas-helper", isDirectory: true)
        try FileManager.default.createDirectory(at: helperRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"name":"alas-helper","protocolVersion":1,"binaryVersion":"0.1.0"}"#
            .write(to: helperRoot.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        #expect(RemoteHelperInstaller.bundledHandshake(resourceURL: root) == handshake)
    }
}
