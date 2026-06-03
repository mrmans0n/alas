import Foundation

struct WebSocketFrame: Equatable {
    enum Opcode: UInt8 { case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA }
    let opcode: Opcode
    let payload: Data

    /// Hard cap on a single inbound frame's declared payload length. Larger
    /// frames are rejected rather than buffered, bounding memory and closing
    /// off a trivial "declare a huge length" denial-of-service. The remote
    /// protocol's messages (transcript deltas, decisions) are small, so 10 MB
    /// sits comfortably above any legitimate frame.
    static let maxPayloadLength = 10_000_000

    /// Server→client frames are never masked (RFC 6455 §5.1).
    static func encode(opcode: Opcode, payload: Data) -> Data {
        var out = Data()
        out.append(0x80 | opcode.rawValue)  // FIN set, single frame
        let len = payload.count
        if len < 126 {
            out.append(UInt8(len))
        } else if len <= 0xFFFF {
            out.append(126)
            out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
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
    static func decode(from buffer: inout Data) throws -> WebSocketFrame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        // RSV1-3 MUST be 0 — no extensions are negotiated (RFC 6455 §5.2).
        guard bytes[0] & 0x70 == 0 else {
            throw RemoteServerError.protocolViolation("reserved bits set")
        }
        // The opcode lives in byte 0, always available here; validate it in
        // O(1) before doing any length parsing or payload unmasking.
        let opRaw = bytes[0] & 0x0F
        guard let opcode = Opcode(rawValue: opRaw) else {
            throw RemoteServerError.protocolViolation("bad opcode \(opRaw)")
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
            mask = Array(bytes[idx..<idx + 4]); idx += 4
        }
        guard bytes.count >= idx + len else { return nil }
        var payload = [UInt8](bytes[idx..<idx + len])
        if masked { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }
        buffer.removeFirst(idx + len)
        return WebSocketFrame(opcode: opcode, payload: Data(payload))
    }
}
