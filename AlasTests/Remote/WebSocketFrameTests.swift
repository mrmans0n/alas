import Testing
import Foundation
@testable import Alas

struct WebSocketFrameTests {
    @Test func decodeExposesFinBit() throws {
        // FIN=0 text frame (byte0 0x01), masked, "hi".
        var notFinal = Data([0x01, 0x82, 1, 2, 3, 4, UInt8(0x68) ^ 1, UInt8(0x69) ^ 2])
        #expect(try WebSocketFrame.decode(from: &notFinal)?.fin == false)
        var final = Data([0x81, 0x82, 1, 2, 3, 4, UInt8(0x68) ^ 1, UInt8(0x69) ^ 2])
        #expect(try WebSocketFrame.decode(from: &final)?.fin == true)
    }

    @Test func reassemblerPassesCompleteMessage() {
        var r = WebSocketReassembler()
        #expect(r.accept(.init(opcode: .text, payload: Data("hi".utf8), fin: true)) == .message(Data("hi".utf8)))
    }

    @Test func reassemblerJoinsFragments() {
        var r = WebSocketReassembler()
        #expect(r.accept(.init(opcode: .text, payload: Data("he".utf8), fin: false)) == .incomplete)
        #expect(r.accept(.init(opcode: .continuation, payload: Data("ll".utf8), fin: false)) == .incomplete)
        #expect(r.accept(.init(opcode: .continuation, payload: Data("o".utf8), fin: true)) == .message(Data("hello".utf8)))
        // Reassembler is reusable for the next message after completing one.
        #expect(r.accept(.init(opcode: .text, payload: Data("x".utf8), fin: true)) == .message(Data("x".utf8)))
    }

    @Test func reassemblerRejectsContinuationWithoutStart() {
        var r = WebSocketReassembler()
        #expect(r.accept(.init(opcode: .continuation, payload: Data(), fin: true)) == .violation)
    }

    @Test func reassemblerRejectsNewMessageMidFragment() {
        var r = WebSocketReassembler()
        _ = r.accept(.init(opcode: .text, payload: Data("a".utf8), fin: false))
        #expect(r.accept(.init(opcode: .text, payload: Data("b".utf8), fin: true)) == .violation)
    }

    @Test func reassemblerEnforcesMaxBytes() {
        var r = WebSocketReassembler(maxBytes: 3)
        #expect(r.accept(.init(opcode: .text, payload: Data("ab".utf8), fin: false)) == .incomplete)
        #expect(r.accept(.init(opcode: .continuation, payload: Data("cd".utf8), fin: true)) == .violation)
    }

    @Test func encodesShortTextFrameUnmasked() {
        let out = WebSocketFrame.encode(opcode: .text, payload: Data("hi".utf8))
        // FIN+text=0x81, len=2, "hi"
        #expect(Array(out) == [0x81, 0x02, 0x68, 0x69])
    }

