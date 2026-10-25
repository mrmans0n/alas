import Foundation
import Testing
@testable import AlasPlatform

struct ProcessGitEnvTests {
    @Test(arguments: [
        (false, [String: String](), nil as String?, nil as String?),
        (true, [:], "0", "ssh -o BatchMode=yes"),
        (true, ["GIT_SSH_COMMAND": "ssh -i key"], "0", "ssh -i key"),
    ])
    func gitEnvNeverPromptsOnlyWhereAskedAndKeepsAConfiguredSSHCommand(
        neverPrompts: Bool, base: [String: String], prompt: String?, ssh: String?
    ) {
        let env = Process.gitEnv(base: base, neverPrompts: neverPrompts)
        #expect(env["GIT_TERMINAL_PROMPT"] == prompt)
        #expect(env["GIT_SSH_COMMAND"] == ssh)
    }
}
