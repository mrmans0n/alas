import Darwin
import Foundation
import Testing
@testable import Alas

@Suite struct ZmxPassiveClientTests {
    // MARK: Codec

    @Test func tagValuesAreFrozen() {
        let tags: [(ZmxIPC.Tag, UInt8)] = [
            (.input, 0), (.output, 1), (.resize, 2), (.kill, 5), (.info, 6), (.initialize, 7),
            (.send, 18), (.capture, 22), (.unsupported, 255),
        ]
        for (tag, raw) in tags { #expect(tag.rawValue == raw) }
    }

    @Test func headerAndCaptureLayoutsMatchEachWire() {
        let payload = Data(repeating: 0x41, count: 0x0102_03)
        #expect(Array(ZmxIPC.encode(.send, payload, wire: .preFreeze).prefix(8)) == [18, 0x03, 0x02, 0x01, 0x00, 0, 0, 0])
        #expect(Array(ZmxIPC.encode(.send, payload, wire: .v1).prefix(8)) == [18, 1, 0, 0, 0x03, 0x02, 0x01, 0x00])
        #expect(Array(ZmxIPC.captureRequest(scrollbackRows: 0x0A0B_0C0D, wire: .preFreeze))
            == [22, 8, 0, 0, 0, 0, 0, 0, 1, 0x0D, 0x0C, 0x0B, 0x0A, 0, 0, 0])
        #expect(Array(ZmxIPC.captureRequest(scrollbackRows: 0x0A0B_0C0D, wire: .v1))
            == [22, 1, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0, 0x0D, 0x0C, 0x0B, 0x0A])
        #expect(Array(ZmxIPC.encode(.kill, wire: .preFreeze)) == [5, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test(arguments: [ZmxIPC.Wire.preFreeze, .v1], [1, 3, 7, 8, 9, 64])
    func decoderReassemblesFramesAcrossArbitraryReads(wire: ZmxIPC.Wire, chunkSize: Int) throws {
        let expected = [
            ZmxFrame(tag: 1, payload: Data("hello".utf8)),
            ZmxFrame(tag: 99, payload: Data([1, 2, 3])),
            ZmxFrame(tag: 22, payload: Data()),
            ZmxFrame(tag: 1, payload: Data(repeating: 0xFF, count: 300)),
        ]
        let stream = expected.reduce(into: Data()) { data, frame in
            var header = ZmxIPC.encode(.output, frame.payload, wire: wire)
            header[0] = frame.tag
            data.append(header)
        }
        var decoder = ZmxFrameDecoder(wire: wire)
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

    @Test(arguments: [ZmxIPC.Wire.preFreeze, .v1], [UInt32(1025), UInt32.max])
    func decoderRejectsOversizedPayloadFromHeaderAlone(wire: ZmxIPC.Wire, declared: UInt32) {
        var decoder = ZmxFrameDecoder(wire: wire, maxPayloadLength: 1024)
        var header = ZmxIPC.encode(.output, wire: wire)
        let offset = wire == .v1 ? 4 : 1
        header.replaceSubrange(offset..<(offset + 4), with: withUnsafeBytes(of: declared.littleEndian, Array.init))
        #expect(throws: ZmxFrameDecoder.Failure.payloadTooLarge(declared: declared)) {
            _ = try decoder.push(header)
        }
    }

