import Darwin
import Foundation

/// zmx's Unix-socket IPC wire format, mirrored from upstream `src/ipc.zig`.
///
/// zmx IPC is not yet a declared stable public API (neurosnap/zmx#127). Keep
/// every wire detail in this file so the codec can later move to libzmx or an
/// upstream client module without touching callers.
///
/// Frame: an eight-byte header followed by the payload. Byte 0 is the tag,
/// bytes 1...4 are the little-endian payload length, bytes 5...7 are padding
/// (`packed struct { tag: u8, len: u32 }` occupies eight bytes).
enum ZmxIPC {
    /// Tags Alas sends or reads. Values are frozen by upstream; unknown
    /// incoming tags are carried as raw bytes in `ZmxFrame` and skipped.
    enum Tag: UInt8, Sendable {
        case input = 0
        case output = 1
        case resize = 2
        case initialize = 7
        case send = 18
        case capture = 22
    }

    /// `util.HistoryFormat` in upstream zmx.
    enum CaptureFormat: UInt8, Sendable {
        case plain = 0
        case vt = 1
        case html = 2
    }

    static let headerSize = 8

    /// Ceiling for a single incoming payload. Checked against the declared
    /// length before anything is buffered, so a corrupt header cannot make
    /// the reader allocate. Sized below the peer WebSocket frame limit after
    /// base64 expansion.
    static let maxPayloadLength = 8 * 1024 * 1024

    static func encode(_ tag: Tag, _ payload: Data = Data()) -> Data {
        var frame = Data(count: headerSize)
        frame[0] = tag.rawValue
        let length = UInt32(payload.count)
        for byte in 0..<4 {
            frame[1 + byte] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(byte)))
        }
        frame.append(payload)
        return frame
    }

    /// `ipc.Capture` is `packed struct { format: u8, rows: u32 }`, eight bytes
    /// on the wire. The daemon silently drops any other payload length.
    static func captureRequest(format: CaptureFormat = .vt, scrollbackRows: UInt32) -> Data {
        var payload = Data(count: 8)
        payload[0] = format.rawValue
        for byte in 0..<4 {
            payload[1 + byte] = UInt8(truncatingIfNeeded: scrollbackRows >> (8 * UInt32(byte)))
        }
        return encode(.capture, payload)
    }

    /// `ipc.Resize` is `packed struct { rows, cols, xpixel, ypixel: u16 }`;
    /// used by `Init` and `Resize`. Alas never sends either from a viewer.
    static func sizePayload(rows: UInt16, cols: UInt16) -> Data {
        var payload = Data(count: 8)
        payload[0] = UInt8(truncatingIfNeeded: rows)
        payload[1] = UInt8(truncatingIfNeeded: rows >> 8)
        payload[2] = UInt8(truncatingIfNeeded: cols)
        payload[3] = UInt8(truncatingIfNeeded: cols >> 8)
        return payload
    }
}

struct ZmxFrame: Equatable, Sendable {
    /// Raw tag byte, so tags newer than `ZmxIPC.Tag` survive decoding.
    var tag: UInt8
    var payload: Data

    var knownTag: ZmxIPC.Tag? { ZmxIPC.Tag(rawValue: tag) }
}

/// Incremental frame decoder that tolerates arbitrary partial reads.
struct ZmxFrameDecoder {
    enum Failure: Error, Equatable {
        case payloadTooLarge(declared: UInt32)
    }

    private let maxPayloadLength: Int
    private var buffer: [UInt8] = []
    private var head = 0

    init(maxPayloadLength: Int = ZmxIPC.maxPayloadLength) {
        self.maxPayloadLength = maxPayloadLength
    }

    var bufferedByteCount: Int { buffer.count - head }

    mutating func push(_ bytes: some Collection<UInt8>) throws -> [ZmxFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [ZmxFrame] = []
        while buffer.count - head >= ZmxIPC.headerSize {
            var declared: UInt32 = 0
            for byte in 0..<4 {
                declared |= UInt32(buffer[head + 1 + byte]) << (8 * UInt32(byte))
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
struct ZmxSnapshotGate {
    enum Event: Equatable, Sendable {
        case snapshot(Data)
        case output(Data)
    }

    /// Starts awaiting: a passive attachment captures before emitting output.
    private(set) var isCaptureInFlight = true

    /// Returns false while a capture is already in flight, so at most one
    /// capture/resync is outstanding.
    mutating func beginCapture() -> Bool {
        guard !isCaptureInFlight else { return false }
        isCaptureInFlight = true
        return true
    }

    mutating func accept(_ frame: ZmxFrame) -> Event? {
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
}

/// Blocking Unix-socket connection to one zmx session daemon.
final class ZmxIPCSocket: @unchecked Sendable {
    enum ConnectError: Error, Equatable {
        case pathTooLong
        case unavailable(errno: Int32)
    }

    let fd: Int32
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to an existing socket only. A missing or stale socket fails
    /// with `.unavailable`; nothing here can create a session.
    static func connect(path: String) throws -> ZmxIPCSocket {
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
    func write(_ data: Data) -> Bool {
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
    func read(maxLength: Int = 64 * 1024) -> Data? {
        var chunk = [UInt8](repeating: 0, count: maxLength)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxLength) }
            if n >= 0 { return Data(chunk[0..<n]) }
            if errno != EINTR { return nil }
        }
    }

    /// Unblocks a pending `read` and stops further I/O.
    func shutdown() {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }

    deinit {
        Darwin.close(fd)
    }
}
