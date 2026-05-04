import Testing
import Foundation
@testable import Alas

/// Smoke tests for the AlasGhostty wrapper. They spin up the libghostty
/// runtime which hangs the test runner on headless macOS CI (no real
/// display) for many minutes during teardown. The whole suite is excluded
/// from CI via `-skip-testing AlasTests/AlasGhosttySmokeTests` in
/// `.github/workflows/build.yml`. Manual smoke (launch Alas.app) is the
/// real coverage for these code paths.
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

    @Test func canCreateAppFromGeneratedFile() throws {
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

    @Test func canCreateSurfaceView() throws {
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
