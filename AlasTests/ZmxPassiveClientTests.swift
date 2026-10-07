import Darwin
import Foundation
import Testing
@testable import Alas

@Suite struct ZmxPassiveClientTests {
    // MARK: Codec

    @Test func tagValuesAndHeaderLayoutAreFrozen() {
        let tags: [(ZmxIPC.Tag, UInt8)] = [
            (.input, 0), (.output, 1), (.resize, 2), (.initialize, 7), (.send, 18), (.capture, 22),
        ]
        for (tag, raw) in tags { #expect(tag.rawValue == raw) }

        let frame = ZmxIPC.encode(.send, Data(repeating: 0x41, count: 0x0102_03))
        #expect(Array(frame.prefix(8)) == [18, 0x03, 0x02, 0x01, 0x00, 0, 0, 0])
        #expect(frame.count == 8 + 0x0102_03)

        #expect(Array(ZmxIPC.captureRequest(scrollbackRows: 0x0A0B_0C0D))
            == [22, 8, 0, 0, 0, 0, 0, 0, 1, 0x0D, 0x0C, 0x0B, 0x0A, 0, 0, 0])
    }

    @Test(arguments: [1, 3, 7, 8, 9, 64])
    func decoderReassemblesFramesAcrossArbitraryReads(chunkSize: Int) throws {
        let expected = [
            ZmxFrame(tag: 1, payload: Data("hello".utf8)),
            ZmxFrame(tag: 99, payload: Data([1, 2, 3])),
            ZmxFrame(tag: 22, payload: Data()),
            ZmxFrame(tag: 1, payload: Data(repeating: 0xFF, count: 300)),
        ]
        let stream = expected.reduce(into: Data()) { data, frame in
            var header = ZmxIPC.encode(.output, frame.payload)
            header[0] = frame.tag
            data.append(header)
        }
        var decoder = ZmxFrameDecoder()
        var frames: [ZmxFrame] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + chunkSize, stream.count)
            frames += try decoder.push(stream[offset..<end])
            offset = end
        }
        #expect(frames == expected)
        #expect(frames[1].knownTag == nil)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test(arguments: [UInt32(1025), UInt32.max])
    func decoderRejectsOversizedPayloadFromHeaderAlone(declared: UInt32) {
        var decoder = ZmxFrameDecoder(maxPayloadLength: 1024)
        let header: [UInt8] = [1] + withUnsafeBytes(of: declared.littleEndian, Array.init) + [0, 0, 0]
        #expect(throws: ZmxFrameDecoder.Failure.payloadTooLarge(declared: declared)) {
            _ = try decoder.push(header)
        }
    }

    // MARK: Snapshot ordering

    @Test func gateDropsOutputUntilEachCaptureResponse() {
        var gate = ZmxSnapshotGate()
        func feed(_ tag: UInt8, _ text: String) -> ZmxSnapshotGate.Event? {
            gate.accept(ZmxFrame(tag: tag, payload: Data(text.utf8)))
        }
        let initial = [feed(1, "early"), feed(22, "snap"), feed(1, "live"), feed(22, "stray")]
        #expect(initial == [nil, .snapshot(Data("snap".utf8)), .output(Data("live".utf8)), nil])

        let first = gate.beginCapture()
        let second = gate.beginCapture()
        #expect(first && !second)
        let resync = [feed(1, "stale"), feed(22, "snap2")]
        #expect(resync == [nil, .snapshot(Data("snap2".utf8))])
        let afterResync = gate.beginCapture()
        #expect(afterResync)
    }

    // MARK: Passive client over a socket pair

    @Test func passiveAttachCapturesFirstAndOrdersStreamAroundTheSnapshot() async throws {
        let pair = try SocketPair()
        let events = EventLog()
        let client = ZmxPassiveClient(socket: ZmxIPCSocket(fd: pair.client), scrollbackRows: 500) {
            events.append($0)
        }
        client.start()

        // The only bytes a passive attach writes are one Capture request.
        var daemon = ZmxFrameDecoder()
        let request = try pair.readFrames(&daemon, count: 1)
        #expect(request == [ZmxFrame(tag: 22, payload: ZmxIPC.captureRequest(scrollbackRows: 500).dropFirst(8))])

        pair.write(ZmxIPC.encode(.output, Data("before".utf8)))
        pair.write(ZmxIPC.encode(.capture, Data("snapshot".utf8)) + ZmxIPC.encode(.output, Data("after".utf8)))
        try await eventually("snapshot and live output") { events.all.count == 2 }

        #expect(client.requestResync())
        #expect(!client.requestResync())
        #expect(try pair.readFrames(&daemon, count: 1).map(\.tag) == [22])
        pair.write(ZmxIPC.encode(.output, Data("dropped".utf8)) + ZmxIPC.encode(.capture, Data("again".utf8)))

        #expect(client.send(Data("ls\r".utf8)))
        #expect(try pair.readFrames(&daemon, count: 1) == [ZmxFrame(tag: 18, payload: Data("ls\r".utf8))])

        pair.closeDaemonEnd()
        try await eventually("closed") { events.all.count == 4 }
        #expect(events.all == [
            .snapshot(Data("snapshot".utf8)),
            .output(Data("after".utf8)),
            .snapshot(Data("again".utf8)),
            .closed(.targetExited),
        ])
    }

    @Test func daemonThatIgnoresCaptureIsReportedUnsupported() async throws {
        let pair = try SocketPair()
        let events = EventLog()
        let client = ZmxPassiveClient(
            socket: ZmxIPCSocket(fd: pair.client),
            scrollbackRows: 0,
            captureTimeout: .milliseconds(50)
        ) { events.append($0) }
        client.start()
        pair.write(ZmxIPC.encode(.output, Data("ignored".utf8)))
        try await eventually("capture deadline") { !events.all.isEmpty }
        #expect(events.all == [.closed(.captureUnsupported)])
        #expect(!client.send(Data("x".utf8)))
    }

    @Test func oversizedFrameDetachesWithProtocolError() async throws {
        let pair = try SocketPair()
        let events = EventLog()
        let client = ZmxPassiveClient(socket: ZmxIPCSocket(fd: pair.client), scrollbackRows: 0) {
            events.append($0)
        }
        client.start()
        pair.write(Data([1, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0]))
        try await eventually("protocol error") { !events.all.isEmpty }
        guard case .closed(.protocolError)? = events.all.first else {
            Issue.record("expected protocol error, got \(events.all)")
            return
        }
    }

    @Test func connectingToMissingSocketNeverCreatesOne() throws {
        let path = NSTemporaryDirectory() + "zmx-missing-\(UUID().uuidString.prefix(8))"
        #expect(throws: ZmxIPCSocket.ConnectError.unavailable(errno: ENOENT)) {
            _ = try ZmxIPCSocket.connect(path: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

final class ZmxEventLog<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []
    func append(_ event: Event) { lock.withLock { events.append(event) } }
    var all: [Event] { lock.withLock { events } }
}

private typealias EventLog = ZmxEventLog<ZmxPassiveClient.Event>

/// A connected Unix socket pair; `client` is handed to the code under test
/// and the other end plays the zmx daemon.
private final class SocketPair {
    let client: Int32
    private let daemon: Int32
    private var daemonOpen = true

    init() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        client = fds[0]
        daemon = fds[1]
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(daemon, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func write(_ data: Data) {
        _ = data.withUnsafeBytes { Darwin.write(daemon, $0.baseAddress, $0.count) }
    }

    func readFrames(_ decoder: inout ZmxFrameDecoder, count: Int) throws -> [ZmxFrame] {
        var frames: [ZmxFrame] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while frames.count < count {
            let n = Darwin.read(daemon, &buffer, buffer.count)
            guard n > 0 else { throw POSIXError(.ETIMEDOUT) }
            frames += try decoder.push(buffer[0..<n])
        }
        return frames
    }

    func closeDaemonEnd() {
        guard daemonOpen else { return }
        daemonOpen = false
        Darwin.close(daemon)
    }

    deinit { closeDaemonEnd() }
}

/// Reproduces the #1558 protocol probe against the bundled upstream zmx: a
/// passive client never changes leadership or PTY geometry, `Send` reaches
/// the shell without claiming leadership, and only `Input` from a direct
/// client hands it geometry. Runs in an isolated `ZMX_DIR`.
@Suite(.enabled(if: ZmxEnv.resolve().binaryURL != nil, "requires the bundled zmx binary"))
struct ZmxPassiveClientIntegrationTests {
    @Test func passiveViewerLeavesLeadershipAndGeometryWithTheHost() async throws {
        let session = try ZmxProbeSession()
        defer { session.tearDown() }

        let host = try ProbeTerminalClient(path: session.socketPath, rows: 40, cols: 120, sendInit: true)
        defer { host.close() }
        try await eventually("host leads") { host.dimensionRequests == 1 }

        var viewer = try PassiveViewer(path: session.socketPath)
        try await viewer.awaitSnapshot()
        try await viewer.awaitSize("40 120")
        let shellPID = try await viewer.query("$$")

        let direct = try ProbeTerminalClient(path: session.socketPath, rows: 55, cols: 123, sendInit: false)
        defer { direct.close() }
        direct.sendResize()
        try await viewer.awaitSize("40 120")
        #expect(direct.dimensionRequests == 0)

        direct.claimWithInput()
        try await viewer.awaitSize("55 123")
        #expect(direct.dimensionRequests == 1)

        host.claimWithInput()
        try await viewer.awaitSize("40 120")
        #expect(host.dimensionRequests == 2)

        direct.close()
        viewer.close()
        viewer = try PassiveViewer(path: session.socketPath)
        try await viewer.awaitSnapshot()
        #expect(try await viewer.query("$$") == shellPID)
        try await viewer.awaitSize("40 120")
        #expect(host.dimensionRequests == 2)
        viewer.close()
    }
}

/// An isolated zmx session running `/bin/sh`, killed on tear-down.
private struct ZmxProbeSession {
    let client: ZmxClient
    let directory: URL
    let socketPath: String
    static let name = "probe"

    init() throws {
        let binary = try #require(ZmxEnv.resolve().binaryURL)
        // Short /tmp path keeps the socket inside sun_path.
        var template = Array("/tmp/azp.XXXXXX".utf8CString)
        let dir = try #require(template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }.map { String(cString: $0) })
        directory = URL(fileURLWithPath: dir, isDirectory: true)
        client = ZmxClient(env: ZmxEnv(binaryURL: binary, zmxDir: directory))
        socketPath = dir + "/" + Self.name

        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", Self.name, "-d", "true"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZMX_SESSION")
        environment["ZMX_DIR"] = dir
        environment["SHELL"] = "/bin/sh"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard FileManager.default.fileExists(atPath: socketPath) else {
            tearDown()
            throw POSIXError(.ENOENT)
        }
    }

    func tearDown() {
        client.killSession(name: Self.name)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Collects a passive client's VT stream as text and reads shell values by
/// sending `printf` through zmx `Send`.
private struct PassiveViewer {
    private let client: ZmxPassiveClient
    private let events: ZmxEventLog<ZmxPassiveClient.Event>

    init(path: String) throws {
        let events = ZmxEventLog<ZmxPassiveClient.Event>()
        self.events = events
        client = ZmxPassiveClient(socket: try ZmxIPCSocket.connect(path: path), scrollbackRows: 0) {
            events.append($0)
        }
        client.start()
    }

    func awaitSnapshot() async throws {
        try await eventually("snapshot") {
            events.all.contains { if case .snapshot = $0 { true } else { false } }
        }
    }

    /// Prints `expression` between unique markers and returns the value.
    /// The shell's echo of the command line shows `%s`, never a value.
    func query(_ expression: String) async throws -> String {
        let marker = "Q" + UUID().uuidString.prefix(6)
        client.send(Data("printf '\(marker)<%s>\\n' \"\(expression)\"\r".utf8))
        var value: String?
        try await eventually("\(marker) reply") {
            value = text.components(separatedBy: "\(marker)<").dropFirst()
                .filter { $0.contains(">") }
                .compactMap { $0.components(separatedBy: ">").first }
                .first { !$0.contains("%s") }
            return value != nil
        }
        return try #require(value)
    }

    /// Polls `stty size` until the PTY reports `expected` rows and columns.
    func awaitSize(_ expected: String) async throws {
        for _ in 0..<20 {
            if try await query("$(stty size)") == expected { return }
        }
        Issue.record("PTY size never became \(expected)")
    }

    func close() { client.close() }

    private var text: String {
        events.all.reduce(into: "") { result, event in
            if case .output(let data) = event { result += String(decoding: data, as: UTF8.self) }
        }
    }
}

/// A raw zmx client standing in for a terminal: answers zmx dimension
/// requests (an empty `Resize`) with its own size.
private final class ProbeTerminalClient: @unchecked Sendable {
    private let socket: ZmxIPCSocket
    private let size: Data
    private let requests = ZmxEventLog<Int>()

    var dimensionRequests: Int { requests.all.count }

    init(path: String, rows: UInt16, cols: UInt16, sendInit: Bool) throws {
        socket = try ZmxIPCSocket.connect(path: path)
        size = ZmxIPC.sizePayload(rows: rows, cols: cols)
        Thread { [socket, size, requests] in
            var decoder = ZmxFrameDecoder()
            while let chunk = socket.read(), !chunk.isEmpty {
                guard let frames = try? decoder.push(chunk) else { return }
                for frame in frames where frame.knownTag == .resize && frame.payload.isEmpty {
                    requests.append(0)
                    socket.write(ZmxIPC.encode(.resize, size))
                }
            }
        }.start()
        if sendInit { socket.write(ZmxIPC.encode(.initialize, size)) }
    }

    func sendResize() { socket.write(ZmxIPC.encode(.resize, size)) }

    /// A bare CR counts as user input to zmx and claims leadership.
    func claimWithInput() { socket.write(ZmxIPC.encode(.input, Data("\r".utf8))) }

    func close() { socket.shutdown() }
}
