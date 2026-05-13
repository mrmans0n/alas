import Testing
import Foundation
@testable import Alas

struct CodexInstallerTests {
    private func tmpDir() -> (dir: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func installState_noFile_notInstalled() {
        let installer = CodexInstaller(
            hooksURL: URL(fileURLWithPath: "/nonexistent/hooks.json"),
            configURL: URL(fileURLWithPath: "/nonexistent/config.toml"),
            runEnableHooks: { .init(status: 0, stderr: "") }
        )
        #expect(installer.installState() == .notInstalled)
    }

    @Test func installRoundTrip() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let hooksURL = dir.appendingPathComponent("hooks.json")
        let configURL = dir.appendingPathComponent("config.toml")
        try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)

        var enableCalled = false
        let installer = CodexInstaller(
            hooksURL: hooksURL, configURL: configURL,
            runEnableHooks: { enableCalled = true
            return .init(status: 0, stderr: "") }
        )

        try await installer.install()
        #expect(enableCalled)
        #expect(installer.installState() == .installed)

        try installer.uninstall()
        #expect(installer.installState() == .notInstalled)
    }

    @Test func install_codexUnavailable_throws() async throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        let installer = CodexInstaller(
            hooksURL: dir.appendingPathComponent("hooks.json"),
            configURL: dir.appendingPathComponent("config.toml"),
            runEnableHooks: { .init(status: 127, stderr: "") }
        )

        await #expect(throws: CodexInstallerError.self) {
            try await installer.install()
        }
    }
}
