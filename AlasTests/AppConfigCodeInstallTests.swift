import Foundation
import Testing
@testable import Alas

@Suite("AppConfig install nudge fields")
struct AppConfigCodeInstallTests {
    @Test("defaults have empty dismissedInstallNudges and userDefinedRecipes")
    func defaultsEmpty() {
        #expect(AppConfig.defaults.code.dismissedInstallNudges == [])
        #expect(AppConfig.defaults.code.userDefinedRecipes == [:])
    }

    @Test("code defaults show line numbers")
    func defaultsShowLineNumbers() {
        #expect(AppConfig.defaults.code.showLineNumbers)
    }

    @Test("clone folder round trips")
    func cloneFolderRoundTrip() throws {
        var config = AppConfig.defaults
        config.repositoryCloneRootPath = "/tmp/repositories"

        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        #expect(decoded.repositoryCloneRootPath == "/tmp/repositories")
    }

    @Test("legacy config without these keys decodes with empty defaults")
    func legacyDecode() throws {
        // Minimal config omitting dismissedInstallNudges and userDefinedRecipes
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
          "harness": {"notifyOnFinish": true},
          "code": {"fontFamily": "SF Mono", "fontSize": 13, "languageServers": []}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.code.dismissedInstallNudges == [])
        #expect(cfg.code.userDefinedRecipes == [:])
        #expect(cfg.repositoryCloneRootPath == "")
    }

    @Test("legacy code config without showLineNumbers decodes as enabled")
    func legacyDecodeShowLineNumbersDefault() throws {
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
          "harness": {"notifyOnFinish": true},
          "code": {"fontFamily": "SF Mono", "fontSize": 13, "languageServers": []}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.code.showLineNumbers)
    }

    @Test("populated values round-trip")
    func roundTrip() throws {
        var cfg = AppConfig.defaults
        cfg.code.dismissedInstallNudges = ["rust", "go"]
        cfg.code.userDefinedRecipes = [
            "zig": [InstallRecipe(installer: .brew, package: "zls")]
        ]
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.code.dismissedInstallNudges == ["rust", "go"])
        #expect(decoded.code.userDefinedRecipes["zig"]?.first?.package == "zls")
        #expect(decoded.code.userDefinedRecipes["zig"]?.first?.installer == .brew)
    }

    @Test("explicit disabled line numbers round-trip")
    func lineNumbersDisabledRoundTrip() throws {
        var cfg = AppConfig.defaults
        cfg.code.showLineNumbers = false

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(!decoded.code.showLineNumbers)
    }

    @Test("Mason package prefill produces enabled language server config")
    func masonPrefillConfig() {
        let pkg = MasonPackage(
            masonId: "taplo",
            displayName: "taplo",
            languageId: "toml",
            languages: ["TOML"],
            extensions: ["toml"],
            command: "taplo",
            args: ["lsp", "stdio"],
            recipes: [InstallRecipe(installer: .brew, package: "taplo")]
        )

        let config = LanguageServerConfig.prefilled(from: pkg)

        #expect(config.language == "toml")
        #expect(config.extensions == ["toml"])
        #expect(config.command == "taplo")
        #expect(config.args == ["lsp", "stdio"])
        #expect(config.env == [:])
        #expect(config.rootMarkers == [".git"])
        #expect(config.enabled)
    }

    @Test("Mason package prefill falls back to mason id without language id")
    func masonPrefillFallsBackToMasonId() {
        let pkg = MasonPackage(
            masonId: "custom-lsp",
            displayName: "custom-lsp",
            languageId: "",
            languages: [],
            extensions: ["custom"],
            command: "custom-lsp",
            args: [],
            recipes: []
        )

        let config = LanguageServerConfig.prefilled(from: pkg)

        #expect(config.language == "custom-lsp")
    }

    @Test("code config upserts language server and stores recipes")
    func upsertLanguageServerStoresRecipes() {
        var code = AppConfig.defaults.code
        let config = LanguageServerConfig(
            language: " toml ",
            extensions: ["toml"],
            command: " taplo ",
            args: [" lsp ", " ", "stdio"],
            env: [:],
            rootMarkers: [" .git ", ""],
            enabled: true
        )
        let recipes = [InstallRecipe(installer: .brew, package: "taplo")]

        code.saveLanguageServerConfig(originalLanguage: nil, config, recipes: recipes)

        #expect(code.languageServers == [
            LanguageServerConfig(
                language: "toml",
                extensions: ["toml"],
                command: "taplo",
                args: ["lsp", "stdio"],
                env: [:],
                rootMarkers: [".git"],
                enabled: true
            )
        ])
        #expect(code.userDefinedRecipes["toml"] == recipes)
    }

    @Test("code config migrates recipes when language is renamed")
    func upsertLanguageServerMigratesRecipesOnRename() {
        var code = AppConfig.defaults.code
        code.languageServers = [
            LanguageServerConfig(
                language: "old",
                extensions: ["old"],
                command: "old-lsp",
                args: [],
                env: [:],
                rootMarkers: [".git"],
                enabled: true
            )
        ]
        code.userDefinedRecipes["old"] = [InstallRecipe(installer: .brew, package: "old-lsp")]

        let renamed = LanguageServerConfig(
            language: "new",
            extensions: ["new"],
            command: "new-lsp",
            args: [],
            env: [:],
            rootMarkers: [".git"],
            enabled: true
        )
        code.saveLanguageServerConfig(originalLanguage: "old", renamed, recipes: nil)

        #expect(code.languageServers.map(\.language) == ["new"])
        #expect(code.userDefinedRecipes["old"] == nil)
        #expect(code.userDefinedRecipes["new"] == [InstallRecipe(installer: .brew, package: "old-lsp")])
    }
}