    @Test func v1DecoderRejectsAFrameFromAnotherProtocolVersion() {
        var decoder = ZmxFrameDecoder(wire: .v1)
        #expect(throws: ZmxFrameDecoder.Failure.unsupportedVersion(0x28)) {
            _ = try decoder.push(ZmxIPC.encode(.output, Data(repeating: 0, count: 0x28), wire: .preFreeze))
        }
    }

    @Test(arguments: [ZmxIPC.Wire.preFreeze, .v1])
    func probeReplyClassifiesTheCapturedInfoHeaders(wire: ZmxIPC.Wire) {
        let reply = zmxInfoReply(wire: wire)
        let expected = zmxInfoStatus(wire)
        let output = ZmxIPC.encode(.output, Data(repeating: 0x41, count: 600), wire: wire)
        #expect(ZmxIPC.classifyProbeReply(reply.prefix(300)) == nil)
        #expect(ZmxIPC.classifyProbeReply(output) == nil)
        #expect(ZmxIPC.classifyProbeReply(reply) == expected)
        #expect(ZmxIPC.classifyProbeReply(output + reply) == expected)
        // Neither wire can frame a v1 header with another version byte and
        // a pre-freeze length above the payload ceiling.
        let unframeable: [UInt8] = [1, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0]
        #expect(ZmxIPC.classifyProbeReply(unframeable) == .unreachable)
        #expect(Array(ZmxIPC.versionProbe) == [6, 1, 0, 0, 0, 0, 0, 0, 0])
    }

    /// A pre-freeze verdict kills the daemon, so an `Info` counts only once
    /// the other wire's decoder has thrown.
    @Test func probeReplyNamesAWireOnlyOnceTheOtherIsRuledOut() {
        // Pre-freeze reads an empty v1 frame as a one-byte frame and is only
        // ruled out inside the v1 `Info` header that follows.
        let emptyOutput = ZmxIPC.encode(.output, Data(), wire: .v1)
        #expect(ZmxIPC.classifyProbeReply(emptyOutput + zmxInfoReply(wire: .v1)) == zmxInfoStatus(.v1))
        #expect(ZmxIPC.classifyProbeReply(zmxAmbiguousInfoReply()) == nil)
    }

    // MARK: Probe

    /// Whole or 7-byte chunks, each with and without a broadcast `Output`
    /// frame ahead of the `Info` reply (zmx broadcasts to un-`Init`ed clients).
    @Test(arguments: [ZmxIPC.Wire.preFreeze, .v1], [
        (chunkSize: Int.max, precededByOutput: false),
        (chunkSize: 7, precededByOutput: false),
        (chunkSize: Int.max, precededByOutput: true),
        (chunkSize: 7, precededByOutput: true),
    ])
    func probeClassifiesEachDaemonFromItsInfoReply(wire: ZmxIPC.Wire, shape: (chunkSize: Int, precededByOutput: Bool)) throws {
        let info = zmxInfoReply(wire: wire)
        let reply = shape.precededByOutput
            ? ZmxIPC.encode(.output, Data(repeating: 0x41, count: 600), wire: wire) + info
            : info
        let daemon = try ZmxFakeDaemonListener(
            script: shape.chunkSize == Int.max ? .reply(reply) : .replyInChunks(reply, size: shape.chunkSize))
        defer { daemon.tearDown() }
        // Paced chunks take a while to arrive; the deadline is not under test.
        #expect(ZmxIPCSocket.probe(path: daemon.path, timeout: .seconds(5)) == zmxInfoStatus(wire))
        #expect(daemon.received == ZmxIPC.versionProbe)
    }

    @Test func probeReportsUnreachableWithinItsTimeout() throws {
        let silent = try ZmxFakeDaemonListener(script: .silent)
        defer { silent.tearDown() }
        let ambiguous = try ZmxFakeDaemonListener(script: .reply(zmxAmbiguousInfoReply()))
        defer { ambiguous.tearDown() }
        for path in ["/tmp/zmxt-missing/s", silent.path, ambiguous.path] {
            let clock = ContinuousClock()
            let start = clock.now
            let status = ZmxIPCSocket.probe(path: path, timeout: .milliseconds(200))
            #expect(status == .unreachable)
            #expect(clock.now - start < .seconds(2))
        }
    }

    @Test func preFreezeKillSendsTheOldFrameAndWaitsForHangup() throws {
        let closing = try ZmxFakeDaemonListener(script: .closeAfterReceiving(count: 8))
        defer { closing.tearDown() }
        #expect(ZmxIPCSocket.killPreFreeze(path: closing.path))
        #expect(closing.received == Data([5, 0, 0, 0, 0, 0, 0, 0]))

        let silent = try ZmxFakeDaemonListener(script: .silent)
        defer { silent.tearDown() }
        #expect(!ZmxIPCSocket.killPreFreeze(path: silent.path, timeout: .milliseconds(200)))

        // A daemon that keeps broadcasting output while its shutdown stalls
        // (~2 s of 64-byte chunks) must not hold the kill past its deadline.
        let chatty = try ZmxFakeDaemonListener(script: .replyInChunks(Data(repeating: 0x41, count: 64 * 1000), size: 64))
        defer { chatty.tearDown() }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(!ZmxIPCSocket.killPreFreeze(path: chatty.path, timeout: .milliseconds(200)))
        #expect(clock.now - start < .seconds(1))
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

    @Test(arguments: [ZmxIPC.Wire.preFreeze, .v1])
    func passiveAttachCapturesFirstAndOrdersStreamAroundTheSnapshot(wire: ZmxIPC.Wire) async throws {
        let pair = try ZmxSocketPair()
        let events = EventLog()
        let client = ZmxPassiveClient(
            socket: ZmxIPCSocket(fd: pair.client),
            probe: { probeStatus(wire) },
            scrollbackRows: 500
        ) { events.append($0) }
        client.start()

        // The only bytes a passive attach writes are one Capture request,
        // encoded for the probed wire.
        var daemon = ZmxFrameDecoder(wire: wire)
        let request = try pair.readFrames(&daemon, count: 1)
        #expect(request == [ZmxFrame(tag: 22, payload: ZmxIPC.captureRequest(scrollbackRows: 500, wire: wire).dropFirst(8))])

        pair.write(ZmxIPC.encode(.output, Data("before".utf8), wire: wire))
        pair.write(ZmxIPC.encode(.capture, Data("snapshot".utf8), wire: wire) + ZmxIPC.encode(.output, Data("after".utf8), wire: wire))
        try await eventually("snapshot and live output") { events.all.count == 2 }

        #expect(client.requestResync())
        #expect(!client.requestResync())
        #expect(try pair.readFrames(&daemon, count: 1).map(\.tag) == [22])
        pair.write(ZmxIPC.encode(.output, Data("dropped".utf8), wire: wire) + ZmxIPC.encode(.capture, Data("again".utf8), wire: wire))

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

    @Test(arguments: [ZmxIPC.Wire.preFreeze, .v1])
    func daemonThatIgnoresCaptureIsReportedUnsupported(wire: ZmxIPC.Wire) async throws {
        let pair = try ZmxSocketPair()
        let events = EventLog()
        let client = ZmxPassiveClient(
            socket: ZmxIPCSocket(fd: pair.client),
            probe: { probeStatus(wire) },
            scrollbackRows: 0,
            captureTimeout: .milliseconds(50)
        ) { events.append($0) }
        client.start()
        pair.write(ZmxIPC.encode(.output, Data("ignored".utf8), wire: wire))
        try await eventually("capture deadline") { !events.all.isEmpty }
        #expect(events.all == [.closed(.captureUnsupported)])
        #expect(!client.send(Data("x".utf8)))
    }

    @Test func oversizedFrameDetachesAsOverflow() async throws {
        let pair = try ZmxSocketPair()
        let events = EventLog()
        let client = ZmxPassiveClient(
            socket: ZmxIPCSocket(fd: pair.client),
            probe: { .preFreeze(pid: 1) },
            scrollbackRows: 0
        ) { events.append($0) }
        client.start()
        pair.write(Data([1, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0]))
        try await eventually("overflow") { !events.all.isEmpty }
        #expect(events.all == [.closed(.overflow)])
    }

    @Test func unreachableProbeClosesWithoutSendingAnything() async throws {
        let pair = try ZmxSocketPair()
        let events = EventLog()
        let client = ZmxPassiveClient(
            socket: ZmxIPCSocket(fd: pair.client),
            probe: { .unreachable },
            scrollbackRows: 0
        ) { events.append($0) }
        client.start()
        try await eventually("closed") { !events.all.isEmpty }
        #expect(events.all == [.closed(.unreachable)])
        #expect(try pair.readUntilEOF().isEmpty)
        #expect(!client.requestResync())
        #expect(!client.send(Data("x".utf8)))
    }

    @Test func inputToAStalledDaemonNeverBlocksAndRevokedInputIsDropped() throws {
        let pair = try ZmxSocketPair()
        let client = ZmxPassiveClient(
            socket: ZmxIPCSocket(fd: pair.client),
            probe: { .preFreeze(pid: 1) },
            scrollbackRows: 0
        ) { _ in }
        client.start()
        defer { client.close() }

        // The daemon end is not read: writes stall, sends must not.
        let chunk = Data(repeating: 0x61, count: 256 * 1024)
        let started = ContinuousClock.now
        var accepted = 0
        while accepted < 64, client.send(chunk) { accepted += 1 }
        #expect(ContinuousClock.now - started < .seconds(1))
        // Queued input plus the one frame already being written.
        #expect(accepted * chunk.count <= ZmxPassiveClient.maxQueuedInputBytes + chunk.count)

        client.discardQueuedInput()
        #expect(client.send(Data("END".utf8)))
        var decoder = ZmxFrameDecoder(wire: .preFreeze)
        var delivered = 0
        var sawEnd = false
        while !sawEnd {
            for frame in try pair.readFrames(&decoder, count: 1) where frame.knownTag == .send {
                if frame.payload == Data("END".utf8) {
                    sawEnd = true
                } else {
                    delivered += frame.payload.count
                }
            }
        }
        // Only the write already in progress when the lease ended got through.
        #expect(delivered <= chunk.count)
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

private func probeStatus(_ wire: ZmxIPC.Wire) -> ZmxDaemonStatus {
    wire == .v1 ? .v1(pid: 1) : .preFreeze(pid: 1)
}

/// The status a probe reports for `zmxInfoReply(wire:)`.
func zmxInfoStatus(_ wire: ZmxIPC.Wire) -> ZmxDaemonStatus {
    wire == .v1 ? .v1(pid: 4242) : .preFreeze(pid: 4242)
}

/// A full `Info` reply for pid 4242: the header captured from a real daemon
/// of each wire plus a `ZmxIPC.infoPayloadSize` payload.
func zmxInfoReply(wire: ZmxIPC.Wire) -> Data {
    let headerHex = wire == .v1 ? "0601000028020000" : "0628020000000000"
    var payload = Data(count: ZmxIPC.infoPayloadSize)
    payload.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(4242).littleEndian, Array.init))
    let header = Data(stride(from: 0, to: headerHex.count, by: 2).map { index in
        let start = headerHex.index(headerHex.startIndex, offsetBy: index)
        return UInt8(headerHex[start..<headerHex.index(start, offsetBy: 2)], radix: 16)!
    })
    return header + payload
}

/// A v1 `Info` behind a v1 `Output` that the pre-freeze decoder can still
/// frame: it reads the `Output` header as a one-byte frame, then a 1 MiB
/// frame header planted in that payload, so it is still waiting for bytes
/// when the v1 `Info` completes.
func zmxAmbiguousInfoReply() -> Data {
    var payload = Data(count: 256)
    payload.replaceSubrange(1..<9, with: [1, 0, 0, 0x10, 0, 0, 0, 0])
    return ZmxIPC.encode(.output, payload, wire: .v1) + zmxInfoReply(wire: .v1)
}

/// Accepts one connection on a Unix socket in a short temp dir, records every
/// byte until the peer closes, and plays a scripted reply.
final class ZmxFakeDaemonListener: @unchecked Sendable {
    enum Script: Sendable {
        case reply(Data)
        case silent
        case replyInChunks(Data, size: Int)
        case closeAfterReceiving(count: Int)
    }

    let path: String
    private let directory: String
    private let listener: Int32
    private let lock = NSLock()
    private var buffer = Data()
    private let finished = DispatchSemaphore(value: 0)

    init(script: Script) throws {
        var template = Array("/tmp/zmxt-XXXXXX".utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }).map({ String(cString: $0) })
        else { throw POSIXError(.EIO) }
        directory = dir
        path = dir + "/s"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            try? FileManager.default.removeItem(atPath: dir)
            throw POSIXError(.EADDRINUSE)
        }
        // A distinct name: Swift 6.2 rejects the closures above if a local
        // shadows the `listener` property later in this initializer.
        let listenerFD = listener
        Thread { [self] in serve(listener: listenerFD, script: script) }.start()
    }

    /// Everything received, once the peer has closed (or after 5 seconds).
    var received: Data {
        _ = finished.wait(timeout: .now() + 5)
        finished.signal()
        return lock.withLock { buffer }
    }

    func tearDown() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func serve(listener: Int32, script: Script) {
        defer { finished.signal() }
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        // The code under test may hang up while a reply is still streaming.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        @discardableResult
        func send(_ data: Data) -> Bool {
            data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) } == data.count
        }
        var replied = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(client, &chunk, chunk.count)
            if n <= 0 { return }
            let total = lock.withLock { () -> Int in
                buffer.append(contentsOf: chunk[0..<n])
                return buffer.count
            }
            switch script {
            case .silent:
                break
            case .reply(let data):
                if !replied {
                    replied = true
                    send(data)
                }
            case .replyInChunks(let data, let size):
                if !replied {
                    replied = true
                    var offset = 0
                    while offset < data.count {
                        guard send(data[offset..<min(offset + size, data.count)]) else { return }
                        offset += size
                        usleep(2_000)
                    }
                }
            case .closeAfterReceiving(let count):
                if total >= count { return }
            }
        }
    }
}

