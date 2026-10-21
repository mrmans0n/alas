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
    }

    // MARK: Pre-freeze migration

    @Test func migrationStopsOnlyPreFreezeDaemons() throws {
        let directory = try zmxShortTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let v1 = try ZmxFakeDaemonListener(directory: directory, name: "a", scripts: [.reply(zmxInfoReply(wire: .v1))])
        defer { v1.tearDown() }
        let preFreeze = try ZmxFakeDaemonListener(
            directory: directory, name: "b",
            scripts: [.reply(zmxInfoReply(wire: .preFreeze)), .closeAfterReceiving(count: 8)])
        defer { preFreeze.tearDown() }
        let silent = try ZmxFakeDaemonListener(directory: directory, name: "c", scripts: [.silent])
        defer { silent.tearDown() }
        #expect(FileManager.default.createFile(atPath: directory + "/d", contents: Data("log".utf8)))
        try FileManager.default.createDirectory(atPath: directory + "/logs", withIntermediateDirectories: false)

        let signalled = ZmxEventLog<Int32>()
        let result = ZmxPreFreezeMigration.run(
            directory: URL(fileURLWithPath: directory),
            bundledWire: .v1,
            probe: { ZmxIPCSocket.probe(path: $0, timeout: .milliseconds(300)) },
            kill: { ZmxIPCSocket.killPreFreeze(path: $0, timeout: .seconds(2)) },
            signal: { signalled.append($0) },
            isAlive: { _ in false }
        )

        #expect(result == ZmxPreFreezeMigration.Result(restarted: ["b"], failed: []))
        #expect(signalled.all.isEmpty)
        #expect(preFreeze.receivedPerConnection == [ZmxIPC.versionProbe, Data([5, 0, 0, 0, 0, 0, 0, 0])])
        #expect(!FileManager.default.fileExists(atPath: preFreeze.path))
        for name in ["a", "c", "d", "logs"] {
            #expect(FileManager.default.fileExists(atPath: directory + "/" + name), "\(name)")
        }
    }

    /// Until the bundled zmx speaks v1, every daemon is one it can drive and
    /// another Alas sharing the directory may be using it.
    @Test func migrationDoesNothingWhileTheBundledZmxIsPreFreeze() throws {
        let daemon = try ZmxFakeDaemonListener(script: .reply(zmxInfoReply(wire: .preFreeze)))
        let result = ZmxPreFreezeMigration.run(
            directory: URL(fileURLWithPath: daemon.directory),
            bundledWire: .preFreeze,
            kill: { _ in true },
            signal: { _ in },
            isAlive: { _ in false }
        )
        #expect(result == ZmxPreFreezeMigration.Result())
        #expect(FileManager.default.fileExists(atPath: daemon.path))
        // Nothing connected: tearing down unblocks the accept, and the
        // listener reports no connection at all.
        daemon.tearDown()
        #expect(daemon.receivedPerConnection.isEmpty)
    }

    /// The socket goes only once the daemon has exited; a daemon that never
    /// exits, or a pid that cannot be watched, leaves it in place.
    @Test(arguments: [
        (pid: Int32(4242), exits: true),
        (pid: Int32(4242), exits: false),
        (pid: Int32(1), exits: true),
    ])
    func migrationFallsBackToSignallingThePid(daemon shape: (pid: Int32, exits: Bool)) throws {
        let daemon = try ZmxFakeDaemonListener(script: .silent)
        defer { daemon.tearDown() }
        let signalled = ZmxEventLog<Int32>()
        let result = ZmxPreFreezeMigration.run(
            directory: URL(fileURLWithPath: daemon.directory),
            bundledWire: .v1,
            probe: { _ in .preFreeze(pid: shape.pid) },
            kill: { _ in false },
            signal: { signalled.append($0) },
            // Exits on the signal, or never.
            isAlive: { _ in !shape.exits || signalled.all.isEmpty },
            exitTimeout: .milliseconds(100)
        )
        let restarted = shape.pid > 1 && shape.exits
        #expect(signalled.all == (shape.pid > 1 ? [shape.pid] : []))
        #expect(FileManager.default.fileExists(atPath: daemon.path) == !restarted)
        #expect(result == (restarted
            ? ZmxPreFreezeMigration.Result(restarted: ["s"], failed: [])
            : ZmxPreFreezeMigration.Result(restarted: [], failed: ["s"])))
    }

    @Test func migrationProbesConcurrently() throws {
        let directory = try zmxShortTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // More sockets than a CI runner has cores: each one gets its own worker.
        let daemons = try (0..<8).map {
            try ZmxFakeDaemonListener(directory: directory, name: "\($0)", scripts: [.silent])
        }
        defer { daemons.forEach { $0.tearDown() } }

        let statuses = ZmxEventLog<ZmxDaemonStatus>()
        let killed = ZmxEventLog<String>()
        let clock = ContinuousClock()
        let start = clock.now
        let result = ZmxPreFreezeMigration.run(
            directory: URL(fileURLWithPath: directory),
            bundledWire: .v1,
            probe: { path in
                let status = ZmxIPCSocket.probe(path: path, timeout: .milliseconds(300))
                statuses.append(status)
                return status
            },
            kill: { path in
                killed.append(path)
                return false
            },
            signal: { _ in }
        )
        #expect(clock.now - start < .seconds(1))
        #expect(statuses.all == Array(repeating: .unreachable, count: 8))
        #expect(killed.all.isEmpty)
        #expect(result == ZmxPreFreezeMigration.Result(restarted: [], failed: []))
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

/// A short temp directory for Unix sockets (`sun_path` caps paths near 104 bytes).
func zmxShortTempDirectory() throws -> String {
    var template = Array("/tmp/zmxt-XXXXXX".utf8CString)
    guard let dir = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }).map({ String(cString: $0) })
    else { throw POSIXError(.EIO) }
    return dir
}

