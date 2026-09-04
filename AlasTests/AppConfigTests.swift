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
        #expect(cfg.sidebarMaterial == .appKitSidebar)
        #expect(cfg.sidebarWidth == 244)
        #expect(cfg.rightPaneWidth == 320)
        #expect(cfg.rightPaneVisible == true)
        #expect(cfg.sidebarVisible == true)
        #expect(cfg.collapsedProjectIds == [])
        #expect(cfg.terminal.shell == "/bin/zsh")
        #expect(cfg.harness.notifyOnFinish == true)
        #expect(cfg.harness.notifyOnAwaiting == true)
        #expect(cfg.worktrees.rootPath == "~/.alas/worktrees")
        #expect(cfg.worktrees.branchPrefix == "feature/")
        #expect(cfg.workspacesEnabled == false)
    }

    @Test func decodeOldConfigDefaultsWorkspacesDisabled() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "workspacesEnabled")

        let oldConfig = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: oldConfig)

        #expect(decoded.workspacesEnabled == false)
    }

    @Test func decodeOldHarnessConfigDefaultsAwaitingPingOn() throws {
        let json = """
        {
          "themeId": "cool-slate",
          "accent": "teal",
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
          "harness": {"notifyOnFinish": false}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.harness.notifyOnFinish == false)
        #expect(cfg.harness.notifyOnAwaiting == true)
        #expect(cfg.collapsedProjectIds == [])
    }

    @Test func collapsedProjectIdsRoundTripIndependently() throws {
        var cfg = AppConfig.defaults
        cfg.collapsedProjectIds = ["project-b", "project-a"]

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.collapsedProjectIds == ["project-b", "project-a"])
    }

    @Test func decodeOldConfigPreservesPreviousSidebarMaterial() throws {
        let json = """
        {
          "themeId": "cool-slate",
          "accent": "teal",
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
        #expect(cfg.sidebarMaterial == .appKitFullScreenUI)
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

    @Test func decodeOldConfigDefaultsRepoSelectorRecentsEmpty() throws {
        // A config blob that predates the repo-selector recents fields must
        // still decode, with both recents collections defaulting to empty.
        let json = """
        {
          "themeId": "cool-slate",
          "accent": "teal",
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
        #expect(cfg.recentProjectIds == [])
        #expect(cfg.recentWorktreeIdsByProject == [:])
    }

    @Test func decodeOldConfigDefaultsSidebarVisibleTrue() throws {
        let json = """
        {
          "themeId": "cool-slate",
          "accent": "teal",
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
          "harness": {"notifyOnFinish": true, "notifyOnAwaiting": true}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.sidebarVisible == true)
    }

    @Test func repoSelectorRecentsRoundTrip() throws {
        var cfg = AppConfig.defaults
        cfg.recentProjectIds = ["proj-a", "proj-b"]
        cfg.recentWorktreeIdsByProject = ["proj-a": ["wt-1", "wt-2"]]
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.recentProjectIds == ["proj-a", "proj-b"])
        #expect(decoded.recentWorktreeIdsByProject == ["proj-a": ["wt-1", "wt-2"]])
    }
}
