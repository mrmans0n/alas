import Testing
import Foundation
@testable import Alas

struct StartupScriptInstallerTests {
    @Test func emptyScriptIsLoginShell() throws {
        let plan = try StartupScriptInstaller.plan(
            shell: "/bin/zsh", startupScript: "", sessionId: "s-empty"
        )
        #expect(plan.executable == "/bin/zsh")
        #expect(plan.args == ["-l"])
        #expect(plan.envOverrides.isEmpty)
    }

    @Test func emptyScriptForBashAlsoLoginShell() throws {
        let plan = try StartupScriptInstaller.plan(
            shell: "/usr/local/bin/bash", startupScript: "   \n  ", sessionId: "s-empty-bash"
        )
        #expect(plan.executable == "/usr/local/bin/bash")
        #expect(plan.args == ["-l"])
    }

    @Test func zshUsesZdotdirNotRcfile() throws {
        let sid = "z-\(UUID().uuidString)"
        let plan = try StartupScriptInstaller.plan(
            shell: "/bin/zsh",
            startupScript: "echo hi from alas",
            sessionId: sid
        )
        #expect(plan.executable == "/bin/zsh")
        // zsh has no `--rcfile` flag — must NOT appear here.
        #expect(!plan.args.contains("--rcfile"))
        // Login + interactive — preserves $HOME/.zprofile semantics.
        #expect(plan.args == ["-l", "-i"])
        // ZDOTDIR must be set to a real directory containing `.zshrc`.
        let zdotdir = try #require(plan.envOverrides["ZDOTDIR"])
        let rcfile = URL(fileURLWithPath: zdotdir).appendingPathComponent(".zshrc")
        #expect(FileManager.default.fileExists(atPath: rcfile.path))
        let body = try String(contentsOf: rcfile, encoding: .utf8)
        // Sources the full user init chain.
        #expect(body.contains("source \"$HOME/.zshenv\""))
        #expect(body.contains("source \"$HOME/.zprofile\""))
        #expect(body.contains("source \"$HOME/.zshrc\""))
        #expect(body.contains("source \"$HOME/.zlogin\""))
        #expect(body.contains("echo hi from alas"))
    }

    @Test func bashUsesRcfile() throws {
        let sid = "b-\(UUID().uuidString)"
        let plan = try StartupScriptInstaller.plan(
            shell: "/bin/bash",
            startupScript: "alias ll='ls -la'",
            sessionId: sid
        )
        #expect(plan.executable == "/bin/bash")
        #expect(plan.args.contains("--rcfile"))
        // Bash silently ignores --rcfile in login mode, so we deliberately
        // omit -l here and let the rcfile source the login chain instead.
        #expect(!plan.args.contains("-l"))
        #expect(plan.args.contains("-i"))
        // No ZDOTDIR for bash.
        #expect(plan.envOverrides["ZDOTDIR"] == nil)
        // The rcfile path is in args after `--rcfile`.
        guard let idx = plan.args.firstIndex(of: "--rcfile") else {
            Issue.record("expected --rcfile arg")
            return
        }
        let rcPath = plan.args[idx + 1]
        let body = try String(contentsOf: URL(fileURLWithPath: rcPath), encoding: .utf8)
        // Sources the full user init chain.
        #expect(body.contains("source \"$HOME/.bash_profile\""))
        #expect(body.contains("source \"$HOME/.bashrc\""))
        #expect(body.contains("alias ll='ls -la'"))
    }

    @Test func unknownShellSkipsScriptGracefully() throws {
        let plan = try StartupScriptInstaller.plan(
            shell: "/usr/local/bin/fish",
            startupScript: "echo this would need fish-specific handling",
            sessionId: "f-test"
        )
        #expect(plan.executable == "/usr/local/bin/fish")
        // Fall back to login shell with no startup script handling.
        #expect(plan.args == ["-l"])
        #expect(plan.envOverrides.isEmpty)
    }

    @Test func supportsStartupScriptInjectionMatchesPlanBehavior() {
        #expect(StartupScriptInstaller.supportsStartupScriptInjection(shell: "/bin/zsh"))
        #expect(StartupScriptInstaller.supportsStartupScriptInjection(shell: "/bin/bash"))
        #expect(StartupScriptInstaller.supportsStartupScriptInjection(shell: "/usr/local/bin/bash"))
        #expect(!StartupScriptInstaller.supportsStartupScriptInjection(shell: "/usr/local/bin/fish"))
        #expect(!StartupScriptInstaller.supportsStartupScriptInjection(shell: "/usr/bin/nu"))
    }
}
