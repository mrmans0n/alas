import Testing
import Foundation
@testable import Alas

/// Smoke tests for the AlasGhostty wrapper. The Config-only test runs fine
/// in any environment (no libghostty runtime). The App + SurfaceView tests
/// spin up the libghostty runtime (`ghostty_app_new` registers
/// NSNotification observers, runloop hooks) and hang for >10min during
/// teardown on headless macOS runners (observed on macos-26 CI on commits
/// 1aef7bf, d3d7a3b). We skip those two via `.disabled` and rely on
/// manually launching `Alas.app` to exercise the full surface code path.
/// The `-skip-testing` xcodebuild flag isn't reliable for Swift-Testing
/// suite filtering, so we disable in-source.
@MainActor
struct AlasGhosttySmokeTests {
    @Test func canCreateConfigFromGeneratedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ghostty-test-\(UUID().uuidString).config")
        try """
        # smoke test config
        font-family = "JetBrains Mono"
        font-size = 13
        cursor-style = bar
        cursor-style-blink = true
        scrollback-limit = 10000
        bell-features = no-system,no-audio,attention,title,border
        background = #111D20
        foreground = #E3EDF1
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = try AlasGhostty.Config(filePath: url.path)
        // Just hold it briefly; deinit will free.
        _ = config
    }

    @Test(.disabled("hangs in headless CI — see file header"))
    func canCreateAppFromGeneratedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ghostty-test-\(UUID().uuidString).config")
        try """
        font-family = "JetBrains Mono"
        font-size = 13
        cursor-style = bar
        scrollback-limit = 10000
        background = #111D20
        foreground = #E3EDF1
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let app = try AlasGhostty.App(configPath: url.path)
        _ = app
    }

    @Test(.disabled("hangs in headless CI — see file header"))
    func canCreateSurfaceView() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ghostty-test-\(UUID().uuidString).config")
        try """
        font-family = "JetBrains Mono"
        font-size = 13
        scrollback-limit = 10000
        background = #111D20
        foreground = #E3EDF1
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let app = try AlasGhostty.App(configPath: url.path)
        var surfaceCfg = AlasGhostty.SurfaceConfiguration()
        surfaceCfg.workingDirectory = NSTemporaryDirectory()
        surfaceCfg.command = "/bin/zsh -l"
        surfaceCfg.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "ALAS_TEST": "yes",
        ]
        let view = AlasGhostty.SurfaceView(app: app, configuration: surfaceCfg)

        // ghostty_surface_new can fail in headless test contexts (no Metal device
        // attached to a real window). When that happens cSurface is nil; the
        // wrapper logs an error and returns the view in a degraded state. We just
        // confirm the wrapper itself didn't crash. Real surface creation is
        // exercised by the manual smoke test (the running app).
        _ = view
    }
}
