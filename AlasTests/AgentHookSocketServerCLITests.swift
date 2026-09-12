import Darwin
import Dispatch
import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct AgentHookSocketServerCLITests {
    private actor Gate {
        private var waitContinuation: CheckedContinuation<Void, Never>?
        private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
        private var entered = false
        private var released = false
        func wait() async {
            entered = true
            enteredContinuations.forEach { $0.resume() }
            enteredContinuations.removeAll()
            if released { return }
            await withCheckedContinuation { waitContinuation = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredContinuations.append($0) }
        }
        func release() {
            released = true
            waitContinuation?.resume()
            waitContinuation = nil
        }
    }

    private func tmpSocketDir() -> (dir: String, cleanup: () -> Void) {
        let dir = "/tmp/alas-cli-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(atPath: dir) })
    }

    private static func sendToSocket(path: String, payload: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try sendToSocketDirect(path: path, payload: payload)
                })
            }
        }
    }

    private static func sendToSocketDirect(path: String, payload: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            let result = withUnsafePointer(to: &timeout) { pointer in
                Darwin.setsockopt(
                    fd,
                    SOL_SOCKET,
                    option,
                    pointer,
                    socklen_t(MemoryLayout<timeval>.size))
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= sunPathSize else { throw POSIXError(.ENAMETOOLONG) }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { buf in
                memcpy(sunPath, buf.baseAddress!, buf.count)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(fd, raw, addrLen)
            }
        }
        guard connectResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        try writeAll(fd: fd, data: Data(payload.utf8))
        shutdown(fd, SHUT_WR)
        return try readAll(fd: fd)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if result == 0 { throw POSIXError(.EPIPE) }
                written += result
            }
        }
    }

    private static func readAll(fd: Int32) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func responseObject(_ response: String) throws -> [String: Any] {
        let data = try #require(response.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
        let response = try await Self.sendToSocket(path: path, payload: json)
        let object = try responseObject(response)

        #expect(object["ok"] as? Bool == true)
        let request = await holder.current()
        #expect(request?.sessionId == "s1")
        #expect(request?.paths == ["/tmp/a.txt"])
    }

    @Test func cliRequestReturnsHandlerError() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        server.onCLIRequest = { _ in .error("Path does not exist.") }

        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/missing.txt"]}"#
        let response = try await Self.sendToSocket(path: path, payload: json)
        let object = try responseObject(response)

        #expect(object["ok"] as? Bool == false)
        #expect(object["error"] as? String == "Path does not exist.")
    }

    @Test func cliRequestWithoutHandlerReturnsUnavailableError() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        let response = try await Self.sendToSocket(path: path, payload: json)
        let object = try responseObject(response)

        #expect(object["ok"] as? Bool == false)
        #expect(object["error"] as? String == "Alas CLI is not available.")
    }

    @Test func cliRequestDoesNotDispatchHarnessEvent() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        let holder = EventHolder()
        server.onEvent = { event in holder.deliver(event) }
        server.onCLIRequest = { _ in .ok }

        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        _ = try await Self.sendToSocket(path: path, payload: json)
        let event = await holder.wait(timeoutMs: 300)

        #expect(event == nil)
    }

    @Test func malformedCLIRequestDoesNotDispatchHarnessEvent() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        let holder = EventHolder()
        server.onEvent = { event in holder.deliver(event) }
        server.onCLIRequest = { _ in .ok }

        let json = #"{"v":1,"kind":"cli","event":"busy","agent":"claude","session_id":"s1","paths":["/tmp/a"]}"#
        let response = try await Self.sendToSocket(path: path, payload: json)
        let object = try responseObject(response)
        let event = await holder.wait(timeoutMs: 300)

        #expect(object["ok"] as? Bool == false)
        #expect(event == nil)
    }

    @Test func longRunningCLIRequestDoesNotBlockPreviewCancel() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        actor Requests {
            var commands: [AlasCLIRequest.Command] = []
            func append(_ command: AlasCLIRequest.Command) { commands.append(command) }
            func snapshot() -> [AlasCLIRequest.Command] { commands }
        }

        let gate = Gate()
        let requests = Requests()
        server.onCLIRequest = { request in
            await requests.append(request.command)
            if case .open = request.command {
                await gate.wait()
                return .ok
            }
            return .text(["cancelled"])
        }

        let longRequest = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        let cancelRequest = #"{"v":1,"kind":"cli","command":"preview_cancel","session_id":"s1","params":{"preview_id":"p1"}}"#

        let longTask = Task { try await Self.sendToSocket(path: path, payload: longRequest) }
        await gate.waitUntilEntered()

        let response: String
        do {
            response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await Self.sendToSocket(path: path, payload: cancelRequest) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    throw POSIXError(.ETIMEDOUT)
                }
                let next = try await group.next()
                let first = try #require(next)
                group.cancelAll()
                return first
            }
            await gate.release()
            _ = try await longTask.value
        } catch {
            await gate.release()
            _ = try? await longTask.value
            throw error
        }
        let object = try responseObject(response)
        let commands = await requests.snapshot()

        #expect(object["lines"] as? [String] == ["cancelled"])
        #expect(commands.count == 2)
    }

    @Test func multiMegabyteCLIResponseIsWrittenIntact() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        let payload = String(repeating: "x", count: 11 * 1024 * 1024)
        server.onCLIRequest = { _ in .text([payload]) }

        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        let response = try await Self.sendToSocket(path: path, payload: json)
        let object = try responseObject(response)

        #expect(object["ok"] as? Bool == true)
        #expect((object["lines"] as? [String])?.first == payload)
    }

    @Test func shutdownUnblocksInFlightCLIConnection() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)

        actor Completion {
            private var value = false
            func finish() { value = true }
            func snapshot() -> Bool { value }
        }

        let gate = Gate()
        let completion = Completion()
        server.onCLIRequest = { _ in
            await gate.wait()
            return .ok
        }

        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        let clientTask = Task {
            do {
                _ = try await Self.sendToSocket(path: path, payload: json)
            } catch {
            }
            await completion.finish()
        }
        await gate.waitUntilEntered()

        server.shutdown()
        var completed = false
        for _ in 0..<20 {
            if await completion.snapshot() {
                completed = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await gate.release()
        await clientTask.value

        #expect(completed)
    }
}