/// A connected Unix socket pair; `client` is handed to the code under test
/// and the other end plays the zmx daemon.
final class ZmxSocketPair: @unchecked Sendable {
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

    /// Everything the client end wrote until it shut down; throws on timeout.
    func readUntilEOF() throws -> Data {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(daemon, &buffer, buffer.count)
            if n == 0 { return received }
            guard n > 0 else { throw POSIXError(.ETIMEDOUT) }
            received.append(contentsOf: buffer[0..<n])
        }
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
        try await viewer.awaitSize("40 120", stage: "initial host attachment")
        let shellPID = try await viewer.query("$$")

        let direct = try ProbeTerminalClient(path: session.socketPath, rows: 55, cols: 123, sendInit: false)
        defer { direct.close() }
        direct.sendResize()
        try await viewer.awaitSize("40 120", stage: "nonleader resize")
        #expect(direct.dimensionRequests == 0)

        direct.claimWithInput()
        try await viewer.awaitSize("55 123", stage: "direct client control")
        #expect(direct.dimensionRequests == 1)

        host.claimWithInput()
        try await viewer.awaitSize("40 120", stage: "host reclaim")
        #expect(host.dimensionRequests == 2)

        direct.close()
        viewer.close()
        viewer = try PassiveViewer(path: session.socketPath)
        try await viewer.awaitSnapshot()
        #expect(try await viewer.query("$$") == shellPID)
        try await viewer.awaitSize("40 120", stage: "viewer reconnect")
        #expect(host.dimensionRequests == 2)
        viewer.close()
    }
}

