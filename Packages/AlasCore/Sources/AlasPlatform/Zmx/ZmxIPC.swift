import Darwin
import Foundation
import AlasFoundation
import AlasModel

/// zmx's Unix-socket IPC wire formats, mirrored from upstream `src/ipc.zig`.
///
/// Two layouts exist. Keep every wire detail in this file so the codec can
/// later move to libzmx or an upstream client module without touching callers.
///
/// Pre-freeze (daemons built before upstream froze the protocol): an
/// eight-byte header followed by the payload. Byte 0 is the tag, bytes 1...4
/// are the little-endian payload length, bytes 5...7 are padding
/// (`packed struct { tag: u8, len: u32 }` occupies eight bytes).
///
/// v1 (frozen upstream): byte 0 is the tag, byte 1 is the protocol version
/// (`protocolVersion`), bytes 2...3 are padding, and bytes 4...7 are the
/// little-endian payload length. Payload structs are C-aligned, so `Capture`
/// carries three padding bytes after its format byte.
public enum ZmxIPC: Sendable {
    /// Which header and payload layout a daemon speaks.
    public enum Wire: Equatable, Sendable {
        case preFreeze
        case v1
    }

    /// Tags Alas sends or reads. Values are frozen by upstream; unknown
    /// incoming tags are carried as raw bytes in `ZmxFrame` and skipped.
    public enum Tag: UInt8, Sendable {
        case input = 0
        case output = 1
        case resize = 2
        case kill = 5
        case info = 6
        case initialize = 7
        case send = 18
        case capture = 22
        case unsupported = 255
    }

    /// `util.HistoryFormat` in upstream zmx.
    public enum CaptureFormat: UInt8, Sendable {
        case plain = 0
        case vt = 1
        case html = 2
    }

    public static let headerSize = 8

    /// The v1 header's protocol version byte.
    public static let protocolVersion: UInt8 = 1

    /// Ceiling for a single incoming payload. Checked against the declared
    /// length before anything is buffered, so a corrupt header cannot make
    /// the reader allocate. Sized below the peer WebSocket frame limit after
    /// base64 expansion.
    public static let maxPayloadLength = 8 * 1024 * 1024

    /// Offset of the little-endian payload length within the header.
    static func lengthOffset(_ wire: Wire) -> Int {
        switch wire {
        case .preFreeze: 1
        case .v1: 4
        }
    }

    public static func encode(_ tag: Tag, _ payload: Data = Data(), wire: Wire) -> Data {
        var frame = Data(count: headerSize)
        frame[0] = tag.rawValue
        if wire == .v1 { frame[1] = protocolVersion }
        let length = UInt32(payload.count)
        let offset = lengthOffset(wire)
        for byte in 0..<4 {
            frame[offset + byte] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(byte)))
        }
        frame.append(payload)
        return frame
    }

    /// `ipc.Capture` is eight bytes on the wire: the format byte and a
    /// little-endian `rows: u32`, packed at offset 1 pre-freeze and aligned at
    /// offset 4 in v1. The daemon silently drops any other payload length.
    public static func captureRequest(format: CaptureFormat = .vt, scrollbackRows: UInt32, wire: Wire) -> Data {
        var payload = Data(count: 8)
        payload[0] = format.rawValue
        let offset = wire == .v1 ? 4 : 1
        for byte in 0..<4 {
            payload[offset + byte] = UInt8(truncatingIfNeeded: scrollbackRows >> (8 * UInt32(byte)))
        }
        return encode(.capture, payload, wire: wire)
    }

    /// An empty-payload `Info` request in v1 framing. A pre-freeze daemon
    /// reads its first header byte as the tag and byte 1 (the version) as the
    /// low length byte, so it answers with a pre-freeze `Info` frame instead.
    public static let versionProbe = Data([Tag.info.rawValue, protocolVersion, 0, 0, 0, 0, 0, 0, 0])

    /// `ipc.Info` is 552 bytes; the daemon pid is an `i32` at payload offset 8.
    private static let infoPayloadSize = 552
    private static let infoPidOffset = 8

    /// Classifies a daemon from the bytes it answered `versionProbe` with.
    /// Returns nil until a whole `Info` frame is present, or when the header
    /// matches neither wire. Never returns `.unreachable`; that is the
    /// caller's verdict when the connection fails or goes silent.
    public static func classifyProbeReply(_ bytes: some Collection<UInt8>) -> ZmxDaemonStatus? {
        let reply = Array(bytes.prefix(headerSize + infoPayloadSize))
        guard reply.count >= headerSize, reply[0] == Tag.info.rawValue else { return nil }
        func length(at offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(reply[offset + $1]) << (8 * $1) }
        }
        let wire: Wire
        if reply[1] == protocolVersion, length(at: 4) == infoPayloadSize {
            wire = .v1
        } else if length(at: 1) == infoPayloadSize, reply[5] == 0, reply[6] == 0, reply[7] == 0 {
            wire = .preFreeze
        } else {
            return nil
        }
        guard reply.count == headerSize + infoPayloadSize else { return nil }
        let pidStart = headerSize + infoPidOffset
        let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(reply[pidStart + $1]) << (8 * UInt32($1)) }
        let pid = Int32(bitPattern: raw)
        return wire == .v1 ? .v1(pid: pid) : .preFreeze(pid: pid)
    }

    /// `ipc.Resize` is `packed struct { rows, cols, xpixel, ypixel: u16 }`;
    /// used by `Init` and `Resize`. Alas never sends either from a viewer.
    public static func sizePayload(rows: UInt16, cols: UInt16) -> Data {
        var payload = Data(count: 8)
        payload[0] = UInt8(truncatingIfNeeded: rows)
        payload[1] = UInt8(truncatingIfNeeded: rows >> 8)
        payload[2] = UInt8(truncatingIfNeeded: cols)
        payload[3] = UInt8(truncatingIfNeeded: cols >> 8)
        return payload
    }
}

