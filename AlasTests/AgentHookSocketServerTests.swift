import Darwin
import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct AgentHookSocketServerTests {
    private func tmpSocketDir() -> (dir: String, cleanup: () -> Void) {
        // Use /tmp directly: NSTemporaryDirectory() on macOS returns a path that
        // exceeds the 104-byte sun_path limit when combined with a UUID and filename.
        let dir = "/tmp/alas-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(atPath: dir) })
    }

    /// Run `trigger`, then wait for the first event delivered to `server.onEvent`
    /// (or for `timeoutMs` to elapse). Avoids `Task.sleep`-then-read races: the
    /// dispatched-to-main handler may run after a fixed sleep under load.
    private func awaitEvent<T>(
        on server: AgentHookSocketServer,
        timeoutMs: UInt64,
        _ trigger: () throws -> T
    ) async throws -> (T, AgentHookEvent?) {
        let holder = EventHolder()
        server.onEvent = { event in holder.deliver(event) }
        let triggerResult = try trigger()
        let received = await holder.wait(timeoutMs: timeoutMs)
        return (triggerResult, received)
    }

    private func sendToSocket(path: String, payload: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "printf '%s' '\(payload)' | /usr/bin/nc -U -w5 '\(path)'"]
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
        defer { server.shutdown() }

        let json = #"{"v":1,"event":"busy","agent":"claude","session_id":"s1","pid":123}"#
        let (response, received) = try await awaitEvent(on: server, timeoutMs: 5000) {
            try sendToSocket(path: path, payload: json)
        }

        #expect(response.contains("\"ok\":true") || response.contains("\"ok\": true"))
        #expect(received?.event == .busy)
        #expect(received?.agent == .claude)
        #expect(received?.sessionId == "s1")
    }

    @Test func aliasEnvelope_dispatchesMappedEvent() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        let json = #"{"v":1,"event":"SessionStart","agent":"claude","session_id":"s1","pid":123}"#
        let (response, received) = try await awaitEvent(on: server, timeoutMs: 5000) {
            try sendToSocket(path: path, payload: json)
        }

        #expect(response.contains("\"ok\":true") || response.contains("\"ok\": true"))
        #expect(received?.event == .attached)
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

    @Test func oversizedPid_decodesAsNil() throws {
        let json = #"{"v":1,"event":"busy","agent":"claude","session_id":"s1","pid":999999999999}"#

        let event = try AgentHookEvent.decode(from: Data(json.utf8))

        #expect(event.pid == nil)
    }

    @Test func unknownEvent_acksOkButDoesNotDispatch() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        let json = #"{"v":1,"event":"future_event","agent":"claude","session_id":"s1"}"#
        // Short timeout: we're asserting no event ever fires.
        let (response, received) = try await awaitEvent(on: server, timeoutMs: 300) {
            try sendToSocket(path: path, payload: json)
        }

        #expect(response.contains("\"ok\":true") || response.contains("\"ok\": true"))
        #expect(received == nil)
    }

    /// Codex review (#102): `/tmp/alas-<uid>` is a predictable path. If
    /// another local user pre-creates it with permissive bits before our
    /// first launch, we must refuse to use it instead of binding our
    /// `pid-<pid>` socket there (where the attacker could connect and spoof
    /// hook envelopes).
    @Test func prepareSocketDirectory_rejectsInsecurePerms() throws {
        let dir = "/tmp/alas-test-insecure-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = chmod(dir, 0o777)

        #expect(AgentHookSocketServer.prepareSocketDirectory(dir, ownerUid: getuid()) == false)
    }

    @Test func prepareSocketDirectory_rejectsWrongOwner() throws {
        let dir = "/tmp/alas-test-wrong-owner-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = chmod(dir, 0o700)

        #expect(AgentHookSocketServer.prepareSocketDirectory(dir, ownerUid: 0xDEAD) == false)
    }

    @Test func prepareSocketDirectory_acceptsFreshDirectory() throws {
        let dir = "/tmp/alas-test-fresh-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(AgentHookSocketServer.prepareSocketDirectory(dir, ownerUid: getuid()) == true)
        var st = Darwin.stat()
        #expect(Darwin.lstat(dir, &st) == 0)
        #expect((st.st_mode & 0o777) == 0o700)
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

    @Test func configureClientSocket_enablesNoSigPipe() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            Issue.record("socketpair failed")
            return
        }
        defer {
            close(fds[0])
            close(fds[1])
        }

        AgentHookSocketServer.configureClientSocket(fds[0])

        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = getsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &value, &length)

        #expect(result == 0)
        #expect(value == 1)
    }
}
