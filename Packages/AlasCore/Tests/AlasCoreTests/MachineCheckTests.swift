import Foundation
import Testing
@testable import AlasCore
import AlasPlatform

struct MachineCheckTests {
    @Test(arguments: [
        ("~", #"mkdir -p "$HOME" && test -w "$HOME" && echo true"#),
        ("~/code", #"mkdir -p "$HOME"/'code' && test -w "$HOME"/'code' && echo true"#),
        ("~/My Code", #"mkdir -p "$HOME"/'My Code' && test -w "$HOME"/'My Code' && echo true"#),
        ("/srv/o'brien", #"mkdir -p '/srv/o'\''brien' && test -w '/srv/o'\''brien' && echo true"#),
    ])
    func tildeFolderExpandsOnTheMachine(folder: String, expected: String) {
        #expect(MachineCheck.folderCommand(folder) == expected)
    }

    struct Reply: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let expected: MachineCheckResult
    }

    @Test(arguments: [
        Reply(exitCode: 0, stdout: "true\n", stderr: "", expected: .ok),
        Reply(exitCode: 255, stdout: "", stderr: "Host key verification failed.",
              expected: .connectionFailed("Host key verification failed.")),
        Reply(exitCode: 1, stdout: "", stderr: "mkdir: Permission denied",
              expected: .folderUnusable("mkdir: Permission denied")),
        Reply(exitCode: 1, stdout: "", stderr: "",
              expected: .folderUnusable("Can't create or write to ~/code on mini.")),
    ])
    func runClassifiesExitCodes(reply: Reply) async {
        let result = await MachineCheck.run(host: "mini", projectsFolder: "~/code") { _, _, _ in
            ProcessResult(exitCode: reply.exitCode, stdout: reply.stdout, stderr: reply.stderr)
        }
        #expect(result == reply.expected)
    }

    @Test func runReportsALaunchFailureAsConnectionFailure() async {
        let result = await MachineCheck.run(host: "mini", projectsFolder: "~/code") { _, _, _ in
            throw CocoaError(.fileNoSuchFile)
        }
        guard case .connectionFailed = result else {
            Issue.record("expected connectionFailed, got \(result)")
            return
        }
    }
}
