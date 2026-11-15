import Foundation
import Testing
@testable import AlasAgentKit
import AlasModel
import AlasPlatform

struct RemoteTerminalHookTests {
    @Test func generatedHookIdentifiesEachWriteAndProtectsOtherProducers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent("latest.json")
        let mailbox = URL(fileURLWithPath: "\(base.path).\(getpid())")
        let id = UUID().uuidString
        func run(_ state: ActivityEvent, otherProducer: Bool = false) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let hook = AlasHookCommand.compositeCommand(
                events: [state], agent: .claude, forwardStdinAsBody: false
            )
            process.arguments = otherProducer
                ? ["-c", #"/bin/sh -c "$1"; :"#, "fixture", hook]
                : ["-c", hook]
            process.environment = [
                "PATH": "/usr/bin:/bin", "ALAS_SESSION_ID": id, "ALAS_HOOK_EVENT_FILE": base.path,
            ]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        try run(.awaitingInput)
        let first = try String(contentsOf: mailbox, encoding: .utf8).split(separator: "\t", maxSplits: 1)
        try run(.awaitingInput)
        let next = try String(contentsOf: mailbox, encoding: .utf8).split(separator: "\t", maxSplits: 1)
        try #require(first.count == 2 && next.count == 2)
        #expect(first[0] != next[0])
        #expect(first[1] == next[1])
        let event = try AgentHookEvent.decode(from: Data(next[1].utf8))
        #expect(event.event == .awaitingInput)
        #expect(event.sessionId == id)

        try run(.backgroundStarted)
        try run(.idle, otherProducer: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 2)
        #expect(try String(contentsOf: mailbox, encoding: .utf8).split(separator: "\t", maxSplits: 1) == next)
        try run(.detached)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
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
