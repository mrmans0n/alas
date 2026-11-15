import Foundation
import Testing
@testable import AlasAgentKit
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

    @Test func mailboxEventsMustComeFromTheRegisteredForegroundGroup() throws {
        let id = UUID().uuidString
        let session = ZmxSessionInfo(name: "one", startDir: "/repo", pid: 100)
        let processes = """
        100 1 100 101 /bin/bash
        101 100 101 101 /usr/bin/claude
        102 100 102 101 /usr/bin/claude
        """
        for (pid, envelopeID, agent, matches) in [
            (101, id, "claude", true), (102, id, "claude", false),
            (101, "other", "claude", false), (101, id, "codex", false),
        ] {
            let event = """
            {"v":1,"event":"awaiting_input","agent":"\(agent)","session_id":"\(envelopeID)","pid":\(pid)}
            """
            let snapshot = RemoteTerminalHarness.snapshot(
                sessions: [session], processTable: processes,
                hookOutput: "\(id)\t\(event)", namesByID: [id: "one"]
            )
            #expect(snapshot.agents["one"] == .claudeCode)
            #expect((snapshot.hooks[id]?.event == .awaitingInput) == matches)
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