/// What a probe learned about a session daemon.
public enum ZmxDaemonStatus: Equatable, Sendable {
    case v1(pid: Int32)
    case preFreeze(pid: Int32)
    case unreachable
}

public struct ZmxFrame: Equatable, Sendable {
    /// Raw tag byte, so tags newer than `ZmxIPC.Tag` survive decoding.
    public var tag: UInt8
    public var payload: Data

    public var knownTag: ZmxIPC.Tag? { ZmxIPC.Tag(rawValue: tag) }

    public init(tag: UInt8, payload: Data) {
        self.tag = tag
        self.payload = payload
    }
}

/// Incremental frame decoder that tolerates arbitrary partial reads.
public struct ZmxFrameDecoder: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case payloadTooLarge(declared: UInt32)
        /// A v1 header whose protocol byte is not `ZmxIPC.protocolVersion`.
        case unsupportedVersion(UInt8)
    }

    private let wire: ZmxIPC.Wire
    private let maxPayloadLength: Int
    private var buffer: [UInt8] = []
    private var head = 0

    public init(wire: ZmxIPC.Wire, maxPayloadLength: Int = ZmxIPC.maxPayloadLength) {
        self.wire = wire
        self.maxPayloadLength = maxPayloadLength
    }

    public var bufferedByteCount: Int { buffer.count - head }

    public mutating func push(_ bytes: some Collection<UInt8>) throws -> [ZmxFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [ZmxFrame] = []
        while buffer.count - head >= ZmxIPC.headerSize {
            if wire == .v1, buffer[head + 1] != ZmxIPC.protocolVersion {
                throw Failure.unsupportedVersion(buffer[head + 1])
            }
            let lengthOffset = ZmxIPC.lengthOffset(wire)
            var declared: UInt32 = 0
            for byte in 0..<4 {
                declared |= UInt32(buffer[head + lengthOffset + byte]) << (8 * UInt32(byte))
            }
            // Compare as UInt64 so a near-max length can never wrap.
            guard UInt64(declared) <= UInt64(maxPayloadLength) else {
                throw Failure.payloadTooLarge(declared: declared)
            }
            let total = ZmxIPC.headerSize + Int(declared)
            guard buffer.count - head >= total else { break }
            let start = head + ZmxIPC.headerSize
            frames.append(ZmxFrame(tag: buffer[head], payload: Data(buffer[start..<(head + total)])))
            head += total
        }
        if head > 0, head >= buffer.count / 2 {
            buffer.removeFirst(head)
            head = 0
        }
        return frames
    }
}

/// Orders a passive attachment's stream around `Capture` responses.
///
/// zmx appends responses and broadcast output to the same per-client write
/// buffer, so the `Capture` response is a snapshot boundary: output read
/// before it is already contained in the snapshot and is discarded; output
/// read after it was produced after the snapshot and is emitted.
public struct ZmxSnapshotGate: Sendable {
    public enum Event: Equatable, Sendable {
        case snapshot(Data)
        case output(Data)
    }

