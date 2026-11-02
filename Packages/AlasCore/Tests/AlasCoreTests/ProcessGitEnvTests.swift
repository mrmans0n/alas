import Foundation
import Testing
@testable import AlasPlatform

struct ProcessGitEnvTests {
    @Test(arguments: [
        (false, [String: String](), nil as String?, nil as String?, nil as String?),
        (true, [:], "0", "ssh -o BatchMode=yes", "never"),
        (true, ["GIT_SSH_COMMAND": "ssh -i key"], "0", "ssh -i key", "never"),
    ])
    func gitEnvNeverPromptsOnlyWhereAskedAndKeepsAConfiguredSSHCommand(
        neverPrompts: Bool, base: [String: String], prompt: String?, ssh: String?, credentialManager: String?
    ) {
        let env = Process.gitEnv(base: base, neverPrompts: neverPrompts)
        #expect(env["GIT_TERMINAL_PROMPT"] == prompt)
        #expect(env["GCM_INTERACTIVE"] == credentialManager)
        #expect(env["GIT_SSH_COMMAND"] == ssh)
    }

    /// A child writing past the cap is stopped while it writes: `yes` never ends on its own.
    @Test func runDataStopsAChildWritingPastItsCap() async {
        await #expect {
            _ = try await Process.runData("/usr/bin/yes", args: [], timeout: 60, maxOutputBytes: 64 * 1024)
        } throws: { error in
            if case ProcessError.outputTooLarge(maxBytes: 64 * 1024) = error { true } else { false }
        }
    }
}
