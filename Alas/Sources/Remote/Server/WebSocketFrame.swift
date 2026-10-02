import Foundation
import zlib

struct WebSocketFrame: Equatable {
    enum Opcode: UInt8 { case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA }
    let opcode: Opcode
    let payload: Data
    /// FIN bit: false means more continuation frames follow (a fragmented
    /// message, RFC 6455 §5.4); callers must reassemble before decoding.
    let fin: Bool
    let compressed: Bool

    init(opcode: Opcode, payload: Data, fin: Bool, compressed: Bool = false) {
        self.opcode = opcode
        self.payload = payload
        self.fin = fin
        self.compressed = compressed
    }

    /// Hard cap on a single inbound frame's declared payload length. Larger
    /// frames are rejected rather than buffered, bounding memory and closing
    /// off a trivial "declare a huge length" denial-of-service.
    /// ~16 MB: fits a ~10 MB image base64-encoded (~13.3 MB) plus JSON overhead.
    static let maxPayloadLength = 16_000_000

    /// Server→client frames are never masked (RFC 6455 §5.1).
    static func encode(opcode: Opcode, payload: Data, compressionEnabled: Bool = false) -> Data {
        let compressed = compressionEnabled && (opcode == .text || opcode == .binary) && payload.count >= 256
            ? WebSocketDeflate.compress(payload) : nil
        let payload = compressed ?? payload
        var out = Data()
        out.reserveCapacity(payload.count + 10)
        out.append(0x80 | (compressed == nil ? 0 : 0x40) | opcode.rawValue)
        let len = payload.count
        if len < 126 {
            out.append(UInt8(len))
        } else if len <= 0xFFFF {
            out.append(126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((len >> shift) & 0xFF)) }
        }
        out.append(payload)
        return out
    }

    /// Decodes one frame, consuming its bytes from `buffer`. Returns nil if
    /// `buffer` does not yet hold a complete frame (buffer left unchanged).
    /// Throws `RemoteServerError.protocolViolation` on a malformed frame.
    static func decode(from buffer: inout Data, compressionEnabled: Bool = false) throws -> WebSocketFrame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] & 0x30 == 0 else {
            throw RemoteServerError.protocolViolation("reserved bits set")
        }
        // The opcode lives in byte 0, always available here; validate it in
        // O(1) before doing any length parsing or payload unmasking.
        let opRaw = bytes[0] & 0x0F
        guard let opcode = Opcode(rawValue: opRaw) else {
            throw RemoteServerError.protocolViolation("bad opcode \(opRaw)")
        }
        let compressed = bytes[0] & 0x40 != 0
        guard !compressed || (compressionEnabled && (opcode == .text || opcode == .binary)) else {
            throw RemoteServerError.protocolViolation("invalid RSV1")
        }
        if opRaw >= 0x8 {
            guard bytes[0] & 0x80 != 0, bytes[1] & 0x7F <= 125 else {
                throw RemoteServerError.protocolViolation("invalid control frame")
            }
        }
        let masked = (bytes[1] & 0x80) != 0
        var len = Int(bytes[1] & 0x7F)
        var idx = 2
        if len == 126 {
            guard bytes.count >= 4 else { return nil }
            len = Int(bytes[2]) << 8 | Int(bytes[3])
            idx = 4
        } else if len == 127 {
            guard bytes.count >= 10 else { return nil }
            // The most significant bit of the 64-bit length MUST be 0 (§5.2);
            // rejecting it also keeps `len` non-negative after accumulation.
            guard bytes[2] & 0x80 == 0 else {
                throw RemoteServerError.protocolViolation("reserved length MSB set")
            }
            len = 0
            for i in 2..<10 { len = (len << 8) | Int(bytes[i]) }
            idx = 10
        }
        guard len <= maxPayloadLength else {
            throw RemoteServerError.protocolViolation("frame too large: \(len)")
        }
        var mask: [UInt8] = [0, 0, 0, 0]
        if masked {
            guard bytes.count >= idx + 4 else { return nil }
            mask = Array(bytes[idx..<idx + 4])
            idx += 4
        }
        guard bytes.count >= idx + len else { return nil }
        var payload = [UInt8](bytes[idx..<idx + len])
        if masked { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }
        buffer.removeFirst(idx + len)
        return WebSocketFrame(opcode: opcode, payload: Data(payload), fin: (bytes[0] & 0x80) != 0,
                              compressed: compressed)
    }
}

/// Reassembles fragmented WebSocket data messages (RFC 6455 §5.4). Feed every
/// decoded `.text`/`.binary`/`.continuation` frame; the caller handles control
/// frames (ping/close/pong) separately and must NOT pass them here.
struct WebSocketReassembler {
    enum Outcome: Equatable {
        case message(Data)   // a complete (possibly reassembled) message
        case incomplete      // buffering; awaiting more continuation frames
        case violation       // malformed sequence — caller should close
    }

    private var fragmentOpcode: WebSocketFrame.Opcode?
    private var buffer = Data()
    private var inflater: WebSocketInflater?
    private let maxBytes: Int

    init(maxBytes: Int = WebSocketFrame.maxPayloadLength) { self.maxBytes = maxBytes }

