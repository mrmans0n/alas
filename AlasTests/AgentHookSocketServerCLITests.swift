import Foundation
import Testing
@testable import Alas

struct AgentHookSocketServerCLITests {
    private func tmpSocketDir() -> (dir: String, cleanup: () -> Void) {
        let dir = "/tmp/alas-cli-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(atPath: dir) })
    }

    private func sendToSocket(path: String, payload: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "printf '%s' '\(payload)' | /usr/bin/nc -U -w2 '\(path)'"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()
        process.waitUntilExit()
        return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @Test func cliRequestDispatchesAndReturnsOK() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        actor Holder {
            var request: AlasCLIRequest?
            func set(_ request: AlasCLIRequest) { self.request = request }
            func current() -> AlasCLIRequest? { request }
        }
        let holder = Holder()
        server.onCLIRequest = { request in
            await holder.set(request)
            return .ok
        }

        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        let response = try sendToSocket(path: path, payload: json)

        #expect(response.contains(#""ok":true"#) || response.contains(#""ok": true"#))
        let request = await holder.current()
        #expect(request?.sessionId == "s1")
        #expect(request?.paths == ["/tmp/a.txt"])
    }

    @Test func cliRequestReturnsHandlerError() throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        server.onCLIRequest = { _ in .error("Path does not exist.") }

        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/missing.txt"]}"#
        let response = try sendToSocket(path: path, payload: json)

        #expect(response.contains(#""ok":false"#) || response.contains(#""ok": false"#))
        #expect(response.contains("Path does not exist."))
    }

    @Test func cliRequestDoesNotDispatchHarnessEvent() throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        var harnessEventReceived = false
        server.onEvent = { _ in harnessEventReceived = true }
        server.onCLIRequest = { _ in .ok }

        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        _ = try sendToSocket(path: path, payload: json)

        #expect(!harnessEventReceived)
    }
}