/// Listens on a Unix socket and serves one connection per script, in order:
/// records every byte until the peer closes and plays that script's reply.
/// Without a `directory` it binds `s` in its own short temp dir.
final class ZmxFakeDaemonListener: @unchecked Sendable {
    enum Script: Sendable {
        case reply(Data)
        case silent
        case replyInChunks(Data, size: Int)
        case closeAfterReceiving(count: Int)
    }

    let path: String
    let directory: String
    private let ownsDirectory: Bool
    private let listener: Int32
    private let lock = NSLock()
    private var connections: [Data] = []
    private let finished = DispatchSemaphore(value: 0)

    convenience init(script: Script) throws {
        try self.init(scripts: [script])
    }

    init(directory: String? = nil, name: String = "s", scripts: [Script]) throws {
        let dir = try directory ?? zmxShortTempDirectory()
        self.directory = dir
        ownsDirectory = directory == nil
        path = dir + "/" + name
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
            if ownsDirectory { try? FileManager.default.removeItem(atPath: dir) }
            throw POSIXError(.EADDRINUSE)
        }
        let listener = listener
        Thread { [self] in
            defer { finished.signal() }
            for script in scripts {
                guard serve(listener: listener, script: script) else { return }
            }
        }.start()
    }

    /// Everything received over all connections, once every script has been
    /// served (or after 5 seconds).
    var received: Data {
        receivedPerConnection.reduce(Data(), +)
    }

    /// The bytes of each connection, in accept order.
    var receivedPerConnection: [Data] {
        _ = finished.wait(timeout: .now() + 5)
        finished.signal()
        return lock.withLock { connections }
    }

    func tearDown() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        if ownsDirectory {
            try? FileManager.default.removeItem(atPath: directory)
        } else {
            unlink(path)
        }
    }

    /// Serves one connection; false when accepting failed.
    private func serve(listener: Int32, script: Script) -> Bool {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return false }
        defer { Darwin.close(client) }
        let index = lock.withLock { () -> Int in
            connections.append(Data())
            return connections.count - 1
        }
        func send(_ data: Data) {
            _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        }
        var replied = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(client, &chunk, chunk.count)
            if n <= 0 { return true }
            let total = lock.withLock { () -> Int in
                connections[index].append(contentsOf: chunk[0..<n])
                return connections[index].count
            }
            switch script {
            case .silent:
                break
            case .reply(let data):
                if !replied { replied = true; send(data) }
            case .replyInChunks(let data, let size):
                if !replied {
                    replied = true
                    var offset = 0
                    while offset < data.count {
                        send(data[offset..<min(offset + size, data.count)])
                        offset += size
                        usleep(2_000)
                    }
                }
            case .closeAfterReceiving(let count):
                if total >= count { return true }
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
    /// The migration trusts `ZmxIPC.bundledWire`; a zmx bump that forgets to
    /// flip it must fail here.
    @Test func bundledWireMatchesTheBundledBinary() throws {
        let session = try ZmxProbeSession()
        defer { session.tearDown() }
        let wire: ZmxIPC.Wire? = switch ZmxIPCSocket.probe(path: session.socketPath, timeout: .seconds(5)) {
        case .v1: ZmxIPC.Wire.v1
        case .preFreeze: ZmxIPC.Wire.preFreeze
        case .unreachable: nil
        }
        #expect(wire == ZmxIPC.bundledWire)
    }

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
