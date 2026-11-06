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

    /// A child can reach the cap before launch has marked it running, which only
    /// shows among many at once. Each must stop rather than block on a full pipe
    /// until its timeout.
    @Test(arguments: [false, true])
    func childrenReachingTheCapDuringLaunchAreStillStopped(capped: Bool) async {
        let timedOut = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    do {
                        if capped {
                            _ = try await Process.runCapped("/usr/bin/yes", args: [], maxOutputBytes: 64 * 1024, timeout: 15)
                        } else {
                            _ = try await Process.runData("/usr/bin/yes", args: [], timeout: 15, maxOutputBytes: 64 * 1024)
                        }
                        return false
                    } catch ProcessError.timedOut {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(timedOut == 0)
    }
}