/// An isolated zmx Bash session without line editing, killed on tear-down.
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
        // `run` starts Bash regardless of SHELL. Readline's prompt setup
        // reads then writes the PTY size, which can overwrite a concurrent
        // leader resize with the old size. Disable it and wait for the task
        // to finish before attaching clients so only zmx owns test geometry.
        process.arguments = ["run", Self.name, "set", "+o", "emacs", "+o", "vi"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZMX_SESSION")
        environment["ZMX_DIR"] = dir
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { tearDown() }
        try #require(process.terminationStatus == 0, "probe shell setup failed")
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
        client = ZmxPassiveClient(
            socket: try ZmxIPCSocket.connect(path: path),
            probe: { ZmxIPCSocket.probe(path: path) },
            scrollbackRows: 0
        ) { events.append($0) }
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
    /// A deadline, not a poll count: a resize is a round trip through the
    /// client's reader thread, which a loaded CI runner can stall.
    func awaitSize(_ expected: String, stage: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        var size = ""
        while ContinuousClock.now < deadline {
            size = try await query("$(stty size)")
            if size == expected { return }
        }
        try #require(size == expected, "\(stage): PTY size stayed \(size), never became \(expected)")
    }

    func close() { client.close() }

    private var text: String {
        events.all.reduce(into: "") { result, event in
            if case .output(let data) = event { result += String(decoding: data, as: UTF8.self) }
        }
    }
}

