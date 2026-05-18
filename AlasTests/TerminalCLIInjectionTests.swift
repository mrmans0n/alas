import Testing
@testable import Alas

struct TerminalCLIInjectionTests {
    @Test func zshAndBashReceiveAlasFunction() {
        let zsh = TerminalCLIInjection.script(forShell: "/bin/zsh") ?? ""
        let bash = TerminalCLIInjection.script(forShell: "/opt/homebrew/bin/bash") ?? ""

        for script in [zsh, bash] {
            #expect(script.contains("alas()"))
            #expect(script.contains("ALAS_SOCKET_PATH"))
            #expect(script.contains("ALAS_SESSION_ID"))
            #expect(script.contains(#""kind": "cli""#))
            #expect(script.contains(#""command": "open""#))
            #expect(script.contains("os.path.abspath"))
            #expect(script.contains("/usr/bin/nc -U -w1"))
        }
    }

    @Test func unsupportedShellReceivesNoSnippet() {
        #expect(TerminalCLIInjection.script(forShell: "/opt/homebrew/bin/fish") == nil)
    }

    @Test func composePrependsInjectionBeforeUserScriptAndSuffix() {
        let composed = TerminalCLIInjection.compose(
            shell: "/bin/zsh",
            userStartupScript: "echo user",
            startupScriptSuffix: "echo agent"
        )

        #expect(composed.contains("alas()"))
        #expect(composed.range(of: "alas()")!.lowerBound < composed.range(of: "echo user")!.lowerBound)
        #expect(composed.range(of: "echo user")!.lowerBound < composed.range(of: "echo agent")!.lowerBound)
    }

    @Test func composeKeepsUnsupportedShellUserScriptOnly() {
        let composed = TerminalCLIInjection.compose(
            shell: "/opt/homebrew/bin/fish",
            userStartupScript: "echo user",
            startupScriptSuffix: nil
        )

        #expect(composed == "echo user")
    }
}
