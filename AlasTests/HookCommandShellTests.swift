import Testing
import Foundation
@testable import Alas

struct HookCommandShellTests {
    private func withTestSocket(_ body: (String, AgentHookSocketServer) async throws -> Void) async throws {
        let dir = "/tmp/alas-shell-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }
        try await body(path, server)
    }

    private func runBash(command: String, socketPath: String, sessionId: String, stdin: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["ALAS_SOCKET_PATH"] = socketPath
        env["ALAS_SESSION_ID"] = sessionId
        process.environment = env
        if let stdin {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
            pipe.fileHandleForWriting.closeFile()
            process.standardInput = pipe
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test func claudeBusyCommand_sendsValidEvent() async throws {
        try await withTestSocket { path, server in
            let holder = EventHolder()
            server.onEvent = { holder.deliver($0) }

            let cmd = AlasHookCommand.compositeCommand(events: [.busy], agent: .claude, forwardStdinAsBody: false)
            try runBash(command: cmd, socketPath: path, sessionId: "test-session")
            let received = await holder.wait(timeoutMs: 3000)

            #expect(received?.event == .busy)
            #expect(received?.agent == .claude)
            #expect(received?.sessionId == "test-session")
        }
    }

    @Test func codexIdleCommand_extractsBody() async throws {
        try await withTestSocket { path, server in
            let holder = EventHolder()
            server.onEvent = { holder.deliver($0) }

            let cmd = AlasHookCommand.compositeCommand(events: [.idle], agent: .codex, forwardStdinAsBody: true)
            let stdinPayload = #"{"message": "All done with the refactor"}"#
            try runBash(command: cmd, socketPath: path, sessionId: "test-session", stdin: stdinPayload)
            // Composite-with-body sends two envelopes: one without body, then the
            // body-bearing one. Wait for the body-bearing event specifically.
            let received = await holder.wait(timeoutMs: 3000) { $0.body != nil }

            #expect(received?.event == .idle)
            #expect(received?.agent == .codex)
            #expect(received?.body == "All done with the refactor")
        }
    }

    @Test func cursorAwaitingCommand_extractsBody() async throws {
        try await withTestSocket { path, server in
            let holder = EventHolder()
            server.onEvent = { holder.deliver($0) }

            let cmd = AlasHookCommand.compositeCommand(events: [.awaitingInput], agent: .cursor, forwardStdinAsBody: true)
            let stdinPayload = #"{"assistant_response": "Should I proceed?"}"#
            try runBash(command: cmd, socketPath: path, sessionId: "test-session", stdin: stdinPayload)
            let received = await holder.wait(timeoutMs: 3000) { $0.body != nil }

            #expect(received?.event == .awaitingInput)
            #expect(received?.agent == .cursor)
            #expect(received?.body == "Should I proceed?")
        }
    }

    @Test func commandWithoutEnvVars_exitsSilently() throws {
        let cmd = AlasHookCommand.compositeCommand(events: [.busy], agent: .claude, forwardStdinAsBody: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]
        process.environment = [:]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
