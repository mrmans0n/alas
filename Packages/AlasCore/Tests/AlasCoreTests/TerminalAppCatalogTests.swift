import Testing
import AlasAgentKit
import AlasModel

struct TerminalAppCatalogTests {
    @Test(arguments: [
        ("/opt/homebrew/bin/nvim", [], "neovim"),
        ("/usr/bin/python3.12", ["python3.12"], "python"),
        ("/bin/zsh", ["-zsh"], nil),
        ("/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"], "npm"),
        ("/opt/homebrew/bin/node", ["node", "/repo/node_modules/@angular/cli/bin/ng.js", "serve"], "angular"),
        ("/opt/homebrew/bin/node", ["node", "--inspect", "/repo/node_modules/vite/bin/vite.js"], "vite"),
        ("/opt/homebrew/bin/node", ["node", "server.js"], "node"),
        ("/usr/bin/python3", ["python3", "-m", "pytest", "-x"], "pytest"),
        ("/usr/bin/python3", ["python3", "manage.py", "runserver"], "django"),
        ("/usr/bin/java", ["java", "-classpath", "gradle-wrapper.jar", "org.gradle.wrapper.GradleWrapperMain", "build"], "gradle"),
        ("/usr/bin/java", ["java", "-jar", "app.jar"], "java"),
    ] as [(String, [String], String?)])
    func namesTheToolBehindTheForegroundExecutable(path: String, arguments: [String], expected: String?) {
        #expect(TerminalAppCatalog.app(forExecutablePath: path, arguments: arguments)?.id == expected)
    }

    @Test func agentsKeepTheirTitleWhileAppsTakeTheirNameAndDirectory() throws {
        let git = try #require(TerminalAppCatalog.app(forExecutablePath: "/opt/homebrew/bin/lazygit"))
        let agent = TerminalTabPresence.resolve(
            harness: .claudeCode, app: git, cwd: "/Users/me/repo", renamesTab: true, homeDirectory: "/Users/me")
        #expect(agent == TerminalTabPresence(badge: .agent(.claude), title: nil, subtitle: nil))

        let app = TerminalTabPresence.resolve(
            harness: nil, app: git, cwd: "/Users/me/.dotfiles", renamesTab: true, homeDirectory: "/Users/me")
        #expect(app == TerminalTabPresence(badge: .app(git), title: "Git Changes", subtitle: "~/.dotfiles"))

        let kept = TerminalTabPresence.resolve(
            harness: nil, app: git, cwd: "/Users/me/.dotfiles", renamesTab: false, homeDirectory: "/Users/me")
        #expect(kept == TerminalTabPresence(badge: .app(git), title: nil, subtitle: nil))
    }
}
