import Testing
import Foundation
@testable import Alas

struct PiInstallerTests {
    private func tmpExtensionURL() -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("alas-notify.ts", isDirectory: false)
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func defaultExtensionPathUsesPiExtensionsDirectory() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installer = PiInstaller(homeDirectoryURL: home)

        #expect(installer.extensionURL.path == home
            .appendingPathComponent(".pi/agent/extensions/alas-notify.ts")
            .path)
    }

    @Test func installWritesManagedExtensionAndCreatesParentDirectories() async throws {
        let (url, cleanup) = tmpExtensionURL()
        defer { cleanup() }
        let installer = PiInstaller(extensionURL: url)

        try await installer.install()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(installer.installState() == .installed)
    }

    @Test func extensionContentContainsRequiredHooksAndNotificationDetails() async throws {
        let (url, cleanup) = tmpExtensionURL()
        defer { cleanup() }
        let installer = PiInstaller(extensionURL: url)

        try await installer.install()

        let content = try String(contentsOf: url, encoding: .utf8)
        for required in [
            "alas-managed-pi-hook-v3",
            "export default function (pi)",
            "ALAS_SOCKET_PATH",
            "/usr/bin/nc",
            #"agent: "pi""#,
            #"envValue("ALAS_SESSION_ID") || ctx?.session_id"#,
            #"envValue("PI_SUBAGENT_CHILD") === "1""#,
            #"pi.events?.on?.("subagent:async-started""#,
            #"pi.events?.on?.("subagent:async-complete""#,
            "background_started",
            "background_ended",
            "activity_id",
            "lifecycle_id",
            "new Date().toISOString()",
            #"pi.on("session_start""#,
            #"pi.on("session_end""#,
            #"pi.on("before_agent_start""#,
            #"pi.on("tool_execution_end""#,
            #"pi.on("agent_end""#,
            #"pi.on("session_shutdown""#,
            "attached",
            "detached",
            "busy",
            "idle",
        ] {
            #expect(content.contains(required))
        }
        #expect(content.contains(#"session_shutdown: "detached""#))
        #expect(!content.contains(#"session_shutdown: "idle""#))
        #expect(!content.contains("export default {"))
        #expect(!content.contains(#"session_start: handle("session_start")"#))
    }

    @Test func installStateOutdatedForExistingUnmanagedExtension() throws {
        let (url, cleanup) = tmpExtensionURL()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default {};".write(to: url, atomically: true, encoding: .utf8)
        let installer = PiInstaller(extensionURL: url)

        #expect(installer.installState() == .outdated)
    }

    @Test(arguments: ["// alas-managed-pi-hook-v2\n", "// alas-managed-pi-hook\n"])
    func legacyManagedExtensionIsOutdatedAndCanBeUpgraded(marker: String) async throws {
        let (url, cleanup) = tmpExtensionURL()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(marker)export default function () {}\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let installer = PiInstaller(extensionURL: url)

        #expect(installer.installState() == .outdated)
        try await installer.install()

        #expect(installer.installState() == .installed)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("alas-managed-pi-hook-v3"))
    }

    @Test func installPreservesUnmanagedExtensionAndThrows() async throws {
        let (url, cleanup) = tmpExtensionURL()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unmanaged = "export default { name: 'custom' };"
        try unmanaged.write(to: url, atomically: true, encoding: .utf8)
        let installer = PiInstaller(extensionURL: url)

        await #expect(throws: PiInstallerError.self) {
            try await installer.install()
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == unmanaged)
        #expect(installer.installState() == .outdated)
    }

    @Test func uninstallRemovesManagedExtension() async throws {
        let (url, cleanup) = tmpExtensionURL()
        defer { cleanup() }
        let installer = PiInstaller(extensionURL: url)
        try await installer.install()

        try installer.uninstall()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(installer.installState() == .notInstalled)
    }

    @Test func uninstallPreservesUnmanagedExtension() throws {
        let (url, cleanup) = tmpExtensionURL()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unmanaged = "export default { name: 'custom' };"
        try unmanaged.write(to: url, atomically: true, encoding: .utf8)
        let installer = PiInstaller(extensionURL: url)

        try installer.uninstall()

        #expect(try String(contentsOf: url, encoding: .utf8) == unmanaged)
        #expect(installer.installState() == .outdated)
    }
}
