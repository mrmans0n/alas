import Testing
import Foundation
@testable import Alas

/// Smoke test for creating the libghostty app runtime. Whether
/// Ghostty accepts the config Alas writes is pinned in GhosttyConfigBuilderTests.
@MainActor
struct AlasGhosttySmokeTests {
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
}
