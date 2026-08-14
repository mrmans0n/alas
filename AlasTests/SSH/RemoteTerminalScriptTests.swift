import Testing
@testable import Alas

struct RemoteTerminalScriptTests {
    @Test func attachScriptResolvesZmxLadderAndAttaches() {
        let script = RemoteTerminalScript.attachScript(
            worktreePath: "/srv/repo", sessionName: "alas-aaaa-bbbb",
            useZmx: true, startupSuffix: nil
        )
        #expect(script.hasPrefix("cd '/srv/repo' || exit; "))
        #expect(script.contains("export ZMX_DIR=\"$HOME/.alas/zmx\""))
        #expect(script.contains("Z=\"$(command -v zmx 2>/dev/null || true)\""))
        #expect(script.contains("[ -x \"$HOME/.alas/bin/zmx\" ] && Z=\"$HOME/.alas/bin/zmx\""))
        #expect(script.contains("exec \"$Z\" attach 'alas-aaaa-bbbb' \"$SHELL\" -l"))
        #expect(script.contains("exec \"$SHELL\" -l"))
    }

    @Test func attachScriptWithoutZmxIsPlainLoginShell() {
        let script = RemoteTerminalScript.attachScript(
            worktreePath: "/srv/repo", sessionName: "alas-aaaa-bbbb",
            useZmx: false, startupSuffix: nil
        )
        #expect(!script.contains("zmx"))
        #expect(script.contains("exec \"$SHELL\" -l"))
    }

    @Test func startupSuffixRunsThenDropsToInteractiveShell() {
        let script = RemoteTerminalScript.attachScript(
            worktreePath: "/srv/repo", sessionName: "alas-aaaa-bbbb",
            useZmx: true, startupSuffix: "claude --continue"
        )
        #expect(script.contains("\"$SHELL\" -l -c 'claude --continue; exec \"$SHELL\" -l'"))
    }

    @Test func runCaptureStartupSuffixUsesPortableShell() {
        let script = RemoteTerminalScript.attachScript(
            worktreePath: "/srv/repo", sessionName: "alas-aaaa-bbbb",
            useZmx: false, startupSuffix: "__alas_run_script_capture() { :; }"
        )
        #expect(script.contains("exec /bin/sh -lc"))
        #expect(!script.contains("exec \"$SHELL\" -l -c"))
    }

    @Test func surfaceInvocationIsInteractiveWithForcedTTY() {
        let invocation = RemoteTerminalScript.surfaceInvocation(host: "devbox", script: "true")
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.args.first == "-tt")
        #expect(!invocation.args.contains("BatchMode=yes"))
        #expect(invocation.args.contains("ConnectTimeout=30"))
        #expect(invocation.args.dropLast().last == "devbox")
        #expect(invocation.args.last == SSHCommand.remoteScript(command: "true"))
    }

    @Test func zmxBatchCommandSharesDirAndLadder() {
        let command = RemoteTerminalScript.zmxBatchCommand(["ls", "--short"])
        #expect(command.contains("export ZMX_DIR=\"$HOME/.alas/zmx\""))
        #expect(command.contains("\"$Z\" 'ls' '--short'"))
        #expect(command.contains("command -v zmx"))
    }
}
