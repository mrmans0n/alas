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
        #expect(cfg.worktrees.rootPath == "~/.alas/worktrees")
        #expect(cfg.worktrees.branchPrefix == "feature/")
    }

    @Test func decodePreservesConfiguredWorktreeRoot() throws {
        var cfg = AppConfig.defaults
        cfg.worktrees.rootPath = "~/code/worktrees"

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.worktrees.rootPath == "~/code/worktrees")
    }

    @Test func warmAmberMigratesToCoolSlate() throws {
        let json = """
        {
          "themeId": "warm-amber",
          "accent": "teal",
          "density": "comfortable",
          "matchSystemTheme": false,
          "sidebarWidth": 244,
          "rightPaneWidth": 320,
          "rightPaneVisible": true,
          "general": {
            "launchAtLogin": false, "closeToTray": true, "confirmQuit": true,
            "autoUpdate": true, "updateChannel": "Stable",
            "crashReports": false, "usageAnalytics": false
          },
          "worktrees": {
            "rootPath": "~/code/.worktrees",
            "pathTemplate": "{worktreeRoot}/{repo}/{branch}",
            "branchPrefix": "feature/", "baseBranch": "main",
            "trackUpstream": true, "deleteBranchOnRemove": true,
            "autoFetch": true, "fetchIntervalMinutes": 5, "pruneStale": false
          },
          "terminal": {
            "shell": "/bin/zsh", "workingDirectory": "worktreeRoot",
            "startupScript": "", "worktreeCreateScript": "",
            "inheritParentEnv": true, "fontFamily": "JetBrains Mono",
            "fontSize": 13, "cursorStyle": "beam", "cursorBlink": true,
            "scrollbackLines": 10000, "bell": "visual"
          },
          "harness": {"notifyOnFinish": true}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.themeId == "cool-slate")
    }

    @Test func neutralMigratesToCoolSlate() throws {
        let json = """
        {
          "themeId": "neutral",
          "accent": "teal",
          "density": "comfortable",
          "matchSystemTheme": false,
          "sidebarWidth": 244,
          "rightPaneWidth": 320,
          "rightPaneVisible": true,
          "general": {
            "launchAtLogin": false, "closeToTray": true, "confirmQuit": true,
            "autoUpdate": true, "updateChannel": "Stable",
            "crashReports": false, "usageAnalytics": false
          },
          "worktrees": {
            "rootPath": "~/code/.worktrees",
            "pathTemplate": "{worktreeRoot}/{repo}/{branch}",
            "branchPrefix": "feature/", "baseBranch": "main",
            "trackUpstream": true, "deleteBranchOnRemove": true,
            "autoFetch": true, "fetchIntervalMinutes": 5, "pruneStale": false
          },
          "terminal": {
            "shell": "/bin/zsh", "workingDirectory": "worktreeRoot",
            "startupScript": "", "worktreeCreateScript": "",
            "inheritParentEnv": true, "fontFamily": "JetBrains Mono",
            "fontSize": 13, "cursorStyle": "beam", "cursorBlink": true,
            "scrollbackLines": 10000, "bell": "visual"
          },
          "harness": {"notifyOnFinish": true}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.themeId == "cool-slate")
    }

    @Test func coolSlateAndLightDecodeUnchanged() throws {
        var cfg = AppConfig.defaults
        cfg.themeId = "light"
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.themeId == "light")

        cfg.themeId = "cool-slate"
        let data2 = try JSONEncoder().encode(cfg)
        let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
        #expect(decoded2.themeId == "cool-slate")
    }
}
