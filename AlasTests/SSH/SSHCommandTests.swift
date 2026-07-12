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

    @Test func remoteScriptChangesDirectoryInsidePOSIXShell() {
        let script = SSHCommand.remoteScript(cwd: "/srv/repo", command: "git status")
        #expect(script == "/bin/sh -c 'PATH=\"$HOME/.alas/bin:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"; export PATH; cd '\\''/srv/repo'\\'' && git status'")
    }

    @Test func remoteScriptQuotesCwdWithSpaces() {
        let script = SSHCommand.remoteScript(cwd: "/srv/my repo", command: "git status")
        #expect(script.contains("cd '\\''/srv/my repo'\\'' && git status"))
    }

    @Test func remoteScriptWithoutCwdOmitsCd() {
        let script = SSHCommand.remoteScript(command: "git --version")
        #expect(script == "/bin/sh -c 'PATH=\"$HOME/.alas/bin:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"; export PATH; git --version'")
    }

    @Test func remoteScriptTopLevelIsSafeForNonPOSIXLoginShells() {
        let script = SSHCommand.remoteScript(command: "f='x'; [ -e \"$f\" ]")
        #expect(script.hasPrefix("/bin/sh -c "))
        #expect(!script.hasPrefix("PATH="))
        #expect(!script.contains("\"$SHELL\" -l -c"))
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