/// A raw zmx client standing in for a terminal: answers zmx dimension
/// requests (an empty `Resize`) with its own size. Speaks whichever wire the
/// bundled daemon answers the probe with.
private final class ProbeTerminalClient: @unchecked Sendable {
    private let socket: ZmxIPCSocket
    private let wire: ZmxIPC.Wire
    private let size: Data
    private let requests = ZmxEventLog<Int>()

    var dimensionRequests: Int { requests.all.count }

    init(path: String, rows: UInt16, cols: UInt16, sendInit: Bool) throws {
        switch ZmxIPCSocket.probe(path: path) {
        case .v1: wire = .v1
        case .preFreeze: wire = .preFreeze
        case .unreachable:
            Issue.record("the zmx daemon at \(path) did not answer the wire probe")
            throw POSIXError(.ECONNREFUSED)
        }
        socket = try ZmxIPCSocket.connect(path: path)
        size = ZmxIPC.sizePayload(rows: rows, cols: cols)
        Thread { [socket, wire, size, requests] in
            var decoder = ZmxFrameDecoder(wire: wire)
            while let chunk = socket.read(), !chunk.isEmpty {
                guard let frames = try? decoder.push(chunk) else { return }
                for frame in frames where frame.knownTag == .resize && frame.payload.isEmpty {
                    requests.append(0)
                    socket.write(ZmxIPC.encode(.resize, size, wire: wire))
                }
            }
        }.start()
        if sendInit { socket.write(ZmxIPC.encode(.initialize, size, wire: wire)) }
    }

    func sendResize() { socket.write(ZmxIPC.encode(.resize, size, wire: wire)) }

    /// A bare CR counts as user input to zmx and claims leadership.
    func claimWithInput() { socket.write(ZmxIPC.encode(.input, Data("\r".utf8), wire: wire)) }

    func close() { socket.shutdown() }
}
