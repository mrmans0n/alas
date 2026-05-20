import Testing
import Foundation
@testable import Alas

struct OpenCodeInstallerTests {
    private func tmpPluginURL() -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("alas-notify.js", isDirectory: false)
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func defaultPluginPathUsesOpenCodePluginsDirectory() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installer = OpenCodeInstaller(homeDirectoryURL: home)

        #expect(installer.pluginURL.path == home
            .appendingPathComponent(".config/opencode/plugins/alas-notify.js")
            .path)
    }

    @Test func installWritesManagedPluginAndCreatesParentDirectories() async throws {
        let (url, cleanup) = tmpPluginURL()
        defer { cleanup() }
        let installer = OpenCodeInstaller(pluginURL: url)

        try await installer.install()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(installer.installState() == .installed)
    }

    @Test func pluginContentContainsRequiredHooksAndNotificationDetails() async throws {
        let (url, cleanup) = tmpPluginURL()
        defer { cleanup() }
        let installer = OpenCodeInstaller(pluginURL: url)

        try await installer.install()

        let content = try String(contentsOf: url, encoding: .utf8)
        for required in [
            "alas-managed-opencode-hook",
            "export const AlasNotifyPlugin = async () =>",
            "return {",
            "event: async ({ event }) =>",
            #"type === "permission.asked""#,
            #"notify("permission_request""#,
            "session.status",
            "session.idle",
            "ALAS_SOCKET_PATH",
            "node:child_process",
            "childProcess.spawn",
            "/usr/bin/nc",
            #"agent: "opencode""#,
            "attached",
            "detached",
            "busy",
            "idle",
            "permission_request",
        ] {
            #expect(content.contains(required))
        }
        #expect(!content.contains("export default"))
        #expect(!content.contains(#""permission.ask""#))
        #expect(!content.contains(#""permission.asked":"#))
        #expect(!content.contains(#""permission.asked": async"#))
    }

    @Test func pluginContentGuardsChildSessionsForAllRootActivityEvents() async throws {
        let (url, cleanup) = tmpPluginURL()
        defer { cleanup() }
        let installer = OpenCodeInstaller(pluginURL: url)

        try await installer.install()

        let content = try String(contentsOf: url, encoding: .utf8)
        for type in ["session.created", "session.deleted", "session.status", "session.idle", "session.error"] {
            #expect(content.contains(#"type === "\#(type)" && !isChildSession(event)"#))
        }
    }

    @Test func installStateOutdatedForExistingUnmanagedPlugin() throws {
        let (url, cleanup) = tmpPluginURL()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default {};".write(to: url, atomically: true, encoding: .utf8)
        let installer = OpenCodeInstaller(pluginURL: url)

        #expect(installer.installState() == .outdated)
    }

    @Test func installPreservesUnmanagedPluginAndThrows() async throws {
        let (url, cleanup) = tmpPluginURL()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unmanaged = "export const CustomPlugin = async () => ({ name: 'custom' });"
        try unmanaged.write(to: url, atomically: true, encoding: .utf8)
        let installer = OpenCodeInstaller(pluginURL: url)

        await #expect(throws: OpenCodeInstallerError.self) {
            try await installer.install()
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == unmanaged)
        #expect(installer.installState() == .outdated)
    }

    @Test func uninstallRemovesManagedPlugin() async throws {
        let (url, cleanup) = tmpPluginURL()
        defer { cleanup() }
        let installer = OpenCodeInstaller(pluginURL: url)
        try await installer.install()

        try installer.uninstall()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(installer.installState() == .notInstalled)
    }

    @Test func uninstallPreservesUnmanagedPlugin() throws {
        let (url, cleanup) = tmpPluginURL()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unmanaged = "export default { name: 'custom' };"
        try unmanaged.write(to: url, atomically: true, encoding: .utf8)
        let installer = OpenCodeInstaller(pluginURL: url)

        try installer.uninstall()

        #expect(try String(contentsOf: url, encoding: .utf8) == unmanaged)
        #expect(installer.installState() == .outdated)
    }
}
