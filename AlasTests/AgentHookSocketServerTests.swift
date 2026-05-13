import Testing
import Foundation
@testable import Alas

struct AgentHookSocketServerTests {
    private func tmpSocketDir() -> (dir: String, cleanup: () -> Void) {
        // Use /tmp directly: NSTemporaryDirectory() on macOS returns a path that
        // exceeds the 104-byte sun_path limit when combined with a UUID and filename.
        let dir = "/tmp/alas-test-\(UUID().uuidString)"
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

    @Test func wellFormedEnvelope_dispatchesEvent() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)

        var received: AgentHookEvent?
        server.onEvent = { event in received = event }

        let json = #"{"v":1,"event":"busy","agent":"claude","session_id":"s1","pid":123}"#
        let response = try sendToSocket(path: path, payload: json)
        try await Task.sleep(for: .milliseconds(200))

        #expect(response.contains("\"ok\":true") || response.contains("\"ok\": true"))
        #expect(received?.event == .busy)
        #expect(received?.agent == .claude)
        #expect(received?.sessionId == "s1")
        server.shutdown()
    }

    @Test func malformedJSON_returnsError() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        let response = try sendToSocket(path: path, payload: "not json")
        #expect(response.contains("\"ok\":false") || response.contains("\"ok\": false"))
    }

    @Test func unknownEvent_acksOkButDoesNotDispatch() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        var received: AgentHookEvent?
        server.onEvent = { event in received = event }

        let json = #"{"v":1,"event":"future_event","agent":"claude","session_id":"s1"}"#
        let response = try sendToSocket(path: path, payload: json)
        try await Task.sleep(for: .milliseconds(200))

        #expect(response.contains("\"ok\":true") || response.contains("\"ok\": true"))
        #expect(received == nil)
    }

    @Test func staleSocketSweep_removesDeadPidFiles() throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let stalePath = "\(dir)/pid-99999"
        FileManager.default.createFile(atPath: stalePath, contents: nil)
        #expect(FileManager.default.fileExists(atPath: stalePath))

        AgentHookSocketServer.sweepStaleSockets(in: dir)

        #expect(!FileManager.default.fileExists(atPath: stalePath))
    }

    @Test func shutdown_unlinksSocketFile() throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        #expect(FileManager.default.fileExists(atPath: path))

        server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