    @Test func decodesMaskedClientTextFrame() throws {
        // Client frames MUST be masked. FIN+text, len=2 with mask bit, mask=0x01020304
        let mask: [UInt8] = [1, 2, 3, 4]
        let payload: [UInt8] = [0x68 ^ 1, 0x69 ^ 2] // "hi" masked
        let bytes: [UInt8] = [0x81, 0x82] + mask + payload
        var buffer = Data(bytes)
        let frame = try WebSocketFrame.decode(from: &buffer)
        #expect(frame?.opcode == .text)
        #expect(frame?.payload == Data("hi".utf8))
        #expect(buffer.isEmpty)  // fully consumed
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

    @Test func roundTripsSixtyFourBitLength() throws {
        // A payload above 0xFFFF forces the 8-byte (127) length path.
        let payload = Data(repeating: 0x5A, count: 70_000)
        var buffer = Data(WebSocketFrame.encode(opcode: .binary, payload: payload))
        let frame = try WebSocketFrame.decode(from: &buffer)
        #expect(frame?.opcode == .binary)
        #expect(frame?.payload == payload)
        #expect(buffer.isEmpty)
    }

    @Test func decodesControlOpcodes() throws {
        var ping = Data([0x89, 0x80, 0, 0, 0, 0])    // masked, empty payload
        #expect(try WebSocketFrame.decode(from: &ping)?.opcode == .ping)
        var close = Data([0x88, 0x80, 0, 0, 0, 0])
        #expect(try WebSocketFrame.decode(from: &close)?.opcode == .close)
    }

    @Test func throwsOnBadOpcode() {
        var buffer = Data([0x83, 0x80, 0, 0, 0, 0])  // opcode 0x3 is reserved/unknown
        #expect(throws: RemoteServerError.self) { _ = try WebSocketFrame.decode(from: &buffer) }
    }

    @Test func throwsOnReservedBitsSet() {
        var buffer = Data([0xC1, 0x80, 0, 0, 0, 0])  // RSV1 set on a text frame
        #expect(throws: RemoteServerError.self) { _ = try WebSocketFrame.decode(from: &buffer) }
    }

    @Test func throwsOnOversizedDeclaredLength() {
        // 64-bit length declaring ~1 GB, well past the cap, with no payload present.
        var buffer = Data([0x82, 0x7F, 0, 0, 0, 0, 0x40, 0, 0, 0])
        #expect(throws: RemoteServerError.self) { _ = try WebSocketFrame.decode(from: &buffer) }
    }

    @Test(arguments: [
        "permessage-deflate",
        "other-extension, permessage-deflate; client_max_window_bits",
        "permessage-deflate; server_max_window_bits=\"15\"; client_max_window_bits=10"
    ])
    func negotiatesFreshDictionaries(offer: String) throws {
        let response = try #require(WebSocketDeflate.negotiate(offer))
        #expect(response.contains("server_no_context_takeover"))
        #expect(response.contains("client_no_context_takeover"))
    }

    @Test(arguments: [
        "", "unknown", "permessage-deflate; unknown",
        "permessage-deflate; server_no_context_takeover=1",
        "permessage-deflate; client_max_window_bits=7",
        "permessage-deflate; client_max_window_bits=16",
        "permessage-deflate; client_max_window_bits=015",
        "permessage-deflate; server_max_window_bits=14",
        "permessage-deflate; client_max_window_bits; client_max_window_bits",
        "permessage-deflate;"
    ])
    func declinesUnsupportedOrMalformedOffers(offer: String) {
        #expect(WebSocketDeflate.negotiate(offer) == nil)
        #expect(WebSocketDeflate.negotiate(nil) == nil)
    }

    @Test(arguments: Array(0...7))
    func inflatesRFC7692MessageAcrossFragments(split: Int) {
        // RFC 7692 §7.2.3.1: raw DEFLATE "Hello", with the sync-flush trailer removed.
        let wire = Data([0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00])
        var r = WebSocketReassembler()
        for _ in 0..<2 {
            #expect(r.accept(.init(opcode: .text, payload: wire.prefix(split), fin: false,
                                   compressed: true)) == .incomplete)
            #expect(r.accept(.init(opcode: .continuation, payload: wire.dropFirst(split), fin: true))
                    == .message(Data("Hello".utf8)))
        }
    }

    @Test(arguments: [
        Data([0xFF]), Data([0x03, 0x00]), Data([0xF2, 0x48]),
        Data([0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00, 0xFF])
    ])
    func rejectsInvalidCompressedMessages(wire: Data) {
        var r = WebSocketReassembler()
        #expect(r.accept(.init(opcode: .text, payload: wire, fin: true, compressed: true)) == .violation)
    }

    @Test(arguments: [UInt8(0xC0), 0xC9, 0xA1, 0x91, 0x09])
    func rejectsInvalidExtensionAndControlBits(first: UInt8) {
        var wire = Data([first, 0])
        #expect(throws: RemoteServerError.self) {
            _ = try WebSocketFrame.decode(from: &wire, compressionEnabled: true)
        }
    }

    @Test func compressedMessagesRespectDecodedLimitIncludingFinalFrame() throws {
        let limit = WebSocketFrame.maxPayloadLength
        let allowed = Data(repeating: 0x41, count: limit)
        let tooLarge = Data(repeating: 0x41, count: limit + 1)
        for (payload, expected) in [(allowed, WebSocketReassembler.Outcome.message(allowed)),
                                    (tooLarge, .violation)] {
            let wire = try #require(WebSocketDeflate.compress(payload))
            var r = WebSocketReassembler()
            #expect(r.accept(.init(opcode: .binary, payload: wire, fin: true, compressed: true)) == expected)
            var plain = WebSocketReassembler()
            #expect(plain.accept(.init(opcode: .binary, payload: payload, fin: true)) == expected)
        }
    }

    @Test func outgoingCompressionIsOptionalAndNeverTouchesControlFrames() throws {
        let payload = Data(String(repeating: "transcript text with repeated JSON fields\n", count: 200).utf8)
        var wire = WebSocketFrame.encode(opcode: .text, payload: payload, compressionEnabled: true)
        let frame = try #require(WebSocketFrame.decode(from: &wire, compressionEnabled: true))
        #expect(frame.compressed)
        #expect(frame.payload.count < payload.count / 2)
        var r = WebSocketReassembler()
        #expect(r.accept(frame) == .message(payload))
        #expect(WebSocketFrame.encode(opcode: .text, payload: payload)[0] == 0x81)
        #expect(WebSocketFrame.encode(opcode: .ping, payload: payload, compressionEnabled: true)[0] == 0x89)
    }
}