    mutating func accept(_ frame: WebSocketFrame) -> Outcome {
        switch frame.opcode {
        case .text, .binary:
            // A new data message must not begin while one is still fragmenting.
            guard fragmentOpcode == nil else { return .violation }
            if frame.fin && !frame.compressed {
                return frame.payload.count <= maxBytes ? .message(frame.payload) : .violation
            }
            if frame.compressed {
                guard let decoder = WebSocketInflater() else { return .violation }
                inflater = decoder
            }
            fragmentOpcode = frame.opcode
            return append(frame)
        case .continuation:
            guard fragmentOpcode != nil else { return .violation }   // continuation without a start
            guard !frame.compressed else { return reset(.violation) }
            return append(frame)
        case .close, .ping, .pong:
            return .violation   // control frames must not be routed here
        }
    }
    private mutating func append(_ frame: WebSocketFrame) -> Outcome {
        if let inflater {
            guard inflater.append(frame.payload, final: frame.fin, to: &buffer, maxBytes: maxBytes) else {
                return reset(.violation)
            }
        } else {
            guard frame.payload.count <= maxBytes - buffer.count else { return reset(.violation) }
            buffer.append(frame.payload)
        }
        guard frame.fin else { return .incomplete }
        let message = buffer
        return reset(.message(message))
    }

    private mutating func reset(_ outcome: Outcome) -> Outcome {
        fragmentOpcode = nil
        inflater = nil
        buffer = Data()
        return outcome
    }
}

/// RFC 7692 with fresh dictionaries in both directions. Declining an offer
/// leaves the connection on the ordinary RFC 6455 transport.
enum WebSocketDeflate {
    static func negotiate(_ header: String?) -> String? {
        guard let header else { return nil }
        for offer in header.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = offer.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first == "permessage-deflate" else { continue }
            var seen = Set<String>()
            var response = "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
            var valid = true
            for parameter in parts.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let name = pair[0]
                guard seen.insert(name).inserted else { valid = false
                break }
                var value = pair.count == 2 ? pair[1] : nil
                if let quoted = value, quoted.hasPrefix("\""), quoted.hasSuffix("\""), quoted.count >= 2 {
                    value = String(quoted.dropFirst().dropLast())
                }
                switch name {
                case "server_no_context_takeover", "client_no_context_takeover":
                    valid = value == nil
                case "server_max_window_bits":
                    // Our outbound encoder uses a 15-bit window.
                    valid = value == "15"
                    if valid { response += "; server_max_window_bits=15" }
                case "client_max_window_bits":
                    valid = value == nil || (8...15).contains(Int(value ?? "") ?? 0)
                        && value == String(Int(value ?? "") ?? 0)
                    if valid { response += "; client_max_window_bits=\(value ?? "15")" }
                default:
                    valid = false
                }
                if !valid { break }
            }
            if valid { return response }
        }
        return nil
    }

    static func compress(_ payload: Data) -> Data? {
        var stream = z_stream()
        return withUnsafeMutablePointer(to: &stream) { stream in
            guard deflateInit2_(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { deflateEnd(stream) }
            var output = Data()
            var scratch = [UInt8](repeating: 0, count: 32 * 1024)
            let success = payload.withUnsafeBytes { input in
                stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.pointee.avail_in = uInt(input.count)
                return scratch.withUnsafeMutableBytes { chunk in
                    repeat {
                        stream.pointee.next_out = chunk.bindMemory(to: UInt8.self).baseAddress
                        stream.pointee.avail_out = uInt(chunk.count)
                        guard deflate(stream, Z_SYNC_FLUSH) == Z_OK else { return false }
                        output.append(chunk.bindMemory(to: UInt8.self).baseAddress!,
                                      count: chunk.count - Int(stream.pointee.avail_out))
                        // Don't allocate an incompressible copy of a large message.
                        guard output.count < payload.count else { return false }
                    } while stream.pointee.avail_out == 0
                    return stream.pointee.avail_in == 0
                }
            }
            guard success, output.suffix(4) == Data([0, 0, 255, 255]) else { return nil }
            output.removeLast(4)
            return output
        }
    }
}

/// Queue-confined, one instance per compressed message, including its fragments.
/// zlib retains a pointer to its stream, so its address must remain stable.
private final class WebSocketInflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var scratch = [UInt8](repeating: 0, count: 32 * 1024)

    init?() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        guard inflateInit2_(stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1)
            stream.deallocate()
            return nil
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func append(_ payload: Data, final: Bool, to output: inout Data, maxBytes: Int) -> Bool {
        guard consume(payload, to: &output, maxBytes: maxBytes) else { return false }
        if final {
            guard consume(Data([0, 0, 255, 255]), to: &output, maxBytes: maxBytes) else { return false }
            // The restored sync-flush block must finish on a block boundary.
            return stream.pointee.data_type & 128 != 0 && stream.pointee.data_type & 63 == 0
        }
        return true
    }

    private func consume(_ input: Data, to output: inout Data, maxBytes: Int) -> Bool {
        input.withUnsafeBytes { input in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.pointee.avail_in = uInt(input.count)
            return scratch.withUnsafeMutableBytes { chunk in
                repeat {
                    // At most one byte beyond the limit is inflated, never appended.
                    let capacity = min(chunk.count, maxBytes - output.count + 1)
                    stream.pointee.next_out = chunk.bindMemory(to: UInt8.self).baseAddress
                    stream.pointee.avail_out = uInt(capacity)
                    let before = stream.pointee.avail_in
                    let status = inflate(stream, Z_BLOCK)
                    let count = capacity - Int(stream.pointee.avail_out)
                    guard status == Z_OK || status == Z_BUF_ERROR, count <= maxBytes - output.count else {
                        return false
                    }
                    output.append(chunk.bindMemory(to: UInt8.self).baseAddress!, count: count)
                    if stream.pointee.avail_in == 0 && stream.pointee.avail_out != 0 { return true }
                    guard count > 0 || stream.pointee.avail_in < before else { return false }
                } while true
            }
        }
    }
}
