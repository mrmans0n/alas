import Testing
@testable import Alas

struct SSHCommandTests {
    @Test func shellQuoteWrapsPlainString() {
        #expect(SSHCommand.shellQuote("git status") == "'git status'")
    }

    @Test func shellQuoteEscapesEmbeddedSingleQuote() {
        #expect(SSHCommand.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func shellQuoteEmptyString() {
        #expect(SSHCommand.shellQuote("") == "''")
    }

    @Test func remoteScriptChangesDirectoryThenExecsLoginShell() {
        let script = SSHCommand.remoteScript(cwd: "/srv/repo", command: "git status")
        #expect(script == "cd -- '/srv/repo' && exec \"$SHELL\" -l -c 'git status'")
    }

    @Test func remoteScriptQuotesCwdWithSpaces() {
        let script = SSHCommand.remoteScript(cwd: "/srv/my repo", command: "git status")
        #expect(script.hasPrefix("cd -- '/srv/my repo' && "))
    }

    @Test func remoteScriptWithoutCwdOmitsCd() {
        let script = SSHCommand.remoteScript(command: "git --version")
        #expect(script == "exec \"$SHELL\" -l -c 'git --version'")
    }

    @Test func batchModeArgvFailsFastAndNeverPrompts() {
        let argv = SSHCommand(host: "devbox", mode: .batch).argv(remoteScript: "true")
        #expect(argv.contains("BatchMode=yes"))
        #expect(argv.contains("ConnectTimeout=10"))
        #expect(Array(argv.suffix(2)) == ["devbox", "true"])
    }

    @Test func interactiveArgvAllowsPrompts() {
        let argv = SSHCommand(host: "devbox", mode: .interactive).argv(remoteScript: "true")
        #expect(!argv.contains("BatchMode=yes"))
        #expect(argv.contains("ConnectTimeout=30"))
    }

    @Test func everyInvocationMultiplexesAndDetectsDeadPeers() {
        for mode in [SSHCommand.Mode.batch, .interactive] {
            let argv = SSHCommand(host: "devbox", mode: mode).argv(remoteScript: "true")
            #expect(argv.contains("ControlMaster=auto"))
            #expect(argv.contains("ControlPath=~/.ssh/alas-%C"))
            #expect(argv.contains("ControlPersist=10m"))
            #expect(argv.contains("ServerAliveInterval=5"))
            #expect(argv.contains("ServerAliveCountMax=3"))
        }
    }
}
