import Foundation
import Testing
@testable import Alas

struct GhosttyConfigBuilderTests {
    @Test func mapsCursorStyle() {
        #expect(GhosttyConfigBuilder.mapCursorStyle("block")     == .block)
        #expect(GhosttyConfigBuilder.mapCursorStyle("beam")      == .beam)
        #expect(GhosttyConfigBuilder.mapCursorStyle("underline") == .underline)
        #expect(GhosttyConfigBuilder.mapCursorStyle("???")       == .beam)
    }

    @Test func mapsToGhosttyCursorStyleString() {
        #expect(GhosttyConfigBuilder.ghosttyCursorStyleString("block")     == "block")
        #expect(GhosttyConfigBuilder.ghosttyCursorStyleString("beam")      == "bar")
        #expect(GhosttyConfigBuilder.ghosttyCursorStyleString("underline") == "underline")
    }

    @Test func posixQuoteLeavesSafeStringsBare() {
        #expect(GhosttyConfigBuilder.posixQuote("/bin/zsh") == "/bin/zsh")
        #expect(GhosttyConfigBuilder.posixQuote("--rcfile") == "--rcfile")
        #expect(GhosttyConfigBuilder.posixQuote("-i") == "-i")
        #expect(GhosttyConfigBuilder.posixQuote("UTF-8") == "UTF-8")
    }

    @Test func posixQuoteWrapsPathsWithSpaces() {
        // The common offender: ~/Library/Application Support/...
        let path = "/Users/me/Library/Application Support/Alas/rcfiles/abc.bashrc"
        #expect(
            GhosttyConfigBuilder.posixQuote(path)
                == "'/Users/me/Library/Application Support/Alas/rcfiles/abc.bashrc'"
        )
    }

    @Test func posixQuoteEscapesEmbeddedSingleQuotes() {
        // Standard shell trick: '...'\''...'
        #expect(GhosttyConfigBuilder.posixQuote("it's a path") == "'it'\\''s a path'")
    }

    @Test func posixQuoteEmptyStringIsEmptyQuotes() {
        #expect(GhosttyConfigBuilder.posixQuote("") == "''")
    }

    @Test @MainActor func writeGlobalConfigEmitsKeybindUnbinds() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = AppConfig.defaults.terminal
        let theme = try Theme.loadBundled(id: "cool-slate")
        try GhosttyConfigBuilder.writeGlobalConfigFile(cfg: cfg, theme: theme, to: url)
        let body = try String(contentsOf: url, encoding: .utf8)

        let expected = [
            "keybind = cmd+d=unbind",
            "keybind = cmd+shift+d=unbind",
            "keybind = cmd+w=unbind",
            "keybind = cmd+alt+left=unbind",
            "keybind = cmd+alt+right=unbind",
            "keybind = cmd+alt+up=unbind",
            "keybind = cmd+alt+down=unbind",
            "keybind = cmd+ctrl+left=unbind",
            "keybind = cmd+ctrl+right=unbind",
            "keybind = cmd+ctrl+up=unbind",
            "keybind = cmd+ctrl+down=unbind",
        ]
        for line in expected {
            #expect(body.contains(line), "config missing line: \(line)")
        }
    }

    @Test @MainActor func writeGlobalConfigDisablesShellIntegration() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty-config-shell-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = AppConfig.defaults.terminal
        let theme = try Theme.loadBundled(id: "cool-slate")
        try GhosttyConfigBuilder.writeGlobalConfigFile(cfg: cfg, theme: theme, to: url)
        let body = try String(contentsOf: url, encoding: .utf8)

        #expect(body.contains("shell-integration = none"))
    }

    @Test @MainActor func surfaceConfigurationEmitsEmptyZmxSessionOverride() {
        let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
        let worktree = Worktree(
            id: "w", projectId: "p", name: "m", branch: "m",
            path: URL(fileURLWithPath: "/wt"),
            status: .clean, lastActivity: Date()
        )
        let env = EnvBuilder.build(
            project: project,
            worktree: worktree,
            sessionId: "s",
            socketPath: nil,
            inheritParent: true,
            parent: ["ZMX_SESSION": "alas-parent"]
        )
        let config = GhosttyConfigBuilder.makeSurfaceConfiguration(
            cwd: worktree.path,
            env: env,
            executable: "/bin/zsh",
            args: ["-l"]
        )

        config.withCValue(nsView: NSObject(), userdata: nil) { cConfig in
            let variables = UnsafeBufferPointer(
                start: cConfig.env_vars,
                count: cConfig.env_var_count
            )
            let emitted = Dictionary(uniqueKeysWithValues: variables.map {
                (String(cString: $0.key), String(cString: $0.value))
            })
            #expect(emitted["ZMX_SESSION"] == "")
        }
    }

    @Test @MainActor func remoteSurfaceConfigurationDoesNotEmitZmxSessionOverride() {
        let project = ProjectConfig(
            id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date(), host: "devbox"
        )
        let worktree = Worktree(
            id: "w", projectId: "p", name: "m", branch: "m",
            path: URL(fileURLWithPath: "/wt"),
            status: .clean, lastActivity: Date()
        )
        let env = EnvBuilder.build(
            project: project,
            worktree: worktree,
            sessionId: "s",
            socketPath: nil,
            inheritParent: true,
            parent: ["ZMX_SESSION": "alas-parent"]
        )
        let config = GhosttyConfigBuilder.makeSurfaceConfiguration(
            cwd: worktree.path,
            env: env,
            executable: "/usr/bin/ssh",
            args: ["-tt", "devbox"]
        )

        config.withCValue(nsView: NSObject(), userdata: nil) { cConfig in
            let variables = UnsafeBufferPointer(
                start: cConfig.env_vars,
                count: cConfig.env_var_count
            )
            let emitted = Dictionary(uniqueKeysWithValues: variables.map {
                (String(cString: $0.key), String(cString: $0.value))
            })
            #expect(emitted["ZMX_SESSION"] == nil)
        }
    }
}
