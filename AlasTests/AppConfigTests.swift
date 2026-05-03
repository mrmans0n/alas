import Testing
import Foundation
@testable import Alas

struct AppConfigTests {
    @Test func defaultConfigEncodesAndDecodes() throws {
        let cfg = AppConfig.defaults
        let store = PersistenceStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.write(cfg, to: url)
        let read: AppConfig = try store.read(AppConfig.self, from: url)
        #expect(read == cfg)
    }

    @Test func defaultsMatchSpec() {
        let cfg = AppConfig.defaults
        #expect(cfg.themeId == "cool-slate")
        #expect(cfg.accent == "teal")
        #expect(cfg.sidebarWidth == 244)
        #expect(cfg.rightPaneWidth == 320)
        #expect(cfg.rightPaneVisible == true)
        #expect(cfg.terminal.shell == "/bin/zsh")
        #expect(cfg.harness.notifyOnFinish == true)
        #expect(cfg.worktrees.branchPrefix == "feature/")
    }
}
