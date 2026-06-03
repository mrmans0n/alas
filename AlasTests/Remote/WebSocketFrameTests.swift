// AlasTests/Remote/WebSocketFrameTests.swift
import Testing
import Foundation
@testable import Alas

struct WebSocketFrameTests {
    @Test func encodesShortTextFrameUnmasked() {
        let out = WebSocketFrame.encode(opcode: .text, payload: Data("hi".utf8))
        // FIN+text=0x81, len=2, "hi"
        #expect(Array(out) == [0x81, 0x02, 0x68, 0x69])
    }

    @Test func decodesMaskedClientTextFrame() throws {
        // Client frames MUST be masked. FIN+text, len=2 with mask bit, mask=0x01020304
        let mask: [UInt8] = [1, 2, 3, 4]
        let payload: [UInt8] = [0x68 ^ 1, 0x69 ^ 2] // "hi" masked
        var bytes: [UInt8] = [0x81, 0x82] + mask + payload
        var buffer = Data(bytes)
        let frame = try WebSocketFrame.decode(from: &buffer)
        #expect(frame?.opcode == .text)
        #expect(frame?.payload == Data("hi".utf8))
        #expect(buffer.isEmpty)  // fully consumed
        _ = bytes
    }

    @Test func decodeReturnsNilOnPartialFrame() throws {
        var buffer = Data([0x81])  // header incomplete
        #expect(try WebSocketFrame.decode(from: &buffer) == nil)
        #expect(buffer.count == 1)  // unconsumed
    }

    @Test func encodesExtendedLength() {
        let payload = Data(repeating: 0x41, count: 200)
        let out = WebSocketFrame.encode(opcode: .text, payload: payload)
        #expect(out[0] == 0x81)
        #expect(out[1] == 126)               // 16-bit length follows
        #expect(out[2] == 0x00 && out[3] == 200)
        #expect(out.count == 4 + 200)
    }
}
