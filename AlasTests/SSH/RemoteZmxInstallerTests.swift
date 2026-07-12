import Foundation
import Testing
@testable import Alas

struct RemoteZmxInstallerTests {
    private let resources = URL(fileURLWithPath: "/App/Resources")

    @Test func picksLinuxBinariesByArch() {
        #expect(RemoteZmxInstaller.bundledBinaryPath(
            os: .linux, arch: "x86_64", resourceURL: resources
        )?.path == "/App/Resources/zmx/linux-x86_64/zmx")
        #expect(RemoteZmxInstaller.bundledBinaryPath(
            os: .linux, arch: "aarch64", resourceURL: resources
        )?.path == "/App/Resources/zmx/linux-aarch64/zmx")
    }

    @Test func unsupportedTargetsYieldNil() {
        #expect(RemoteZmxInstaller.bundledBinaryPath(
            os: .linux, arch: nil, resourceURL: resources
        ) == nil)
        #expect(RemoteZmxInstaller.bundledBinaryPath(
            os: .other, arch: "x86_64", resourceURL: resources
        ) == nil)
    }

    @Test func macRemoteRequiresMatchingLocalArch() {
        let other = RemoteZmxInstaller.localArch == "aarch64" ? "x86_64" : "aarch64"
        #expect(RemoteZmxInstaller.bundledBinaryPath(
            os: .macos, arch: other, resourceURL: resources
        ) == nil)
        #expect(RemoteZmxInstaller.bundledBinaryPath(
            os: .macos, arch: RemoteZmxInstaller.localArch, resourceURL: resources
        )?.path == "/App/Resources/zmx/zmx")
    }

    @Test func scpArgvUsesBatchOptionsAndQuietMode() {
        let args = SSHCommand.scpArgv(
            localPath: "/tmp/zmx", host: "devbox", remotePath: ".alas/bin/zmx.tmp"
        )
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains("-q"))
        #expect(Array(args.suffix(2)) == ["/tmp/zmx", "devbox:.alas/bin/zmx.tmp"])
    }
}
