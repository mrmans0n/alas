import Foundation
import Testing
@testable import AlasAgentKit
import AlasModel
import AlasPlatform

struct RemoteTerminalHookTests {
    @Test func generatedHookWritesAndReplacesRemoteMailbox() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = directory.appendingPathComponent("latest.json")
        let id = UUID().uuidString
        for state: ActivityEvent in [.awaitingInput, .idle] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", AlasHookCommand.compositeCommand(
                events: [state], agent: .claude, forwardStdinAsBody: false
            )]
            process.environment = [
                "PATH": "/usr/bin:/bin", "ALAS_SESSION_ID": id, "ALAS_HOOK_EVENT_FILE": mailbox.path,
            ]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let event = try AgentHookEvent.decode(from: Data(contentsOf: mailbox))
            #expect(event.event == state)
            #expect(event.sessionId == id)
        }
    }

    @Test func onlyPersistentSSHTerminalsExportMailboxEnvironment() {
        let id = UUID().uuidString
        let persistent = RemoteTerminalScript.attachScript(
            worktreePath: "/repo", sessionName: "alas-demo",
            useZmx: true, startupSuffix: nil, hookSessionID: id
        )
        let direct = RemoteTerminalScript.attachScript(
            worktreePath: "/repo", sessionName: "alas-demo",
            useZmx: false, startupSuffix: nil, hookSessionID: id
        )
        #expect(persistent.contains("ALAS_SESSION_ID='\(id)'"))
        #expect(persistent.contains("ALAS_HOOK_EVENT_FILE=\"$HOME/.alas/terminal-hooks/\(id).json\""))
        #expect(!persistent.contains("ALAS_SOCKET_PATH"))
        #expect(!direct.contains("ALAS_HOOK_EVENT_FILE"))
        #expect(RemoteTerminalScript.hookMailboxPath(sessionID: "../unsafe") == nil)
    }
}
