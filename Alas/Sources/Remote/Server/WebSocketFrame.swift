// Alas/Sources/Remote/Server/WebSocketFrame.swift
import Foundation

struct WebSocketFrame: Equatable {
    enum Opcode: UInt8 { case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA }
    let opcode: Opcode
    let payload: Data

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
    static func decode(from buffer: inout Data) throws -> WebSocketFrame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let opRaw = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var len = Int(bytes[1] & 0x7F)
        var idx = 2
        if len == 126 {
            guard bytes.count >= 4 else { return nil }
            len = Int(bytes[2]) << 8 | Int(bytes[3]); idx = 4
        } else if len == 127 {
            guard bytes.count >= 10 else { return nil }
            len = 0; for i in 2..<10 { len = (len << 8) | Int(bytes[i]) }; idx = 10
        }
        var mask: [UInt8] = [0, 0, 0, 0]
        if masked {
            guard bytes.count >= idx + 4 else { return nil }
            mask = Array(bytes[idx..<idx + 4]); idx += 4
        }
        guard bytes.count >= idx + len else { return nil }
        var payload = [UInt8](bytes[idx..<idx + len])
        if masked { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }
        guard let opcode = Opcode(rawValue: opRaw) else {
            throw RemoteServerError.protocolViolation("bad opcode \(opRaw)")
        }
        buffer.removeFirst(idx + len)
        return WebSocketFrame(opcode: opcode, payload: Data(payload))
    }
}

enum RemoteServerError: Error, Equatable { case protocolViolation(String); case unauthorized; case badRequest(String) }