    /// Starts awaiting: a passive attachment captures before emitting output.
    public private(set) var isCaptureInFlight = true

    /// Returns false while a capture is already in flight, so at most one
    /// capture/resync is outstanding.
    public mutating func beginCapture() -> Bool {
        guard !isCaptureInFlight else { return false }
        isCaptureInFlight = true
        return true
    }

    public mutating func accept(_ frame: ZmxFrame) -> Event? {
        switch frame.knownTag {
        case .capture where isCaptureInFlight:
            isCaptureInFlight = false
            return .snapshot(frame.payload)
        case .output where !isCaptureInFlight:
            return .output(frame.payload)
        default:
            return nil
        }
    }

    public init(isCaptureInFlight: Bool = true) {
        self.isCaptureInFlight = isCaptureInFlight
    }
}

/// Blocking Unix-socket connection to one zmx session daemon.
public final class ZmxIPCSocket: @unchecked Sendable {
    public enum ConnectError: Error, Equatable, Sendable {
        case pathTooLong
        case unavailable(errno: Int32)
    }

    public let fd: Int32
    private let writeLock = NSLock()

    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to an existing socket only. A missing or stale socket fails
    /// with `.unavailable`; nothing here can create a session.
    public static func connect(path: String) throws -> ZmxIPCSocket {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else { throw ConnectError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectError.unavailable(errno: errno) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ConnectError.unavailable(errno: code)
        }
        return ZmxIPCSocket(fd: fd)
    }

    /// Writes the whole buffer; false once the peer is gone.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Blocking read. Empty data means EOF; nil means a read error.
    public func read(maxLength: Int = 64 * 1024) -> Data? {
        var chunk = [UInt8](repeating: 0, count: maxLength)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxLength) }
            if n >= 0 { return Data(chunk[0..<n]) }
            if errno != EINTR { return nil }
        }
    }

    /// Asks a daemon which wire it speaks. Always uses its own connection and
    /// closes it before returning: a v1 daemon keeps the probe's ninth byte
    /// buffered as a partial frame, so this connection can carry nothing else.
    /// Anything but a recognized `Info` reply (connect failure, EOF, read
    /// error, unrecognized bytes, deadline) is `.unreachable`.
    public static func probe(path: String, timeout: DispatchTimeInterval = .seconds(1)) -> ZmxDaemonStatus {
        let deadline = DispatchTime.now() + timeout
        guard let socket = try? connect(path: path) else { return .unreachable }
        defer { socket.shutdown() }
        guard socket.write(ZmxIPC.versionProbe) else { return .unreachable }
        var reply = Data()
        while true {
            guard socket.waitReadable(until: deadline),
                  let chunk = socket.read(), !chunk.isEmpty else { return .unreachable }
            reply.append(chunk)
            if let status = ZmxIPC.classifyProbeReply(reply) { return status }
            // A reply that is already a full frame's worth of bytes yet
            // unclassifiable will never become valid.
            if reply.count > ZmxIPC.headerSize + 552 { return .unreachable }
        }
    }

    /// Sends a pre-freeze `Kill` and waits for the daemon to hang up, which it
    /// does once it has shut down. False on connect failure, error, or deadline.
    public static func killPreFreeze(path: String, timeout: DispatchTimeInterval = .seconds(3)) -> Bool {
        let deadline = DispatchTime.now() + timeout
        guard let socket = try? connect(path: path) else { return false }
        defer { socket.shutdown() }
        guard socket.write(ZmxIPC.encode(.kill, wire: .preFreeze)) else { return false }
        while true {
            guard socket.waitReadable(until: deadline), let chunk = socket.read() else { return false }
            if chunk.isEmpty { return true }
        }
    }

    /// `poll(2)` until the descriptor is readable (data or hangup) or the
    /// deadline passes. EINTR retries with the remaining time.
    private func waitReadable(until deadline: DispatchTime) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline.uptimeNanoseconds > now ? deadline.uptimeNanoseconds - now : 0
            let milliseconds = Int32(clamping: (remaining + 999_999) / 1_000_000)
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result > 0 { return true }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    /// Unblocks a pending `read` and stops further I/O.
    public func shutdown() {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }

    deinit {
        Darwin.close(fd)
    }
}
