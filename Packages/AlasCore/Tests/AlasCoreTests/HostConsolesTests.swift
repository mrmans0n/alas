import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

@MainActor
struct HostConsolesTests {
    @Test func hostShellNamesAreNeverAlasNames() {
        let name = ZmxSessionName.hostShell(worktreeId: "/srv/feature", consoleId: "c")
        #expect(name.hasPrefix("alashost-"))
        #expect(!ZmxSessionName.isAlasName(name)) // sweeps, Open Sessions, pre-freeze migration
        #expect(ZmxSessionName.parseScoped(name) == nil)
    }

    @Test func aShellLaunchesInTheWorktreeWithTheAgentsPath() throws {
        let zmx = ZmxClient(env: ZmxEnv(binaryURL: URL(fileURLWithPath: "/opt/zmx"), zmxDir: URL(fileURLWithPath: "/tmp/z")))
        let base = [
            "PATH": "/login/bin:/usr/bin", "TERM": "dumb", "TERM_PROGRAM": "Apple_Terminal",
            "ZMX_SESSION": "outer", "HOME": "/Users/u",
        ]
        let launch = try #require(HostShellLaunch.make(
            zmx: zmx, sessionName: "alashost-a-b", directory: URL(fileURLWithPath: "/srv/feature"),
            shell: "/bin/zsh", baseEnvironment: base
        ))
        #expect(launch.executable.path == "/opt/zmx")
        #expect(launch.arguments == ["attach", "alashost-a-b", "/bin/zsh", "-l"])
        #expect(launch.directory.path == "/srv/feature")
        #expect(launch.environment == [
            "PATH": "/login/bin:/usr/bin", "HOME": "/Users/u", "TERM": "xterm-256color",
            "COLORTERM": "truecolor", "ZMX_DIR": "/tmp/z",
        ])
    }

    @Test func zmxIsFoundBesideTheLinkedExecutableElseInTheApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hostconsoles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func executable(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
            return url
        }
        // Homebrew layout: root/bin/alas-host -> root/pkg/alas-host/alas-host, zmx in root/pkg/zmx/zmx.
        _ = try executable("pkg/alas-host/alas-host")
        let pkgZmx = try executable("pkg/zmx/zmx")
        let linked = root.appendingPathComponent("bin/alas-host")
        try fm.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linked.path, withDestinationPath: "../pkg/alas-host/alas-host")
        let bare = try executable("bare/alas-host/alas-host")
        let appZmx = try executable("app/zmx/zmx")
        let missing = root.appendingPathComponent("nowhere/zmx")

        #expect(HostShellLaunch.zmxBinary(executable: linked, fallback: missing)?.standardizedFileURL.path
            == pkgZmx.resolvingSymlinksInPath().path)
        #expect(HostShellLaunch.zmxBinary(executable: bare, fallback: appZmx) == appZmx)
        #expect(HostShellLaunch.zmxBinary(executable: bare, fallback: missing) == nil)
    }
}
