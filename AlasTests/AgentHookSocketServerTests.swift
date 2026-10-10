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
        _ trigger: () async throws -> T
    ) async throws -> (T, AgentHookEvent?) {
        let holder = EventHolder()
        server.onEvent = { event in holder.deliver(event) }
        let triggerResult = try await trigger()
        let received = await holder.wait(timeoutMs: timeoutMs)
        return (triggerResult, received)
    }

    /// Performs the blocking client round-trip on a dedicated thread.
    ///
    /// The server serves every client on a detached Swift task, i.e. on the
    /// cooperative pool. Blocking a cooperative thread here in `read` while
    /// waiting for that task's reply can starve it on a narrow CI runner: the
    /// reply never gets written and `read` fails with EAGAIN when
    /// SO_RCVTIMEO fires (run 35322676722, subprocess-4-1). A plain `Thread`
    /// keeps the wait off the pool the server needs.
    private func sendToSocket(path: String, payload: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result {
                    try Self.blockingSendToSocket(path: path, payload: payload)
                })
            }
            thread.name = "AgentHookSocketServerTests.client"
            thread.start()
        }
    }

    private static func blockingSendToSocket(path: String, payload: String) throws -> String {
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
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            guard result == 0 else { throw posixError() }
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { bytes in
                memcpy(sunPath, bytes.baseAddress!, bytes.count)
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connectResult == 0 else { throw posixError() }

        try Data(payload.utf8).withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EPIPE) }
                written += count
            }
        }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            response.append(contentsOf: bytes.prefix(count))
        }
        return String(decoding: response, as: UTF8.self)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    @Test func wellFormedEnvelope_dispatchesEvent() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/test.sock"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }

        let json = #"{"v":1,"event":"busy","agent":"claude","session_id":"s1","pid":123}"#
        let (response, received) = try await awaitEvent(on: server, timeoutMs: 5000) {
            try await sendToSocket(path: path, payload: json)
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
            try await sendToSocket(path: path, payload: json)
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

        let response = try await sendToSocket(path: path, payload: "not json")
        #expect(response.contains("\"ok\":false") || response.contains("\"ok\": false"))
    }

    @Test func oversizedPid_decodesAsNil() throws {
        let json = #"{"v":1,"event":"busy","agent":"claude","session_id":"s1","pid":999999999999}"#

        let event = try AgentHookEvent.decode(from: Data(json.utf8))

        #expect(event.pid == nil)
    }

    @Test func backgroundActivityEnvelopeDecodesActivityIdentifier() throws {
        let json = #"{"v":1,"event":"background_started","agent":"pi","session_id":"s1","activity_id":"run-1","lifecycle_id":"life-1","lifecycle_order":"12345"}"#

        let event = try AgentHookEvent.decode(from: Data(json.utf8))

        #expect(event.event == .backgroundStarted)
        #expect(event.activityId == "run-1")
        #expect(event.lifecycleId == "life-1")
        #expect(event.lifecycleOrder == 12_345)
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
            try await sendToSocket(path: path, payload: json)
        }

        #expect(response.contains("\"ok\":true") || response.contains("\"ok\": true"))
        #expect(received == nil)
    }

    /// A missing directory is created and an existing one we own is set to
    /// `0700`, including owner-only but untraversable modes that would
    /// otherwise make socket binding fail later. A directory group or others
    /// could write is refused: tightening it would keep sockets they planted.
    /// A `nil` mode means the directory does not exist yet.
    @Test(arguments: [
        (nil, true), (0o700, true), (0o755, true), (0o600, true), (0o500, true),
        (0o777, false), (0o720, false), (0o702, false),
    ] as [(mode_t?, Bool)])
    func prepareSocketDirectory_tightensOrRefusesExistingMode(existingMode: mode_t?, accepted: Bool) throws {
        let dir = "/tmp/alas-test-mode-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        if let existingMode {
            try #require(mkdir(dir, 0o700) == 0)
            try #require(chmod(dir, existingMode) == 0)
        }

        #expect(AgentHookSocketServer.prepareSocketDirectory(dir, ownerUid: getuid()) == accepted)
        var st = Darwin.stat()
        #expect(Darwin.lstat(dir, &st) == 0)
        #expect((st.st_mode & 0o777) == (accepted ? 0o700 : existingMode))
    }

    /// Codex review (#102): `/tmp/alas-<uid>` is a predictable path. Another
    /// local user can pre-create it, but not owned by us, so a foreign owner
    /// is refused instead of binding our `pid-<pid>` socket there.
    @Test func prepareSocketDirectory_rejectsWrongOwner() throws {
        let dir = "/tmp/alas-test-wrong-owner-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = chmod(dir, 0o700)

        #expect(AgentHookSocketServer.prepareSocketDirectory(dir, ownerUid: 0xDEAD) == false)
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

    @Test
    func isolatedProfileBindsInsideItsRuntimeDirectory() {
        let runtime = URL(fileURLWithPath: "/tmp/alas-501-0123abcd", isDirectory: true)
        let isolated = AlasProfile(appSupportOverride: URL(fileURLWithPath: "/tmp/p"), runtimeDirectory: runtime)
        let standard = AlasProfile(appSupportOverride: nil, runtimeDirectory: nil)
        #expect(AgentHookSocketServer.socketDirectory(uid: 501, profile: isolated) == "/tmp/alas-501-0123abcd/hooks")
        #expect(AgentHookSocketServer.socketDirectory(uid: 501, profile: standard) == "/tmp/alas-501")
    }

    @Test
    func sessionLinksLiveNextToTheBindPath() throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/pid-1"
        let server = AgentHookSocketServer(socketPath: path)
        defer { server.shutdown() }
        let link = try #require(server.linkSession(leafId: "leaf"))
        #expect(link == "\(dir)/sock-leaf")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == path)
        server.unlinkSession(leafId: "leaf")
        #expect(!FileManager.default.fileExists(atPath: link))
    }

    /// A delegated child keeps the `ALAS_SOCKET_PATH` it was spawned with for
    /// its whole life, across app relaunches; the same path must reach
    /// whichever instance is running now.
    @Test
    func sessionLinkReachesTheRelaunchedInstance() async throws {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let key = AgentHookSocketServer.acpSessionLinkKey("child")
        let first = AgentHookSocketServer(socketPath: "\(dir)/pid-1")
        let link = try #require(first.linkSession(leafId: key))
        first.shutdown()

        // The relaunch's sweep drops the link left dangling by the quit...
        AgentHookSocketServer.sweepStaleSockets(in: dir)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == nil)

        // ...and re-attaching the session recreates it at the same path. The
        // live instance's socket is named after a live pid so the sweep keeps it.
        let secondPath = "\(dir)/pid-\(getpid())"
        let second = AgentHookSocketServer(socketPath: secondPath)
        defer { second.shutdown() }
        #expect(second.linkSession(leafId: key) == link)
        AgentHookSocketServer.sweepStaleSockets(in: dir)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == secondPath)

        let response = try await sendToSocket(path: link, payload: "not json")
        #expect(response.contains("\"ok\":false") || response.contains("\"ok\": false"))
    }

    /// Deleting the socket directory under a running instance (e.g.
    /// `rm -rf /tmp/alas-*`) must not strand its clients until a relaunch:
    /// the bind path comes back on its own and `onRebind` lets the owner
    /// relink its sessions. An isolated profile's `hooks` directory loses its
    /// runtime root with it.
    @Test(arguments: [false, true])
    func deletedSocketDirectoryIsRestored(isolated: Bool) async throws {
        let (root, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let dir = isolated ? "\(root)/hooks" : root
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let server = AgentHookSocketServer(socketPath: "\(dir)/pid-1", runtimeRoot: isolated ? root : nil)
        defer { server.shutdown() }
        let key = AgentHookSocketServer.acpSessionLinkKey("s")
        let link = try #require(server.linkSession(leafId: key))
        server.onRebind = { [weak server] in _ = server?.linkSession(leafId: key) }

        try FileManager.default.removeItem(atPath: root)

        let deadline = ContinuousClock.now + .seconds(15)
        while access(link, F_OK) != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let response = try await sendToSocket(path: link, payload: "not json")
        #expect(response.contains("\"ok\":false") || response.contains("\"ok\": false"))
    }

    /// Servers in one process share the pid bind path; the newest owns it.
    /// An older one must not take it back, or the two would trade the path
    /// on every idle check.
    @Test
    func olderServerDoesNotReclaimAReplacedBindPath() {
        let (dir, cleanup) = tmpSocketDir()
        defer { cleanup() }
        let path = "\(dir)/pid-1"
        let older = AgentHookSocketServer(socketPath: path)
        defer { older.shutdown() }
        let newer = AgentHookSocketServer(socketPath: path)
        defer { newer.shutdown() }

        #expect(older.rebindIfUnlinked() == nil)
    }
}
