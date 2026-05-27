import Foundation
import Testing
@testable import Alas

@Suite("JSONRPCFramer")
struct JSONRPCFramerTests {
    @Test("decodes a single Content-Length framed payload")
    func singleFrame() {
        var framer = JSONRPCFramer()
        let body = #"{"jsonrpc":"2.0","id":1,"method":"x"}"#
        let bytes = "Content-Length: \(body.utf8.count)\r\n\r\n\(body)".data(using: .utf8)!
        framer.append(bytes)
        let frames = framer.drainFrames()
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == body)
    }

    @Test("decodes two frames delivered in one chunk")
    func twoFramesOneChunk() {
        var framer = JSONRPCFramer()
        let a = #"{"a":1}"#
        let b = #"{"b":2}"#
        let blob = "Content-Length: \(a.utf8.count)\r\n\r\n\(a)Content-Length: \(b.utf8.count)\r\n\r\n\(b)"
        framer.append(blob.data(using: .utf8)!)
        let frames = framer.drainFrames().compactMap { String(data: $0, encoding: .utf8) }
        #expect(frames == [a, b])
    }

    @Test("buffers partial frames across appends")
    func partialChunks() {
        var framer = JSONRPCFramer()
        let body = #"{"x":1}"#
        let full = "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let cut = full.index(full.startIndex, offsetBy: 8)
        framer.append(String(full[..<cut]).data(using: .utf8)!)
        #expect(framer.drainFrames().isEmpty)
        framer.append(String(full[cut...]).data(using: .utf8)!)
        let frames = framer.drainFrames()
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == body)
    }

    @Test("encodes a body with Content-Length header")
    func encode() {
        let body = #"{"a":1}"#.data(using: .utf8)!
        let framed = JSONRPCFramer.encode(body)
        let expected = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)! + body
        #expect(framed == expected)
    }
}
